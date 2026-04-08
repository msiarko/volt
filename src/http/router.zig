//! HTTP Router implementation with automatic parameter injection.
//!
//! This module provides a type-safe HTTP router that automatically extracts
//! parameters from HTTP requests and injects them into handler functions.
//! It supports JSON deserialization, WebSocket upgrades, and custom extract support.

const std = @import("std");
const Request = std.http.Server.Request;
const Response = @import("response.zig").Response;
const Context = @import("context.zig").Context;
const extract = @import("extract");

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
        /// Checked in registration order after an exact match fails.
        parametric_routes: std.ArrayListUnmanaged(ParametricRoute),

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
            }
            self.routes.deinit();

            for (self.parametric_routes.items) |*route| {
                route.entry.handlers.deinit();
                self.allocator.free(route.segments);
            }
            self.parametric_routes.deinit(self.allocator);
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
            if (std.mem.findScalar(u8, path, ':') != null) {
                // Parametric route — check if the pattern is already registered.
                for (self.parametric_routes.items) |*route| {
                    if (std.mem.eql(u8, route.pattern, path)) {
                        try route.entry.handlers.put(method, handler);
                        return;
                    }
                }
                const segments = try parseSegments(self.allocator, path);
                var entry = Route{ .handlers = .init(self.allocator) };
                try entry.handlers.put(method, handler);
                try self.parametric_routes.append(self.allocator, .{
                    .pattern = path,
                    .segments = segments,
                    .entry = entry,
                });
            } else {
                var res = try self.routes.getOrPut(path);
                if (!res.found_existing) {
                    res.value_ptr.* = .{ .handlers = .init(self.allocator) };
                }
                try res.value_ptr.handlers.put(method, handler);
            }
        }

        /// Parses a route pattern string into a slice of `Segment` values.
        ///
        /// Leading `/` is stripped before splitting by `/`. Segments starting
        /// with `:` become `.param` captures; all others become `.literal`.
        fn parseSegments(allocator: std.mem.Allocator, pattern: []const u8) ![]Segment {
            const path = if (pattern.len > 0 and pattern[0] == '/') pattern[1..] else pattern;
            var it = std.mem.splitScalar(u8, path, '/');
            var list: std.ArrayListUnmanaged(Segment) = .empty;
            while (it.next()) |seg| {
                if (seg.len > 0 and seg[0] == ':') {
                    try list.append(allocator, .{ .param = seg[1..] });
                } else {
                    try list.append(allocator, .{ .literal = seg });
                }
            }
            return list.toOwnedSlice(allocator);
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
