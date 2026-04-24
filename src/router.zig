const std = @import("std");
const Request = std.http.Server.Request;
const Allocator = std.mem.Allocator;
const HttpRequest = std.http.Server.Request;
const Response = @import("Response.zig");
const WebSocket = @import("extractors/WebSocket.zig");
const Context = @import("Context.zig");
const ArgsTuple = std.meta.ArgsTuple;
const FnParam = std.builtin.Type.Fn.Param;

const JsonResolver = @import("extractors/json.zig").Resolver;
const QueryResolver = @import("extractors/query.zig").Resolver;
const TypedQueryResolver = @import("extractors/typed_query.zig").Resolver;
const HeaderResolver = @import("extractors/header.zig").Resolver;
const RouteParamResolver = @import("extractors/route_param.zig").Resolver;
const FormResolver = @import("extractors/form.zig").Resolver;

const extractor_resolvers = .{
    JsonResolver,
    QueryResolver,
    TypedQueryResolver,
    HeaderResolver,
    FormResolver,
    RouteParamResolver,
};

fn matches(comptime Extractor: type, comptime EXTRACTOR_ID: []const u8) bool {
    if (!@hasDecl(Extractor, "ID")) return false;
    return std.mem.eql(u8, @field(Extractor, "ID"), EXTRACTOR_ID);
}

fn getArgsTypes(func_params: []const FnParam) []const type {
    comptime var func_param_types: [func_params.len]type = undefined;
    inline for (func_params, 0..) |param_type, i| {
        func_param_types[i] = param_type.type.?;
    }

    return &func_param_types;
}

pub fn Router(comptime State: type) type {
    return struct {
        const Self = @This();

        state: State,
        routes: std.StringHashMap(Route),
        parametric_routes: std.ArrayList(ParametricRoute),

        const VTable = struct {
            execute: *const fn (*const anyopaque, Context, State) anyerror!Response,
        };

        const Handler = struct {
            const Self = @This();

            ptr: *const anyopaque,
            vtable: VTable,

            pub fn init(comptime FnPtr: type, h: *const anyopaque) @This() {
                const Fn = @typeInfo(FnPtr).pointer.child;
                const impl = struct {
                    fn exec(ptr: *const anyopaque, ctx: Context, state: State) !Response {
                        var args: ArgsTuple(Fn) = undefined;
                        const args_fields = comptime std.meta.fields(ArgsTuple(Fn));
                        inline for (args_fields, 0..args_fields.len) |field, i| {
                            switch (field.type) {
                                Context => args[i] = ctx,
                                State => args[i] = state,
                                WebSocket => args[i] = .{ .result = WebSocket.init(ctx) },
                                else => |Arg| {
                                    comptime var resolved = false;
                                    inline for (extractor_resolvers) |Resolver| {
                                        if (!resolved and comptime matches(Arg, Resolver.ID)) {
                                            args[i] = Resolver.resolve(Arg, ctx);
                                            resolved = true;
                                        }
                                    }

                                    if (!resolved) {
                                        @compileError("unable to resolve parameter of type " ++ @typeName(field.type));
                                    }
                                },
                            }
                        }

                        const fun: FnPtr = @ptrCast(@alignCast(ptr));
                        return @call(.auto, fun, args);
                    }
                };

                return .{
                    .ptr = h,
                    .vtable = .{
                        .execute = impl.exec,
                    },
                };
            }

            pub fn execute(self: *const Handler, ctx: Context, state: State) !Response {
                return self.vtable.execute(self.ptr, ctx, state);
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
            const Self = @This();

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
        /// - `state`: Shared application state value passed to handlers
        ///
        /// Returns: Initialized router ready to register routes
        pub fn init(allocator: Allocator, state: State) Self {
            return .{
                .state = state,
                .routes = .init(allocator),
                .parametric_routes = .empty,
            };
        }

        /// Cleans up router resources.
        ///
        /// This method should be called when the router is no longer needed
        /// to free all allocated route handlers and mappings.
        pub fn deinit(self: *Self, allocator: Allocator) void {
            var it = self.routes.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.handlers.deinit();
                allocator.free(entry.key_ptr.*);
            }
            self.routes.deinit();

            for (self.parametric_routes.items) |*route| {
                route.entry.handlers.deinit();
                allocator.free(route.segments);
                allocator.free(route.pattern);
            }
            self.parametric_routes.deinit(allocator);
        }

        /// Registers a GET route handler.
        ///
        /// Parameters:
        /// - `allocator`: Memory allocator used for route storage
        /// - `path`: Route path (e.g., "/users", "/api/v1/data")
        /// - `handler`: Function that handles GET requests to this path
        pub fn get(self: *Self, allocator: Allocator, path: []const u8, handler: anytype) !void {
            try self.addRoute(allocator, .GET, path, makeHandler(handler));
        }

        /// Registers a POST route handler.
        ///
        /// Parameters:
        /// - `allocator`: Memory allocator used for route storage
        /// - `path`: Route path
        /// - `handler`: Function that handles POST requests to this path
        pub fn post(self: *Self, allocator: Allocator, path: []const u8, handler: anytype) !void {
            try self.addRoute(allocator, .POST, path, makeHandler(handler));
        }

        /// Registers a PUT route handler.
        ///
        /// Parameters:
        /// - `allocator`: Memory allocator used for route storage
        /// - `path`: Route path
        /// - `handler`: Function that handles PUT requests to this path
        pub fn put(self: *Self, allocator: Allocator, path: []const u8, handler: anytype) !void {
            try self.addRoute(allocator, .PUT, path, makeHandler(handler));
        }

        /// Registers a DELETE route handler.
        ///
        /// Parameters:
        /// - `allocator`: Memory allocator used for route storage
        /// - `path`: Route path
        /// - `handler`: Function that handles DELETE requests to this path
        pub fn delete(self: *Self, allocator: Allocator, path: []const u8, handler: anytype) !void {
            try self.addRoute(allocator, .DELETE, path, makeHandler(handler));
        }

        /// Registers a PATCH route handler.
        ///
        /// Parameters:
        /// - `allocator`: Memory allocator used for route storage
        /// - `path`: Route path
        /// - `handler`: Function that handles PATCH requests to this path
        pub fn patch(self: *Self, allocator: Allocator, path: []const u8, handler: anytype) !void {
            try self.addRoute(allocator, .PATCH, path, makeHandler(handler));
        }

        pub fn handle(self: *const Self, io: std.Io, allocator: Allocator, conn: std.Io.net.Stream) void {
            defer conn.close(io);

            var read_buffer: [4096]u8 = undefined;
            var stream_buf_reader = conn.reader(io, &read_buffer);

            var write_buffer: [4096]u8 = undefined;
            var stream_buf_writer = conn.writer(io, &write_buffer);

            var http_server = std.http.Server.init(&stream_buf_reader.interface, &stream_buf_writer.interface);
            while (true) {
                var req = http_server.receiveHead() catch |err| {
                    std.log.err("Failed to receive head: {}", .{err});
                    break;
                };

                self.handleRequest(io, allocator, &req) catch |err| {
                    if (err == error.ConnectionClose) break;
                    req.respond(@errorName(err), .{ .status = .internal_server_error }) catch continue;
                };
            }
        }

        fn handleRequest(self: *const Self, io: std.Io, allocator: Allocator, req: *HttpRequest) !void {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();

            var ctx: Context = .init(
                io,
                arena.allocator(),
                req,
            );

            const target = normalizedTarget(ctx.raw_req.head.target);
            const method = ctx.raw_req.head.method;
            var allowed_methods = std.EnumSet(std.http.Method).empty;

            if (self.findHandler(&ctx, target, method, &allowed_methods)) |handler| {
                return executeHandler(handler, ctx, self.state);
            }

            if (allowed_methods.count() > 0) {
                return respondMethodNotAllowed(ctx.raw_req, allowed_methods);
            }

            return respondNotFound(ctx.raw_req);
        }

        fn findHandler(
            self: *const Self,
            ctx: *Context,
            target: []const u8,
            method: std.http.Method,
            allowed_methods: *std.EnumSet(std.http.Method),
        ) ?Handler {
            if (self.findRouteHandler(target, method, allowed_methods)) |handler| {
                return handler;
            }

            if (self.findParametricRouteHandler(ctx, target, method, allowed_methods)) |handler| {
                return handler;
            }

            return null;
        }

        fn findRouteHandler(
            self: *const Self,
            target: []const u8,
            method: std.http.Method,
            allowed_methods: *std.EnumSet(std.http.Method),
        ) ?Handler {
            if (self.routes.get(target)) |route_entry| {
                if (route_entry.handlers.get(method)) |handler| {
                    return handler;
                }

                collectAllowedMethods(allowed_methods, route_entry.handlers);
            }

            return null;
        }

        fn findParametricRouteHandler(
            self: *const Self,
            ctx: *Context,
            target: []const u8,
            method: std.http.Method,
            allowed_methods: *std.EnumSet(std.http.Method),
        ) ?Handler {
            for (self.parametric_routes.items) |*route| {
                if (route.match(target)) {
                    if (route.entry.handlers.get(method)) |handler| {
                        ctx.route_pattern = route.pattern;
                        return handler;
                    }

                    collectAllowedMethods(allowed_methods, route.entry.handlers);
                }
            }

            return null;
        }

        fn executeHandler(handler: Router(State).Handler, ctx: Context, state: State) !void {
            const res = handler.execute(ctx, state) catch |err| {
                if (isMemberOfErrorSet(WebSocket.WebSocketError, err)) return;
                try ctx.raw_req.respond(@errorName(err), .{ .status = .internal_server_error });
                return;
            };

            try res.send(ctx.raw_req);
        }

        fn normalizedTarget(target: []const u8) []const u8 {
            if (std.mem.findScalar(u8, target, '?')) |idx| {
                return target[0..idx];
            }

            return target;
        }

        fn respondNotFound(req: *HttpRequest) !void {
            return req.respond("Not Found", .{ .status = .not_found });
        }

        fn collectAllowedMethods(methods: *std.EnumSet(std.http.Method), handlers: anytype) void {
            var it = handlers.iterator();
            while (it.next()) |entry| {
                methods.insert(entry.key_ptr.*);
            }
        }

        fn buildAllowHeaderValue(buf: *[128]u8, methods: std.EnumSet(std.http.Method)) []u8 {
            var writer = std.Io.Writer.fixed(buf);
            var first = true;
            inline for (std.meta.fields(std.http.Method)) |field| {
                const method = @field(std.http.Method, field.name);
                if (methods.contains(method)) {
                    if (!first) {
                        writer.writeAll(", ") catch unreachable;
                    }

                    first = false;
                    writer.writeAll(@tagName(method)) catch unreachable;
                }
            }

            return writer.buffer[0..writer.end];
        }

        fn respondMethodNotAllowed(req: *HttpRequest, methods: std.EnumSet(std.http.Method)) !void {
            var buf: [128]u8 = undefined;
            const allow = buildAllowHeaderValue(&buf, methods);

            const extra_headers = [_]std.http.Header{
                .{ .name = "Allow", .value = allow },
            };

            return req.respond("Method Not Allowed", .{
                .status = .method_not_allowed,
                .extra_headers = &extra_headers,
            });
        }

        fn addRoute(self: *Self, allocator: Allocator, method: std.http.Method, path: []const u8, handler: Handler) !void {
            if (isParametricPath(path)) {
                for (self.parametric_routes.items) |*route| {
                    if (std.mem.eql(u8, route.pattern, path)) {
                        try route.entry.handlers.put(method, handler);
                        return;
                    }
                }

                const parsed = try parseSegments(allocator, path);
                errdefer allocator.free(parsed.segments);

                const owned_pattern = try allocator.dupe(u8, path);
                errdefer allocator.free(owned_pattern);

                var entry: Route = .{ .handlers = .init(allocator) };
                errdefer entry.handlers.deinit();

                try entry.handlers.put(method, handler);

                var insert_index = self.parametric_routes.items.len;
                for (self.parametric_routes.items, 0..) |existing, i| {
                    if (parsed.literal_count > existing.literal_count) {
                        insert_index = i;
                        break;
                    }
                }

                try self.parametric_routes.insert(allocator, insert_index, .{
                    .pattern = owned_pattern,
                    .segments = parsed.segments,
                    .literal_count = parsed.literal_count,
                    .entry = entry,
                });
            } else {
                if (self.routes.getPtr(path)) |route| {
                    try route.handlers.put(method, handler);
                } else {
                    const owned_path = try allocator.dupe(u8, path);
                    errdefer allocator.free(owned_path);

                    var entry: Route = .{ .handlers = .init(allocator) };
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

        fn parseSegments(allocator: Allocator, pattern: []const u8) !struct { segments: []Segment, literal_count: usize } {
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
            const FnPtr = @TypeOf(handler);
            const func_ptr_info = @typeInfo(FnPtr);
            if (func_ptr_info != .pointer or !func_ptr_info.pointer.is_const) {
                @compileError("handler must be a const pointer type");
            }

            const func_type_info = @typeInfo(std.meta.Child(FnPtr));
            if (func_type_info != .@"fn") {
                @compileError("handler must be a const pointer type to a function");
            }

            const ret_type_info = @typeInfo(func_type_info.@"fn".return_type.?);
            if (ret_type_info != .error_union or ret_type_info.error_union.payload != Response) {
                @compileError("handler must return !Response");
            }

            return .init(FnPtr, @ptrCast(handler));
        }
    };
}

fn isMemberOfErrorSet(comptime T: type, err: anyerror) bool {
    const info = @typeInfo(T);
    if (info != .error_set) @compileError("T should be an error set");

    const error_set = info.error_set orelse return false;
    inline for (error_set) |err_field| {
        if (err == @field(T, err_field.name)) return true;
    }

    return false;
}

const TestRouter = Router(void);
const RouteParam = @import("extractors/route_param.zig").RouteParam;

test "isMemberOfErrorSet returns true for member" {
    const AppError = error{ NotFound, InvalidPayload };
    try std.testing.expect(isMemberOfErrorSet(AppError, error.NotFound));
}

test "isMemberOfErrorSet returns false for non-member" {
    const AppError = error{ NotFound, InvalidPayload };
    try std.testing.expect(!isMemberOfErrorSet(AppError, error.OutOfMemory));
}

test "isMemberOfErrorSet works with another error set" {
    const NetworkError = error{ Timeout, ConnectionReset };
    try std.testing.expect(isMemberOfErrorSet(NetworkError, error.Timeout));
    try std.testing.expect(!isMemberOfErrorSet(NetworkError, error.NotFound));
}

test "handleRequest returns 404 for unknown route" {
    var router: TestRouter = .init(std.testing.allocator, {});
    defer router.deinit(std.testing.allocator);

    const req_bytes = "GET /missing HTTP/1.1\r\n\r\n";
    var stream_buf_reader = std.Io.Reader.fixed(req_bytes);
    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = std.Io.Writer.fixed(&write_buffer);
    var http_server = std.http.Server.init(&stream_buf_reader, &stream_buf_writer);
    var req = try http_server.receiveHead();

    try router.handleRequest(std.testing.io, std.testing.allocator, &req);

    const output = write_buffer[0..stream_buf_writer.end];
    try std.testing.expect(std.mem.find(u8, output, "404") != null);
    try std.testing.expect(std.mem.find(u8, output, "Not Found") != null);
}

test "handleRequest returns 405 for method mismatch" {
    var router: TestRouter = .init(std.testing.allocator, {});
    defer router.deinit(std.testing.allocator);

    const handlers = struct {
        fn postOnly(ctx: Context) !Response {
            return Response.text(ctx.req_arena, .ok, "ok", null);
        }
    };

    try router.post(std.testing.allocator, "/users", &handlers.postOnly);

    const req_bytes = "GET /users HTTP/1.1\r\n\r\n";
    var stream_buf_reader = std.Io.Reader.fixed(req_bytes);
    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = std.Io.Writer.fixed(&write_buffer);
    var http_server = std.http.Server.init(&stream_buf_reader, &stream_buf_writer);
    var req = try http_server.receiveHead();

    try router.handleRequest(std.testing.io, std.testing.allocator, &req);

    const output = write_buffer[0..stream_buf_writer.end];
    try std.testing.expect(std.mem.find(u8, output, "405") != null);
    try std.testing.expect(std.mem.find(u8, output, "Method Not Allowed") != null);
    try std.testing.expect(std.mem.find(u8, output, "Allow: POST") != null);
}

test "handleRequest returns 405 with Allow header for parametric route mismatch" {
    var router: TestRouter = .init(std.testing.allocator, {});
    defer router.deinit(std.testing.allocator);

    const handlers = struct {
        fn putOnly(ctx: Context, id: RouteParam("id")) !Response {
            _ = id;
            return Response.text(ctx.req_arena, .ok, "ok", null);
        }
    };

    try router.put(std.testing.allocator, "/users/:id", &handlers.putOnly);

    const req_bytes = "GET /users/42 HTTP/1.1\r\n\r\n";
    var stream_buf_reader = std.Io.Reader.fixed(req_bytes);
    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = std.Io.Writer.fixed(&write_buffer);
    var http_server = std.http.Server.init(&stream_buf_reader, &stream_buf_writer);
    var req = try http_server.receiveHead();

    try router.handleRequest(std.testing.io, std.testing.allocator, &req);

    const output = write_buffer[0..stream_buf_writer.end];
    try std.testing.expect(std.mem.find(u8, output, "405") != null);
    try std.testing.expect(std.mem.find(u8, output, "Method Not Allowed") != null);
    try std.testing.expect(std.mem.find(u8, output, "Allow: PUT") != null);
}

test "handleRequest falls back to parametric method when exact path lacks method" {
    var router: TestRouter = .init(std.testing.allocator, {});
    defer router.deinit(std.testing.allocator);

    const handlers = struct {
        fn exactPost(ctx: Context) !Response {
            return Response.text(ctx.req_arena, .ok, "exact-post", null);
        }

        fn paramGet(ctx: Context, id: RouteParam("id")) !Response {
            _ = id;
            return Response.text(ctx.req_arena, .ok, "param-get", null);
        }
    };

    try router.post(std.testing.allocator, "/users/me", &handlers.exactPost);
    try router.get(std.testing.allocator, "/users/:id", &handlers.paramGet);

    const req_bytes = "GET /users/me HTTP/1.1\r\n\r\n";
    var stream_buf_reader = std.Io.Reader.fixed(req_bytes);
    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = std.Io.Writer.fixed(&write_buffer);
    var http_server = std.http.Server.init(&stream_buf_reader, &stream_buf_writer);
    var req = try http_server.receiveHead();

    try router.handleRequest(std.testing.io, std.testing.allocator, &req);

    const output = write_buffer[0..stream_buf_writer.end];
    try std.testing.expect(std.mem.find(u8, output, "200") != null);
    try std.testing.expect(std.mem.find(u8, output, "param-get") != null);
    try std.testing.expect(std.mem.find(u8, output, "405") == null);
}

test "handleRequest returns combined Allow header for overlapping path matches" {
    var router: TestRouter = .init(std.testing.allocator, {});
    defer router.deinit(std.testing.allocator);

    const handlers = struct {
        fn exactPost(ctx: Context) !Response {
            return Response.text(ctx.req_arena, .ok, "exact-post", null);
        }

        fn paramPut(ctx: Context, id: RouteParam("id")) !Response {
            _ = id;
            return Response.text(ctx.req_arena, .ok, "param-put", null);
        }
    };

    try router.post(std.testing.allocator, "/users/me", &handlers.exactPost);
    try router.put(std.testing.allocator, "/users/:id", &handlers.paramPut);

    const req_bytes = "GET /users/me HTTP/1.1\r\n\r\n";
    var stream_buf_reader = std.Io.Reader.fixed(req_bytes);
    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = std.Io.Writer.fixed(&write_buffer);
    var http_server = std.http.Server.init(&stream_buf_reader, &stream_buf_writer);
    var req = try http_server.receiveHead();

    try router.handleRequest(std.testing.io, std.testing.allocator, &req);

    const output = write_buffer[0..stream_buf_writer.end];
    try std.testing.expect(std.mem.find(u8, output, "405") != null);
    try std.testing.expect(std.mem.find(u8, output, "Allow:") != null);
    try std.testing.expect(std.mem.find(u8, output, "POST") != null);
    try std.testing.expect(std.mem.find(u8, output, "PUT") != null);
}

test "handleRequest ignores websocket extractor errors" {
    var router: TestRouter = .init(std.testing.allocator, {});
    defer router.deinit(std.testing.allocator);

    const handlers = struct {
        fn noop(socket: *std.http.Server.WebSocket) !void {
            _ = socket;
        }

        fn websocketRoute(ctx: Context, ws: WebSocket) !Response {
            try ws.onConnected(noop, .{});
            return Response.ok(ctx.req_arena, null, null);
        }
    };

    try router.get(std.testing.allocator, "/ws", &handlers.websocketRoute);

    const req_bytes = "GET /ws HTTP/1.1\r\n\r\n";
    var stream_buf_reader = std.Io.Reader.fixed(req_bytes);
    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = std.Io.Writer.fixed(&write_buffer);
    var http_server = std.http.Server.init(&stream_buf_reader, &stream_buf_writer);
    var req = try http_server.receiveHead();

    try router.handleRequest(std.testing.io, std.testing.allocator, &req);

    try std.testing.expectEqual(@as(usize, 0), stream_buf_writer.end);
}

test "findHandler prefers exact route over parametric overlap" {
    var router: TestRouter = .init(std.testing.allocator, {});
    defer router.deinit(std.testing.allocator);

    const handlers = struct {
        fn exact(ctx: Context) !Response {
            return Response.text(ctx.req_arena, .ok, "exact", null);
        }

        fn param(ctx: Context, id: RouteParam("id")) !Response {
            _ = id;
            return Response.text(ctx.req_arena, .ok, "param", null);
        }
    };

    try router.get(std.testing.allocator, "/users/:id", &handlers.param);
    try router.get(std.testing.allocator, "/users/me", &handlers.exact);

    const req_bytes = "GET /users/me HTTP/1.1\r\n\r\n";
    var stream_buf_reader = std.Io.Reader.fixed(req_bytes);
    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = std.Io.Writer.fixed(&write_buffer);
    var http_server = std.http.Server.init(&stream_buf_reader, &stream_buf_writer);
    var req = try http_server.receiveHead();

    try router.handleRequest(std.testing.io, std.testing.allocator, &req);

    const output = write_buffer[0..stream_buf_writer.end];
    try std.testing.expect(std.mem.find(u8, output, "exact") != null);
    try std.testing.expect(std.mem.find(u8, output, "param") == null);
}

test "handleRequest applies parametric precedence by literal segments" {
    var router: TestRouter = .init(std.testing.allocator, {});
    defer router.deinit(std.testing.allocator);

    const handlers = struct {
        fn generic(ctx: Context, entity: RouteParam("entity"), id: RouteParam("id")) !Response {
            _ = entity;
            _ = id;
            return Response.text(ctx.req_arena, .ok, "generic", null);
        }

        fn users(ctx: Context, id: RouteParam("id")) !Response {
            _ = id;
            return Response.text(ctx.req_arena, .ok, "users", null);
        }
    };

    try router.get(std.testing.allocator, "/:entity/:id", &handlers.generic);
    try router.get(std.testing.allocator, "/users/:id", &handlers.users);

    const req_bytes = "GET /users/42 HTTP/1.1\r\n\r\n";
    var stream_buf_reader = std.Io.Reader.fixed(req_bytes);
    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = std.Io.Writer.fixed(&write_buffer);
    var http_server = std.http.Server.init(&stream_buf_reader, &stream_buf_writer);
    var req = try http_server.receiveHead();

    try router.handleRequest(std.testing.io, std.testing.allocator, &req);

    const output = write_buffer[0..stream_buf_writer.end];
    try std.testing.expect(std.mem.find(u8, output, "users") != null);
    try std.testing.expect(std.mem.find(u8, output, "generic") == null);
}

test "router rejects duplicate placeholder names in same route" {
    var router: TestRouter = .init(std.testing.allocator, {});
    defer router.deinit(std.testing.allocator);

    const handlers = struct {
        fn duplicate(ctx: Context, id: RouteParam("id")) !Response {
            _ = id;
            return Response.text(ctx.req_arena, .ok, "ok", null);
        }
    };

    try std.testing.expectError(
        error.DuplicateRouteParamName,
        router.get(std.testing.allocator, "/users/:id/orders/:id", &handlers.duplicate),
    );
}

test "literal colon segment is treated as exact route" {
    var router: TestRouter = .init(std.testing.allocator, {});
    defer router.deinit(std.testing.allocator);

    const handlers = struct {
        fn literal(ctx: Context) !Response {
            return Response.text(ctx.req_arena, .ok, "literal", null);
        }
    };

    try router.get(std.testing.allocator, "/time/10:30", &handlers.literal);

    const req_bytes = "GET /time/10:30 HTTP/1.1\r\n\r\n";
    var stream_buf_reader = std.Io.Reader.fixed(req_bytes);
    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = std.Io.Writer.fixed(&write_buffer);
    var http_server = std.http.Server.init(&stream_buf_reader, &stream_buf_writer);
    var req = try http_server.receiveHead();

    try router.handleRequest(std.testing.io, std.testing.allocator, &req);

    const output = write_buffer[0..stream_buf_writer.end];
    try std.testing.expect(std.mem.find(u8, output, "literal") != null);
}

test "router duplicates route path keys on registration" {
    var router: TestRouter = .init(std.testing.allocator, {});
    defer router.deinit(std.testing.allocator);

    const handlers = struct {
        fn owned(ctx: Context) !Response {
            return Response.text(ctx.req_arena, .ok, "owned", null);
        }
    };

    var dynamic_path = [_]u8{ '/', 'd', 'y', 'n' };
    try router.get(std.testing.allocator, dynamic_path[0..], &handlers.owned);
    dynamic_path[1] = 'x';

    const req_bytes = "GET /dyn HTTP/1.1\r\n\r\n";
    var stream_buf_reader = std.Io.Reader.fixed(req_bytes);
    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = std.Io.Writer.fixed(&write_buffer);
    var http_server = std.http.Server.init(&stream_buf_reader, &stream_buf_writer);
    var req = try http_server.receiveHead();

    try router.handleRequest(std.testing.io, std.testing.allocator, &req);

    const output = write_buffer[0..stream_buf_writer.end];
    try std.testing.expect(std.mem.find(u8, output, "owned") != null);
}
