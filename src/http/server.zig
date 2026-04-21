const std = @import("std");
const HttpRequest = std.http.Server.Request;
const Allocator = std.mem.Allocator;
const Router = @import("router.zig").Router;
const IpAddress = std.Io.net.IpAddress;
const ListenOptions = std.Io.net.IpAddress.ListenOptions;
const response = @import("response.zig");
const extract = @import("../extract/root.zig");
const utils = @import("utils.zig");

const context = @import("context.zig");
const Context = context.Context;
const Response = response.Response;

/// Configuration options for the HTTP server, such as timeouts and limits.
pub const ServerOptions = struct {
    shutdown_timeout_seconds: u64 = 2,
};

/// Creates a generic HTTP server type parameterized by application state.
///
/// The State type parameter allows applications to maintain shared state across
/// all request handlers. This state is passed to route handlers and can contain
/// databases, configuration, caches, or any other shared resources.
///
/// Example:
/// ```zig
/// const MyState = struct {
///     database: Database,
///     config: Config,
///     allocator: std.mem.Allocator,
/// };
///
/// const MyServer = Server(MyState);
///
/// Handlers should only allocate request-scoped memory with `ctx.request_allocator`.
/// For state updates that require longer-lived allocations, store an allocator in
/// the state struct itself and free those allocations during your state deinit.
/// ```
pub fn Server(comptime State: type) type {
    return struct {
        const Self = @This();

        const ShutdownWait = union(enum) {
            tasks_done: std.Io.Cancelable!void,
            timeout: std.Io.Cancelable!void,
        };

        io: std.Io,
        state: State,
        options: ServerOptions,

        /// Initializes a new HTTP server instance.
        ///
        /// Parameters:
        /// - `io`: I/O interface for network operations
        /// - `state`: Initial application state
        /// - `options`: Server runtime options
        ///
        /// Returns: A new Server instance ready to listen for connections
        pub fn init(io: std.Io, state: State, options: ServerOptions) !Self {
            return .{
                .io = io,
                .state = state,
                .options = options,
            };
        }

        /// Starts listening for HTTP connections on the specified address.
        ///
        /// This method runs an event loop that accepts incoming connections
        /// and processes them asynchronously. Each connection is handled in
        /// a separate async task.
        ///
        /// Parameters:
        /// - `allocator`: Allocator used for per-request arena allocation
        /// - `address`: Network address to bind to (IP and port)
        /// - `router`: Registered route table used to resolve handlers
        ///
        /// The server will continue running until interrupted or an error occurs.
        pub fn listen(self: *Self, allocator: Allocator, address: IpAddress, router: *const Router(State)) !void {
            var server = try IpAddress.listen(
                &address,
                self.io,
                .{},
            );
            defer server.deinit(self.io);

            var tasks: std.Io.Group = .init;
            errdefer tasks.cancel(self.io);

            var buffer: [32]u8 = undefined;
            var fixed_writer = std.Io.Writer.fixed(&buffer);
            try address.format(&fixed_writer);
            try fixed_writer.flush();

            std.log.info("Server is listening on http://{s}", .{buffer[0..fixed_writer.end]});
            try self.acceptConnections(allocator, router, &server, &tasks);
            const graceful_shutdown_timeout: std.Io.Clock.Duration = .{
                .raw = std.Io.Duration.fromSeconds(@intCast(self.options.shutdown_timeout_seconds)),
                .clock = .real,
            };
            try self.gracefulShutdown(&tasks, graceful_shutdown_timeout);
        }

        fn acceptConnections(self: *Self, allocator: Allocator, router: *const Router(State), server: *std.Io.net.Server, tasks: *std.Io.Group) !void {
            while (true) {
                const conn = server.accept(self.io) catch |err| switch (err) {
                    error.Canceled => return,
                    else => return err,
                };
                tasks.async(self.io, handleConnection, .{ self, allocator, router, conn });
            }
        }

        fn awaitTasks(tasks: *std.Io.Group, io: std.Io) std.Io.Cancelable!void {
            try tasks.await(io);
        }

        fn sleepFor(duration: std.Io.Clock.Duration, io: std.Io) std.Io.Cancelable!void {
            try duration.sleep(io);
        }

        fn gracefulShutdown(self: *Self, tasks: *std.Io.Group, timeout: std.Io.Clock.Duration) !void {
            defer tasks.cancel(self.io);

            var select_buffer: [2]ShutdownWait = undefined;
            var select = std.Io.Select(ShutdownWait).init(self.io, &select_buffer);
            defer select.cancelDiscard();

            select.async(.tasks_done, awaitTasks, .{ tasks, self.io });
            select.async(.timeout, sleepFor, .{ timeout, self.io });

            const result = try select.await();
            switch (result) {
                .tasks_done => |await_result| try await_result,
                .timeout => |timeout_result| {
                    std.log.warn(
                        "Graceful shutdown timeout reached after {}ms; canceling remaining connection tasks",
                        .{timeout.raw.toMilliseconds()},
                    );
                    try timeout_result;
                },
            }
        }

        fn handleConnection(self: *Self, allocator: Allocator, router: *const Router(State), conn: std.Io.net.Stream) void {
            defer conn.close(self.io);

            var read_buffer: [4096]u8 = undefined;
            var stream_buf_reader = conn.reader(self.io, &read_buffer);

            var write_buffer: [4096]u8 = undefined;
            var stream_buf_writer = conn.writer(self.io, &write_buffer);

            var http_server = std.http.Server.init(&stream_buf_reader.interface, &stream_buf_writer.interface);
            while (true) {
                var req = http_server.receiveHead() catch |err| {
                    std.log.err("Failed to receive head: {}", .{err});
                    break;
                };

                var arena = std.heap.ArenaAllocator.init(allocator);
                defer arena.deinit();

                const req_allocator = arena.allocator();
                const ctx: Context = .{
                    .io = self.io,
                    .request_allocator = req_allocator,
                    .request = &req,
                };

                handleRequest(router, ctx, &self.state, &req) catch |err| {
                    if (err == error.ConnectionClose) break;
                    req.respond(@errorName(err), .{ .status = .internal_server_error }) catch continue;
                };
            }
        }

        fn handleRequest(router: *const Router(State), ctx: Context, state: *State, req: *HttpRequest) !void {
            const target = normalizedTarget(req.head.target);
            const method = req.head.method;
            var path_matched = false;
            var allowed_methods = std.EnumSet(std.http.Method).empty;

            if (router.routes.get(target)) |route_entry| {
                path_matched = true;
                if (route_entry.handlers.get(method)) |handler| {
                    return executeHandler(handler, ctx, state, null, req);
                }

                collectAllowedMethods(&allowed_methods, route_entry.handlers);
            }

            for (router.parametric_routes.items) |*route| {
                if (route.match(target)) {
                    path_matched = true;
                    if (route.entry.handlers.get(method)) |handler| {
                        return executeHandler(handler, ctx, state, route.pattern, req);
                    }
                    collectAllowedMethods(&allowed_methods, route.entry.handlers);
                }
            }

            if (path_matched) {
                return respondMethodNotAllowed(req, allowed_methods);
            }

            return respondNotFound(req);
        }

        fn executeHandler(handler: Router(State).Handler, ctx: Context, state: *State, pattern: ?[]const u8, req: *HttpRequest) !void {
            const res = handler.execute(ctx, state, pattern, req) catch |err| {
                if (utils.isMemberOfErrorSet(extract.WebSocketError, err)) return;
                try req.respond(@errorName(err), .{ .status = .internal_server_error });
                return;
            };

            try response.respond(req, res);
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
    };
}

test "handleRequest returns 404 for unknown route" {
    const TestRouter = Router(void);
    const TestServer = Server(void);

    var router: TestRouter = .init(std.testing.allocator);
    defer router.deinit(std.testing.allocator);

    const req_bytes = "GET /missing HTTP/1.1\r\n\r\n";
    var stream_buf_reader = std.Io.Reader.fixed(req_bytes);
    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = std.Io.Writer.fixed(&write_buffer);
    var http_server = std.http.Server.init(&stream_buf_reader, &stream_buf_writer);
    var req = try http_server.receiveHead();

    var state: void = {};
    const ctx: Context = .{
        .io = undefined,
        .request_allocator = std.testing.allocator,
        .request = &req,
    };

    try TestServer.handleRequest(&router, ctx, &state, &req);
    try stream_buf_writer.flush();

    const output = write_buffer[0..stream_buf_writer.end];
    try std.testing.expect(std.mem.find(u8, output, "404") != null);
    try std.testing.expect(std.mem.find(u8, output, "Not Found") != null);
}

test "handleRequest returns 405 for method mismatch" {
    const TestRouter = Router(void);
    const TestServer = Server(void);

    var router: TestRouter = .init(std.testing.allocator);
    defer router.deinit(std.testing.allocator);

    const handlers = struct {
        fn postOnly(ctx: Context) !Response {
            return Response.text(ctx.request_allocator, .ok, "ok", null);
        }
    };

    try router.post(std.testing.allocator, "/users", &handlers.postOnly);

    const req_bytes = "GET /users HTTP/1.1\r\n\r\n";
    var stream_buf_reader = std.Io.Reader.fixed(req_bytes);
    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = std.Io.Writer.fixed(&write_buffer);
    var http_server = std.http.Server.init(&stream_buf_reader, &stream_buf_writer);
    var req = try http_server.receiveHead();

    var state: void = {};
    const ctx: Context = .{
        .io = undefined,
        .request_allocator = std.testing.allocator,
        .request = &req,
    };

    try TestServer.handleRequest(&router, ctx, &state, &req);
    try stream_buf_writer.flush();

    const output = write_buffer[0..stream_buf_writer.end];
    try std.testing.expect(std.mem.find(u8, output, "405") != null);
    try std.testing.expect(std.mem.find(u8, output, "Method Not Allowed") != null);
    try std.testing.expect(std.mem.find(u8, output, "Allow: POST") != null);
}

test "handleRequest returns 405 with Allow header for parametric route mismatch" {
    const TestRouter = Router(void);
    const TestServer = Server(void);

    var router: TestRouter = .init(std.testing.allocator);
    defer router.deinit(std.testing.allocator);

    const handlers = struct {
        fn putOnly(ctx: Context, id: extract.RouteParam("id")) !Response {
            _ = id;
            return Response.text(ctx.request_allocator, .ok, "ok", null);
        }
    };

    try router.put(std.testing.allocator, "/users/:id", &handlers.putOnly);

    const req_bytes = "GET /users/42 HTTP/1.1\r\n\r\n";
    var stream_buf_reader = std.Io.Reader.fixed(req_bytes);
    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = std.Io.Writer.fixed(&write_buffer);
    var http_server = std.http.Server.init(&stream_buf_reader, &stream_buf_writer);
    var req = try http_server.receiveHead();

    var state: void = {};
    const ctx: Context = .{
        .io = undefined,
        .request_allocator = std.testing.allocator,
        .request = &req,
    };

    try TestServer.handleRequest(&router, ctx, &state, &req);
    try stream_buf_writer.flush();

    const output = write_buffer[0..stream_buf_writer.end];
    try std.testing.expect(std.mem.find(u8, output, "405") != null);
    try std.testing.expect(std.mem.find(u8, output, "Method Not Allowed") != null);
    try std.testing.expect(std.mem.find(u8, output, "Allow: PUT") != null);
}

test "handleRequest falls back to parametric method when exact path lacks method" {
    const TestRouter = Router(void);
    const TestServer = Server(void);

    var router: TestRouter = .init(std.testing.allocator);
    defer router.deinit(std.testing.allocator);

    const handlers = struct {
        fn exactPost(ctx: Context) !Response {
            return Response.text(ctx.request_allocator, .ok, "exact-post", null);
        }

        fn paramGet(ctx: Context, id: extract.RouteParam("id")) !Response {
            _ = id;
            return Response.text(ctx.request_allocator, .ok, "param-get", null);
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

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var state: void = {};
    const ctx: Context = .{
        .io = undefined,
        .request_allocator = arena.allocator(),
        .request = &req,
    };

    try TestServer.handleRequest(&router, ctx, &state, &req);
    try stream_buf_writer.flush();

    const output = write_buffer[0..stream_buf_writer.end];
    try std.testing.expect(std.mem.find(u8, output, "200") != null);
    try std.testing.expect(std.mem.find(u8, output, "param-get") != null);
    try std.testing.expect(std.mem.find(u8, output, "405") == null);
}

test "handleRequest returns combined Allow header for overlapping path matches" {
    const TestRouter = Router(void);
    const TestServer = Server(void);

    var router: TestRouter = .init(std.testing.allocator);
    defer router.deinit(std.testing.allocator);

    const handlers = struct {
        fn exactPost(ctx: Context) !Response {
            return Response.text(ctx.request_allocator, .ok, "exact-post", null);
        }

        fn paramPut(ctx: Context, id: extract.RouteParam("id")) !Response {
            _ = id;
            return Response.text(ctx.request_allocator, .ok, "param-put", null);
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

    var state: void = {};
    const ctx: Context = .{
        .io = undefined,
        .request_allocator = std.testing.allocator,
        .request = &req,
    };

    try TestServer.handleRequest(&router, ctx, &state, &req);
    try stream_buf_writer.flush();

    const output = write_buffer[0..stream_buf_writer.end];
    try std.testing.expect(std.mem.find(u8, output, "405") != null);
    try std.testing.expect(std.mem.find(u8, output, "Allow:") != null);
    try std.testing.expect(std.mem.find(u8, output, "POST") != null);
    try std.testing.expect(std.mem.find(u8, output, "PUT") != null);
}

test "handleRequest ignores websocket extractor errors" {
    const TestRouter = Router(void);
    const TestServer = Server(void);

    var router: TestRouter = .init(std.testing.allocator);
    defer router.deinit(std.testing.allocator);

    const handlers = struct {
        fn noop(socket: *std.http.Server.WebSocket) !void {
            _ = socket;
        }

        fn websocketRoute(ctx: Context, ws: extract.WebSocket) !Response {
            try ws.onConnected(noop, .{});
            return Response.ok(ctx.request_allocator, null, null);
        }
    };

    try router.get(std.testing.allocator, "/ws", &handlers.websocketRoute);

    const req_bytes = "GET /ws HTTP/1.1\r\n\r\n";
    var stream_buf_reader = std.Io.Reader.fixed(req_bytes);
    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = std.Io.Writer.fixed(&write_buffer);
    var http_server = std.http.Server.init(&stream_buf_reader, &stream_buf_writer);
    var req = try http_server.receiveHead();

    var state: void = {};
    const ctx: Context = .{
        .io = undefined,
        .request_allocator = std.testing.allocator,
        .request = &req,
    };

    try TestServer.handleRequest(&router, ctx, &state, &req);
    try stream_buf_writer.flush();
    try std.testing.expectEqual(@as(usize, 0), stream_buf_writer.end);
}

test "handleRequest prefers exact route over parametric overlap" {
    const TestRouter = Router(void);
    const TestServer = Server(void);

    var router: TestRouter = .init(std.testing.allocator);
    defer router.deinit(std.testing.allocator);

    const handlers = struct {
        fn exact(ctx: Context) !Response {
            return Response.text(ctx.request_allocator, .ok, "exact", null);
        }

        fn param(ctx: Context, id: extract.RouteParam("id")) !Response {
            _ = id;
            return Response.text(ctx.request_allocator, .ok, "param", null);
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

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var state: void = {};
    const ctx: Context = .{
        .io = undefined,
        .request_allocator = arena.allocator(),
        .request = &req,
    };

    try TestServer.handleRequest(&router, ctx, &state, &req);
    try stream_buf_writer.flush();

    const output = write_buffer[0..stream_buf_writer.end];
    try std.testing.expect(std.mem.find(u8, output, "exact") != null);
    try std.testing.expect(std.mem.find(u8, output, "param") == null);
}

test "handleRequest applies parametric precedence by literal segments" {
    const TestRouter = Router(void);
    const TestServer = Server(void);

    var router: TestRouter = .init(std.testing.allocator);
    defer router.deinit(std.testing.allocator);

    const handlers = struct {
        fn generic(ctx: Context, entity: extract.RouteParam("entity"), id: extract.RouteParam("id")) !Response {
            _ = entity;
            _ = id;
            return Response.text(ctx.request_allocator, .ok, "generic", null);
        }

        fn users(ctx: Context, id: extract.RouteParam("id")) !Response {
            _ = id;
            return Response.text(ctx.request_allocator, .ok, "users", null);
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

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var state: void = {};
    const ctx: Context = .{
        .io = undefined,
        .request_allocator = arena.allocator(),
        .request = &req,
    };

    try TestServer.handleRequest(&router, ctx, &state, &req);
    try stream_buf_writer.flush();

    const output = write_buffer[0..stream_buf_writer.end];
    try std.testing.expect(std.mem.find(u8, output, "users") != null);
    try std.testing.expect(std.mem.find(u8, output, "generic") == null);
}

test "router rejects duplicate placeholder names in same route" {
    const TestRouter = Router(void);
    var router: TestRouter = .init(std.testing.allocator);
    defer router.deinit(std.testing.allocator);

    const handlers = struct {
        fn duplicate(ctx: Context, id: extract.RouteParam("id")) !Response {
            _ = id;
            return Response.text(ctx.request_allocator, .ok, "ok", null);
        }
    };

    try std.testing.expectError(
        error.DuplicateRouteParamName,
        router.get(std.testing.allocator, "/users/:id/orders/:id", &handlers.duplicate),
    );
}

test "literal colon segment is treated as exact route" {
    const TestRouter = Router(void);
    const TestServer = Server(void);

    var router: TestRouter = .init(std.testing.allocator);
    defer router.deinit(std.testing.allocator);

    const handlers = struct {
        fn literal(ctx: Context) !Response {
            return Response.text(ctx.request_allocator, .ok, "literal", null);
        }
    };

    try router.get(std.testing.allocator, "/time/10:30", &handlers.literal);

    const req_bytes = "GET /time/10:30 HTTP/1.1\r\n\r\n";
    var stream_buf_reader = std.Io.Reader.fixed(req_bytes);
    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = std.Io.Writer.fixed(&write_buffer);
    var http_server = std.http.Server.init(&stream_buf_reader, &stream_buf_writer);
    var req = try http_server.receiveHead();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var state: void = {};
    const ctx: Context = .{
        .io = undefined,
        .request_allocator = arena.allocator(),
        .request = &req,
    };

    try TestServer.handleRequest(&router, ctx, &state, &req);
    try stream_buf_writer.flush();

    const output = write_buffer[0..stream_buf_writer.end];
    try std.testing.expect(std.mem.find(u8, output, "literal") != null);
}

test "router duplicates route path keys on registration" {
    const TestRouter = Router(void);
    const TestServer = Server(void);

    var router: TestRouter = .init(std.testing.allocator);
    defer router.deinit(std.testing.allocator);

    const handlers = struct {
        fn owned(ctx: Context) !Response {
            return Response.text(ctx.request_allocator, .ok, "owned", null);
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

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var state: void = {};
    const ctx: Context = .{
        .io = undefined,
        .request_allocator = arena.allocator(),
        .request = &req,
    };

    try TestServer.handleRequest(&router, ctx, &state, &req);
    try stream_buf_writer.flush();

    const output = write_buffer[0..stream_buf_writer.end];
    try std.testing.expect(std.mem.find(u8, output, "owned") != null);
}
