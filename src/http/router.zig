//! HTTP Router implementation with automatic parameter injection.
//!
//! This module provides a type-safe HTTP router that automatically extracts
//! parameters from HTTP requests and injects them into handler functions.
//! It supports JSON deserialization, WebSocket upgrades, and custom extract support.

const std = @import("std");
const Request = std.http.Server.Request;
const Response = @import("response.zig").Response;
const Context = @import("context.zig").Context;
const extract = @import("../extract/root.zig");
const middleware = @import("middleware.zig");

/// Creates a generic HTTP router type parameterized by application state.
///
/// The State type parameter allows handlers to access shared application state.
/// The router automatically resolves handler parameters from the request using
/// compile-time reflection and built-in extract support.
///
/// Example:
/// ```zig
/// const MyState = struct { db: Database };
/// const MyRouter = Router(MyState);
///
/// fn myHandler(ctx: Context, state: *MyState, data: Json(MyStruct)) !Response {
///     // Parameters automatically extracted from request
///     _ = data; // JSON body deserialized to MyStruct
///     return Response.ok();
/// }
/// ```
pub fn Router(comptime State: type) type {
    return struct {
        const Self = @This();

        /// Memory allocator for route storage
        allocator: std.mem.Allocator,
        /// Map of exact route paths to their handlers
        routes: std.StringHashMap(Route),
        /// List of routes containing path parameters (e.g., `/users/:id`).
        /// Checked in precedence order (more literal segments first) after an exact match fails.
        parametric_routes: std.ArrayList(ParametricRoute),
        /// Middleware factories for per-request instantiation.
        /// A new middleware instance is created for each request from these factories.
        middleware_factories: std.ArrayList(middleware.MiddlewareFactory),

        /// Virtual table for type-erased handler execution
        const VTable = struct {
            execute: *const fn (*const anyopaque, Context, *State, ?[]const u8, req: *Request) anyerror!Response,
        };

        /// Type-erased handler wrapper that provides dynamic dispatch
        const Handler = struct {
            /// Pointer to the handler function
            ptr: *const anyopaque,
            /// Virtual table for execution
            vtable: VTable,

            /// Creates a new Handler instance from a function pointer.
            ///
            /// Parameters:
            /// - `HandlerFunction`: The function pointer type
            /// - `h`: Pointer to the handler function
            ///
            /// Returns: Initialized Handler with vtable
            pub fn init(comptime HandlerFunction: type, h: *const anyopaque) @This() {
                const impl = struct {
                    fn exec(ptr: *const anyopaque, ctx: Context, state: *State, route_pattern: ?[]const u8, req: *Request) !Response {
                        const values = .{ ctx, state };
                        const params = extract.resolveParams(
                            HandlerFunction,
                            @TypeOf(values),
                            ctx.request_allocator,
                            values,
                            route_pattern,
                            req,
                        );
                        const fun: HandlerFunction = @ptrCast(@alignCast(ptr));
                        return @call(.auto, fun, params);
                    }
                };

                return .{
                    .ptr = h,
                    .vtable = .{
                        .execute = impl.exec,
                    },
                };
            }

            /// Executes the handler with the given context, state, route pattern, and request.
            pub fn execute(self: *const Handler, ctx: Context, state: *State, route_pattern: ?[]const u8, req: *Request) !Response {
                return self.vtable.execute(self.ptr, ctx, state, route_pattern, req);
            }
        };

        /// Route entry containing handlers for different HTTP methods
        const Route = struct {
            /// Map of HTTP methods to their handlers
            handlers: std.AutoHashMap(std.http.Method, Handler),
        };

        /// A path segment used to match parametric routes.
        const Segment = union(enum) {
            /// A literal path segment that must match exactly.
            literal: []const u8,
            /// A named capture segment (e.g., `:id`) — matches any value.
            param: []const u8,
        };

        /// A route entry with a parsed segment pattern for path parameter matching.
        const ParametricRoute = struct {
            /// Original pattern string (e.g., "/users/:id") used for deduplication.
            pattern: []const u8,
            /// Parsed path segments, owned by the router allocator.
            segments: []Segment,
            /// Number of literal segments used for precedence ordering.
            literal_count: usize,
            /// Handlers indexed by HTTP method.
            entry: Route,

            /// Attempts to match `target` against this route's segment pattern.
            ///
            /// Returns true when all segments match and there are no extra trailing
            /// segments in `target`.
            pub fn match(self: *const ParametricRoute, target: []const u8) bool {
                const path = if (target.len > 0 and target[0] == '/') target[1..] else target;
                var path_it = std.mem.splitScalar(u8, path, '/');

                for (self.segments) |seg| {
                    const path_seg = path_it.next() orelse return false;
                    switch (seg) {
                        .literal => |lit| if (!std.mem.eql(u8, lit, path_seg)) return false,
                        .param => {},
                    }
                }

                // Reject paths with extra trailing segments.
                return path_it.next() == null;
            }
        };

        /// Initializes a new router instance.
        ///
        /// Parameters:
        /// - `allocator`: Memory allocator for route storage
        ///
        /// Returns: Initialized router ready to register routes
        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .routes = .init(allocator),
                .parametric_routes = .empty,
                .middleware_factories = .empty,
            };
        }

        /// Cleans up router resources.
        ///
        /// This method should be called when the router is no longer needed
        /// to free all allocated route handlers and mappings.
        pub fn deinit(self: *Self) void {
            var it = self.routes.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.handlers.deinit();
                self.allocator.free(entry.key_ptr.*);
            }
            self.routes.deinit();

            for (self.parametric_routes.items) |*route| {
                route.entry.handlers.deinit();
                self.allocator.free(route.segments);
                self.allocator.free(route.pattern);
            }
            self.parametric_routes.deinit(self.allocator);
            self.middleware_factories.deinit(self.allocator);
        }

        /// Registers middleware for all requests.
        ///
        /// Middleware runs for regular HTTP requests and WebSocket upgrade requests.
        /// A fresh middleware instance is created for each request.
        ///
        /// Middleware must implement:
        /// - `handle(self: *const Self, ctx: *Context, next: *const middleware.Chain.Next) !Response`
        /// - Optional: `init(allocator: std.mem.Allocator) !Self`
        ///
        /// Middleware may call `next.run()` to continue the chain or return a
        /// response directly to short-circuit request processing.
        pub fn use(self: *Self, comptime M: type) !void {
            const factory = middleware.Chain.makeFactory(M);
            try self.middleware_factories.append(self.allocator, factory);
        }

        /// Registers a GET route handler.
        ///
        /// Parameters:
        /// - `path`: Route path (e.g., "/users", "/api/v1/data")
        /// - `handler`: Function that handles GET requests to this path
        ///
        /// The handler function signature should be:
        /// `fn(ctx: Context, state: *State, ...) !Response`
        pub fn get(self: *Self, path: []const u8, handler: anytype) !void {
            try self.addRoute(.GET, path, makeHandler(handler));
        }

        /// Registers a POST route handler.
        ///
        /// Parameters:
        /// - `path`: Route path
        /// - `handler`: Function that handles POST requests to this path
        pub fn post(self: *Self, path: []const u8, handler: anytype) !void {
            try self.addRoute(.POST, path, makeHandler(handler));
        }

        /// Registers a PUT route handler.
        ///
        /// Parameters:
        /// - `path`: Route path
        /// - `handler`: Function that handles PUT requests to this path
        pub fn put(self: *Self, path: []const u8, handler: anytype) !void {
            try self.addRoute(.PUT, path, makeHandler(handler));
        }

        /// Registers a DELETE route handler.
        ///
        /// Parameters:
        /// - `path`: Route path
        /// - `handler`: Function that handles DELETE requests to this path
        pub fn delete(self: *Self, path: []const u8, handler: anytype) !void {
            try self.addRoute(.DELETE, path, makeHandler(handler));
        }

        /// Registers a PATCH route handler.
        ///
        /// Parameters:
        /// - `path`: Route path
        /// - `handler`: Function that handles PATCH requests to this path
        pub fn patch(self: *Self, path: []const u8, handler: anytype) !void {
            try self.addRoute(.PATCH, path, makeHandler(handler));
        }

        fn addRoute(self: *Self, method: std.http.Method, path: []const u8, handler: Handler) !void {
            if (isParametricPath(path)) {
                // Parametric route — check if the pattern is already registered.
                for (self.parametric_routes.items) |*route| {
                    if (std.mem.eql(u8, route.pattern, path)) {
                        try route.entry.handlers.put(method, handler);
                        return;
                    }
                }
                const parsed = try parseSegments(self.allocator, path);
                errdefer self.allocator.free(parsed.segments);
                const owned_pattern = try self.allocator.dupe(u8, path);
                errdefer self.allocator.free(owned_pattern);
                var entry = Route{ .handlers = .init(self.allocator) };
                errdefer entry.handlers.deinit();
                try entry.handlers.put(method, handler);

                var insert_index = self.parametric_routes.items.len;
                for (self.parametric_routes.items, 0..) |existing, i| {
                    if (parsed.literal_count > existing.literal_count) {
                        insert_index = i;
                        break;
                    }
                }

                try self.parametric_routes.insert(self.allocator, insert_index, .{
                    .pattern = owned_pattern,
                    .segments = parsed.segments,
                    .literal_count = parsed.literal_count,
                    .entry = entry,
                });
            } else {
                if (self.routes.getPtr(path)) |route| {
                    try route.handlers.put(method, handler);
                } else {
                    const owned_path = try self.allocator.dupe(u8, path);
                    errdefer self.allocator.free(owned_path);
                    var entry = Route{ .handlers = .init(self.allocator) };
                    errdefer entry.handlers.deinit();
                    try entry.handlers.put(method, handler);
                    try self.routes.put(owned_path, entry);
                }
            }
        }

        fn isParametricPath(path: []const u8) bool {
            const normalized = if (path.len > 0 and path[0] == '/') path[1..] else path;
            var it = std.mem.splitScalar(u8, normalized, '/');
            while (it.next()) |seg| {
                if (seg.len > 0 and seg[0] == ':') return true;
            }
            return false;
        }

        /// Parses a route pattern string into a slice of `Segment` values.
        ///
        /// Leading `/` is stripped before splitting by `/`. Segments starting
        /// with `:` become `.param` captures; all others become `.literal`.
        fn parseSegments(allocator: std.mem.Allocator, pattern: []const u8) !struct { segments: []Segment, literal_count: usize } {
            const path = if (pattern.len > 0 and pattern[0] == '/') pattern[1..] else pattern;
            var it = std.mem.splitScalar(u8, path, '/');
            var list: std.ArrayListUnmanaged(Segment) = .empty;
            errdefer list.deinit(allocator);
            var literal_count: usize = 0;
            while (it.next()) |seg| {
                if (seg.len > 0 and seg[0] == ':') {
                    const name = seg[1..];
                    for (list.items) |existing| {
                        switch (existing) {
                            .param => |existing_name| {
                                if (std.mem.eql(u8, existing_name, name)) {
                                    return error.DuplicateRouteParamName;
                                }
                            },
                            .literal => {},
                        }
                    }
                    try list.append(allocator, .{ .param = name });
                } else {
                    try list.append(allocator, .{ .literal = seg });
                    literal_count += 1;
                }
            }

            return .{
                .segments = try list.toOwnedSlice(allocator),
                .literal_count = literal_count,
            };
        }

        fn makeHandler(handler: anytype) Handler {
            const FuncPtr = @TypeOf(handler);
            const func_ptr_info = @typeInfo(FuncPtr);
            if (func_ptr_info != .pointer or !func_ptr_info.pointer.is_const) {
                @compileError("handler must be a const pointer type");
            }

            const func_type_info = @typeInfo(func_ptr_info.pointer.child);
            if (func_type_info != .@"fn") {
                @compileError("handler must be a const pointer type to a function");
            }

            const RetType = func_type_info.@"fn".return_type.?;
            const ret_type_info = @typeInfo(RetType);
            if (ret_type_info != .error_union or ret_type_info.error_union.payload != Response) {
                @compileError("handler must return !Response");
            }

            return .init(FuncPtr, @ptrCast(handler));
        }
    };
}
