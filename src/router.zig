const std = @import("std");
const Request = std.http.Server.Request;
const Allocator = std.mem.Allocator;
const HttpRequest = std.http.Server.Request;
const core = @import("core");
const Context = core.Context;
const Response = core.Response;
const ArgsTuple = std.meta.ArgsTuple;
const log = std.log;
const extractor = @import("extractor.zig");
const volt_options = @import("options");

const middleware = if (volt_options.middleware_enabled) @import("middleware/root.zig") else void;
const Middleware = if (volt_options.middleware_enabled) middleware.Middleware else void;
const Next = if (volt_options.middleware_enabled) middleware.Next else void;

pub fn Router(comptime Config: anytype) type {
    const config_info = @typeInfo(@TypeOf(Config));
    const State = if (config_info == .type) Config else Config[0];
    const mws = if (config_info == .type) .{} else Config[1];

    if (comptime !volt_options.middleware_enabled and mws.len > 0) {
        @compileError("Built-in middleware features are not enabled: set 'middleware_enabled' option to 'true' in volt's dependency import");
    }

    return struct {
        const Self = @This();

        state: State,
        routes: std.StringHashMap(Route),
        parametric_routes: std.ArrayList(ParametricRoute),

        const Handler = struct {
            const Self = @This();

            ptr: *const anyopaque,
            execute_fn: *const fn (ptr: *const anyopaque, ctx: Context, state: State) anyerror!Response,

            pub fn init(comptime Fn: type, h: *const anyopaque) @This() {
                const impl = struct {
                    fn exec(ptr: *const anyopaque, ctx: Context, state: State) !Response {
                        var args: ArgsTuple(Fn) = undefined;
                        const type_info = @typeInfo(ArgsTuple(Fn));
                        const field_types = type_info.@"struct".field_types;
                        inline for (field_types, 0..field_types.len) |field_type, i| {
                            switch (field_type) {
                                Context => args[i] = ctx,
                                State => args[i] = state,
                                else => |Arg| {
                                    if (comptime extractor.isExtractor(Arg)) {
                                        args[i] = Arg.init(ctx) catch |err|
                                            return .badRequest(ctx.req_arena, @errorName(err), null);
                                    } else {
                                        @compileError("unable to resolve parameter of type " ++ @typeName(field_type));
                                    }
                                },
                            }
                        }

                        const fun: *const Fn = @ptrCast(@alignCast(ptr));
                        return @call(.auto, fun, args);
                    }
                };

                return .{
                    .ptr = h,
                    .execute_fn = impl.exec,
                };
            }

            pub fn execute(self: *const Handler, ctx: Context, state: State) !Response {
                return self.execute_fn(self.ptr, ctx, state);
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

            for (self.parametric_routes.items) |*p_route| {
                p_route.entry.handlers.deinit();
                allocator.free(p_route.segments);
                allocator.free(p_route.pattern);
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

        /// Registers a HEAD route handler.
        ///
        /// Parameters:
        /// - `allocator`: Memory allocator used for route storage
        /// - `path`: Route path
        /// - `handler`: Function that handles HEAD requests to this path
        pub fn head(self: *Self, allocator: Allocator, path: []const u8, handler: anytype) !void {
            try self.addRoute(allocator, .HEAD, path, makeHandler(handler));
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

        /// Registers a CONNECT route handler.
        ///
        /// Parameters:
        /// - `allocator`: Memory allocator used for route storage
        /// - `path`: Route path
        /// - `handler`: Function that handles CONNECT requests to this path
        pub fn connect(self: *Self, allocator: Allocator, path: []const u8, handler: anytype) !void {
            try self.addRoute(allocator, .CONNECT, path, makeHandler(handler));
        }

        /// Registers an OPTIONS route handler.
        ///
        /// Parameters:
        /// - `allocator`: Memory allocator used for route storage
        /// - `path`: Route path
        /// - `handler`: Function that handles OPTIONS requests to this path
        pub fn options(self: *Self, allocator: Allocator, path: []const u8, handler: anytype) !void {
            try self.addRoute(allocator, .OPTIONS, path, makeHandler(handler));
        }

        /// Registers a TRACE route handler.
        ///
        /// Parameters:
        /// - `allocator`: Memory allocator used for route storage
        /// - `path`: Route path
        /// - `handler`: Function that handles TRACE requests to this path
        pub fn trace(self: *Self, allocator: Allocator, path: []const u8, handler: anytype) !void {
            try self.addRoute(allocator, .TRACE, path, makeHandler(handler));
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

        /// Registers a route handler for a specified HTTP method.
        ///
        /// Parameters:
        /// - `allocator`: Memory allocator used for route storage
        /// - `method`: HTTP method enum value (e.g. .GET, .POST, .OPTIONS, etc.)
        /// - `path`: Route path
        /// - `handler`: Function that handles requests for this method and path
        pub fn route(self: *Self, allocator: Allocator, method: std.http.Method, path: []const u8, handler: anytype) !void {
            try self.addRoute(allocator, method, path, makeHandler(handler));
        }

        pub fn handle(self: *const Self, io: std.Io, allocator: Allocator, conn: std.Io.net.Stream) void {
            defer conn.close(io);

            var read_buffer: [4096]u8 = undefined;
            var stream_buf_reader = conn.reader(io, &read_buffer);

            var write_buffer: [4096]u8 = undefined;
            var stream_buf_writer = conn.writer(io, &write_buffer);

            var http_server = std.http.Server.init(&stream_buf_reader.interface, &stream_buf_writer.interface);
            while (http_server.reader.state == .ready) {
                var req = http_server.receiveHead() catch |err| {
                    if (err == error.HttpConnectionClosing) break;
                    log.err("Failed to receive head: {}", .{err});
                    break;
                };

                self.handleRequest(io, allocator, &req) catch |err| {
                    if (err == error.ConnectionClose) break;
                    req.respond(@errorName(err), .{ .status = .internal_server_error }) catch continue;
                };
            }
        }

        pub fn dispatch(self: *const Self, io: std.Io, allocator: Allocator, req: *HttpRequest) !Response {
            var ctx: Context = .init(
                io,
                allocator,
                req,
            );
            const target = normalizedTarget(ctx.raw_req.head.target);
            const method = ctx.raw_req.head.method;
            var allowed_methods = std.EnumSet(std.http.Method).empty;

            if (self.findHandler(&ctx, target, method, &allowed_methods)) |handler| {
                return handler.execute(ctx, self.state);
            }
            if (allowed_methods.count() > 0) {
                return .text(allocator, .method_not_allowed, "Method Not Allowed", null);
            }
            return .text(allocator, .not_found, "404 Not Found", null);
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
                return self.executeHandler(handler, &ctx);
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
            for (self.parametric_routes.items) |*p_route| {
                if (p_route.match(target)) {
                    if (p_route.entry.handlers.get(method)) |handler| {
                        ctx.route_pattern = p_route.pattern;
                        return handler;
                    }

                    collectAllowedMethods(allowed_methods, p_route.entry.handlers);
                }
            }

            return null;
        }

        fn executeHandler(self: *const Self, handler: Handler, ctx: *Context) !void {
            const res = handler.execute(ctx.*, self.state) catch |err| {
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
            inline for (@typeInfo(std.http.Method).@"enum".field_names) |field_name| {
                const method = @field(std.http.Method, field_name);
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
                for (self.parametric_routes.items) |*p_route| {
                    if (std.mem.eql(u8, p_route.pattern, path)) {
                        try p_route.entry.handlers.put(method, handler);
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
                if (self.routes.getPtr(path)) |route_entry| {
                    try route_entry.handlers.put(method, handler);
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
            return while (it.next()) |seg| {
                if (seg.len > 0 and seg[0] == ':') return true;
            } else false;
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
            const Fn = @TypeOf(handler);
            const func = @typeInfo(Fn);
            if (func != .@"fn") {
                @compileError("handler must be a function");
            }

            const ret = @typeInfo(func.@"fn".return_type.?);
            if (ret != .error_union or ret.error_union.payload != Response) {
                @compileError("handler must return !Response");
            }

            if (comptime volt_options.middleware_enabled and mws.len > 0) {
                const Chained = middleware.Chain(State, mws, handler);
                return .init(@TypeOf(Chained.exec), @ptrCast(&Chained.exec));
            }

            return .init(Fn, @ptrCast(&handler));
        }
    };
}

test "handleRequest returns 404 for unknown route" {
    var router: Router(void) = .init(std.testing.allocator, {});
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
    const TestRouter = Router(void);
    var router: TestRouter = .init(std.testing.allocator, {});
    defer router.deinit(std.testing.allocator);

    const handlers = struct {
        fn postOnly(ctx: Context) !Response {
            return Response.text(ctx.req_arena, .ok, "ok", null);
        }
    };

    try router.post(std.testing.allocator, "/users", handlers.postOnly);

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
    var router: Router(void) = .init(std.testing.allocator, {});
    defer router.deinit(std.testing.allocator);

    const handlers = struct {
        fn putOnly(ctx: Context) !Response {
            return Response.text(ctx.req_arena, .ok, "ok", null);
        }
    };

    try router.put(std.testing.allocator, "/users/:id", handlers.putOnly);

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
    var router: Router(void) = .init(std.testing.allocator, {});
    defer router.deinit(std.testing.allocator);

    const handlers = struct {
        fn exactPost(ctx: Context) !Response {
            return Response.text(ctx.req_arena, .ok, "exact-post", null);
        }

        fn paramGet(ctx: Context) !Response {
            return Response.text(ctx.req_arena, .ok, "param-get", null);
        }
    };

    try router.post(std.testing.allocator, "/users/me", handlers.exactPost);
    try router.get(std.testing.allocator, "/users/:id", handlers.paramGet);

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
    var router: Router(void) = .init(std.testing.allocator, {});
    defer router.deinit(std.testing.allocator);

    const handlers = struct {
        fn exactPost(ctx: Context) !Response {
            return Response.text(ctx.req_arena, .ok, "exact-post", null);
        }

        fn paramPut(ctx: Context) !Response {
            return Response.text(ctx.req_arena, .ok, "param-put", null);
        }
    };

    try router.post(std.testing.allocator, "/users/me", handlers.exactPost);
    try router.put(std.testing.allocator, "/users/:id", handlers.paramPut);

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

test "findHandler prefers exact route over parametric overlap" {
    var router: Router(void) = .init(std.testing.allocator, {});
    defer router.deinit(std.testing.allocator);

    const handlers = struct {
        fn exact(ctx: Context) !Response {
            return Response.text(ctx.req_arena, .ok, "exact", null);
        }

        fn param(ctx: Context) !Response {
            return Response.text(ctx.req_arena, .ok, "param", null);
        }
    };

    try router.get(std.testing.allocator, "/users/:id", handlers.param);
    try router.get(std.testing.allocator, "/users/me", handlers.exact);

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
    var router: Router(void) = .init(std.testing.allocator, {});
    defer router.deinit(std.testing.allocator);

    const handlers = struct {
        fn generic(ctx: Context) !Response {
            return Response.text(ctx.req_arena, .ok, "generic", null);
        }

        fn users(ctx: Context) !Response {
            return Response.text(ctx.req_arena, .ok, "users", null);
        }
    };

    try router.get(std.testing.allocator, "/:entity/:id", handlers.generic);
    try router.get(std.testing.allocator, "/users/:id", handlers.users);

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
    var router: Router(void) = .init(std.testing.allocator, {});
    defer router.deinit(std.testing.allocator);

    const handlers = struct {
        fn duplicate(ctx: Context) !Response {
            return Response.text(ctx.req_arena, .ok, "ok", null);
        }
    };

    try std.testing.expectError(
        error.DuplicateRouteParamName,
        router.get(std.testing.allocator, "/users/:id/orders/:id", handlers.duplicate),
    );
}

test "literal colon segment is treated as exact route" {
    var router: Router(void) = .init(std.testing.allocator, {});
    defer router.deinit(std.testing.allocator);

    const handlers = struct {
        fn literal(ctx: Context) !Response {
            return Response.text(ctx.req_arena, .ok, "literal", null);
        }
    };

    try router.get(std.testing.allocator, "/time/10:30", handlers.literal);

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
    var router: Router(void) = .init(std.testing.allocator, {});
    defer router.deinit(std.testing.allocator);

    const handlers = struct {
        fn owned(ctx: Context) !Response {
            return Response.text(ctx.req_arena, .ok, "owned", null);
        }
    };

    var dynamic_path = [_]u8{ '/', 'd', 'y', 'n' };
    try router.get(std.testing.allocator, dynamic_path[0..], handlers.owned);
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

test "middleware executes in order and modifies response header" {
    if (comptime !volt_options.middleware_enabled) return;

    const mw = struct {
        fn addHeader(ctx: *Context, next: *Next) !Response {
            var res = try next.exec(ctx);
            try res.setHeader(ctx.req_arena, "X-Custom-Middleware", "Active");
            return res;
        }

        fn handler(ctx: Context) !Response {
            return Response.text(ctx.req_arena, .ok, "hello middleware", null);
        }
    };

    var router: Router(.{ void, .{mw.addHeader} }) = .init(std.testing.allocator, {});
    defer router.deinit(std.testing.allocator);

    try router.get(std.testing.allocator, "/test", mw.handler);

    const req_bytes = "GET /test HTTP/1.1\r\n\r\n";
    var stream_buf_reader = std.Io.Reader.fixed(req_bytes);
    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = std.Io.Writer.fixed(&write_buffer);
    var http_server = std.http.Server.init(&stream_buf_reader, &stream_buf_writer);
    var req = try http_server.receiveHead();

    try router.handleRequest(std.testing.io, std.testing.allocator, &req);

    const output = write_buffer[0..stream_buf_writer.end];
    try std.testing.expect(std.mem.find(u8, output, "X-Custom-Middleware: Active") != null);
    try std.testing.expect(std.mem.find(u8, output, "hello middleware") != null);
}

test "built-in requestId and cors middlewares" {
    if (comptime !volt_options.middleware_enabled) return;

    var router: Router(.{ void, .{ middleware.requestId, middleware.cors } }) = .init(std.testing.allocator, {});
    defer router.deinit(std.testing.allocator);

    try router.get(std.testing.allocator, "/ping", struct {
        fn ping(ctx: Context) !Response {
            return Response.text(ctx.req_arena, .ok, "pong", null);
        }
    }.ping);

    const req_bytes = "GET /ping HTTP/1.1\r\nOrigin: https://example.com\r\n\r\n";
    var stream_buf_reader = std.Io.Reader.fixed(req_bytes);
    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = std.Io.Writer.fixed(&write_buffer);
    var http_server = std.http.Server.init(&stream_buf_reader, &stream_buf_writer);
    var req = try http_server.receiveHead();

    try router.handleRequest(std.testing.io, std.testing.allocator, &req);

    const output = write_buffer[0..stream_buf_writer.end];
    try std.testing.expect(std.mem.find(u8, output, "X-Request-ID: req-") != null);
    try std.testing.expect(std.mem.find(u8, output, "Access-Control-Allow-Origin: *") != null);
}

test "recovery middleware intercepts error and returns 500" {
    if (comptime !volt_options.middleware_enabled) return;

    var router: Router(.{ void, .{middleware.recovery} }) = .init(std.testing.allocator, {});
    defer router.deinit(std.testing.allocator);

    try router.get(std.testing.allocator, "/faulty", struct {
        fn faulty(_: Context) !Response {
            return error.DatabaseConnectionFailed;
        }
    }.faulty);

    const req_bytes = "GET /faulty HTTP/1.1\r\n\r\n";
    var stream_buf_reader = std.Io.Reader.fixed(req_bytes);
    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = std.Io.Writer.fixed(&write_buffer);
    var http_server = std.http.Server.init(&stream_buf_reader, &stream_buf_writer);
    var req = try http_server.receiveHead();

    try router.handleRequest(std.testing.io, std.testing.allocator, &req);

    const output = write_buffer[0..stream_buf_writer.end];
    try std.testing.expect(std.mem.find(u8, output, "500 Internal Server Error") != null);
}

test "comptime static middleware chain" {
    if (comptime !volt_options.middleware_enabled) return;

    var router: Router(void) = .init(std.testing.allocator, {});
    defer router.deinit(std.testing.allocator);

    const mw = struct {
        fn addHeader(ctx: *Context, next: *Next) !Response {
            var res = try next.exec(ctx);
            try res.setHeader(ctx.req_arena, "X-Static-Chained", "true");
            return res;
        }

        fn handler(ctx: Context) !Response {
            return Response.text(ctx.req_arena, .ok, "hello static chain", null);
        }
    };

    const chained_handler = middleware.Chain(void, .{mw.addHeader}, mw.handler).exec;
    try router.get(std.testing.allocator, "/static", chained_handler);

    const req_bytes = "GET /static HTTP/1.1\r\n\r\n";
    var stream_buf_reader = std.Io.Reader.fixed(req_bytes);
    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = std.Io.Writer.fixed(&write_buffer);
    var http_server = std.http.Server.init(&stream_buf_reader, &stream_buf_writer);
    var req = try http_server.receiveHead();

    try router.handleRequest(std.testing.io, std.testing.allocator, &req);

    const output = write_buffer[0..stream_buf_writer.end];
    try std.testing.expect(std.mem.find(u8, output, "X-Static-Chained: true") != null);
    try std.testing.expect(std.mem.find(u8, output, "hello static chain") != null);
}
