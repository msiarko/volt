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
///
/// // Stateless handlers for Server(void) should omit state entirely.
/// fn health(ctx: Context) !Response {
///     return Response.ok(ctx.request_allocator, null, null);
/// }
/// ```
pub fn Router(comptime State: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        routes: std.StringHashMap(Route),
        parametric_routes: std.ArrayList(ParametricRoute),
        middleware_factories: std.ArrayList(middleware.MiddlewareFactory),

        const VTable = struct {
            execute: *const fn (*const anyopaque, Context, *State, ?[]const u8, req: *Request) anyerror!Response,
        };

        const Handler = struct {
            ptr: *const anyopaque,
            vtable: VTable,

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

            pub fn execute(self: *const Handler, ctx: Context, state: *State, route_pattern: ?[]const u8, req: *Request) !Response {
                return self.vtable.execute(self.ptr, ctx, state, route_pattern, req);
            }
        };

        const Route = struct {
            handlers: std.AutoHashMap(std.http.Method, Handler),
        };

        const Segment = union(enum) {
            literal: []const u8,
            param: []const u8,
        };

        const ParametricRoute = struct {
            pattern: []const u8,
            segments: []Segment,
            literal_count: usize,
            entry: Route,

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
        /// - `init(ctx: *Context) !Self`
        /// - `handle(self: *const Self, next: *const middleware.Next) !Response`
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
        /// - for `Server(State)`: `fn(ctx: Context, state: *State, ...) !Response`
        /// - for `Server(void)`: `fn(ctx: Context, ...) !Response`
        ///
        /// `*void` state parameters are rejected at compile time for `Server(void)`.
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

        fn parseSegments(allocator: std.mem.Allocator, pattern: []const u8) !struct { segments: []Segment, literal_count: usize } {
            const path = if (pattern.len > 0 and pattern[0] == '/') pattern[1..] else pattern;
            var it = std.mem.splitScalar(u8, path, '/');
            var list: std.ArrayListUnmanaged(Segment) = .empty;
            errdefer list.deinit(allocator);

            var literal_count: usize = 0;
            var seen_params: [8][]const u8 = undefined;
            var seen_params_len: usize = 0;
            while (it.next()) |seg| {
                if (seg.len > 0 and seg[0] == ':') {
                    const name = seg[1..];
                    for (seen_params[0..seen_params_len]) |existing_name| {
                        if (std.mem.eql(u8, existing_name, name)) {
                            return error.DuplicateRouteParamName;
                        }
                    }

                    if (seen_params_len >= seen_params.len) return error.TooManyRouteParams;
                    seen_params[seen_params_len] = name;
                    seen_params_len += 1;
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

            if (comptime State == void) {
                inline for (func_type_info.@"fn".params) |param| {
                    if (param.type) |param_type| {
                        if (param_type == *void) {
                            @compileError("for Server(void), handlers must not declare a *void state parameter; omit the state argument entirely");
                        }
                    }
                }
            }

            return .init(FuncPtr, @ptrCast(handler));
        }
    };
}
