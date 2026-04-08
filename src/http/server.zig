//! HTTP Server implementation for the Volt web library.
//!
//! This module provides a generic HTTP server that can handle requests asynchronously
//! and route them through a configured router. The server supports WebSocket upgrades
//! and provides a context for request handling.

const std = @import("std");
const options = @import("options");
const HttpRequest = std.http.Server.Request;
const ServerRouter = @import("router.zig").Router;
const IpAddress = std.Io.net.IpAddress;
const ListenOptions = std.Io.net.IpAddress.ListenOptions;
const response = @import("response.zig");
const extract = @import("extract");
const utils = @import("utils.zig");

pub const Context = @import("context.zig").Context;
pub const Response = response.Response;

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
/// };
///
/// const MyServer = Server(MyState);
/// ```
pub fn Server(comptime State: type) type {
    return struct {
        const Self = @This();
        const Router = ServerRouter(State);
        const graceful_shutdown_timeout: std.Io.Clock.Duration = .{
            .raw = std.Io.Duration.fromSeconds(options.shutdown_timeout_seconds),
            .clock = .real,
        };

        const ShutdownWait = union(enum) {
            tasks_done: std.Io.Cancelable!void,
            timeout: std.Io.Cancelable!void,
        };

        /// The HTTP router that handles request routing and handler execution
        router: Router,
        /// I/O interface for network operations
        io: std.Io,
        /// Global allocator for server-wide allocations
        allocator: std.mem.Allocator,
        /// Application-specific shared state
        state: State,

        /// Initializes a new HTTP server instance.
        ///
        /// Parameters:
        /// - `allocator`: Global allocator for server operations
        /// - `io`: I/O interface for network operations
        /// - `state`: Initial application state
        ///
        /// Returns: A new Server instance ready to listen for connections
        pub fn init(allocator: std.mem.Allocator, io: std.Io, state: State) !Self {
            return .{
                .router = .init(allocator),
                .io = io,
                .allocator = allocator,
                .state = state,
            };
        }

        /// Cleans up server resources.
        ///
        /// This method should be called when the server is no longer needed
        /// to free any allocated resources, particularly the router.
        pub fn deinit(self: *Self) void {
            self.router.deinit();
        }

        /// Starts listening for HTTP connections on the specified address.
        ///
        /// This method runs an event loop that accepts incoming connections
        /// and processes them asynchronously. Each connection is handled in
        /// a separate async task.
        ///
        /// Parameters:
        /// - `address`: Network address to bind to (IP and port)
        /// - `options`: Listen options for the server socket
        ///
        /// The server will continue running until interrupted or an error occurs.
        pub fn listen(self: *Self, address: IpAddress, listen_options: ListenOptions) !void {
            var server = try IpAddress.listen(
                &address,
                self.io,
                listen_options,
            );
            defer server.deinit(self.io);

            var tasks: std.Io.Group = .init;
            errdefer tasks.cancel(self.io);

            var buffer: [32]u8 = undefined;
            var fixed_writer = std.Io.Writer.fixed(&buffer);
            try address.format(&fixed_writer);
            try fixed_writer.flush();

            std.log.info("Server is listening on http://{s}", .{buffer[0..fixed_writer.end]});
            try self.acceptConnections(&server, &tasks);
            self.gracefulShutdown(&tasks, graceful_shutdown_timeout);
        }

        fn acceptConnections(self: *Self, server: *std.Io.net.Server, tasks: *std.Io.Group) !void {
            while (true) {
                const conn = server.accept(self.io) catch |err| switch (err) {
                    error.Canceled => return,
                    else => return err,
                };
                tasks.async(self.io, handleConnection, .{ self, conn });
            }
        }

        fn awaitTasks(tasks: *std.Io.Group, io: std.Io) std.Io.Cancelable!void {
            try tasks.await(io);
        }

        fn sleepFor(duration: std.Io.Clock.Duration, io: std.Io) std.Io.Cancelable!void {
            try duration.sleep(io);
        }

        fn gracefulShutdown(self: *Self, tasks: *std.Io.Group, timeout: std.Io.Clock.Duration) void {
            var select_buffer: [2]ShutdownWait = undefined;
            var select = std.Io.Select(ShutdownWait).init(self.io, &select_buffer);
            defer select.cancelDiscard();

            select.async(.tasks_done, awaitTasks, .{ tasks, self.io });
            select.async(.timeout, sleepFor, .{ timeout, self.io });

            const result = select.await() catch |err| switch (err) {
                error.Canceled => {
                    tasks.cancel(self.io);
                    return;
                },
            };

            switch (result) {
                .tasks_done => |await_result| {
                    await_result catch {
                        tasks.cancel(self.io);
                    };
                },
                .timeout => |timeout_result| {
                    _ = timeout_result catch {};
                    std.log.warn(
                        "Graceful shutdown timeout reached after {}ms; canceling remaining connection tasks",
                        .{timeout.raw.toMilliseconds()},
                    );
                    tasks.cancel(self.io);
                },
            }
        }

        fn handleConnection(self: *Self, conn: std.Io.net.Stream) void {
            defer conn.close(self.io);

            var read_buffer: [4096]u8 = undefined;
            var stream_buf_reader = conn.reader(self.io, &read_buffer);

            var write_buffer: [4096]u8 = undefined;
            var stream_buf_writer = conn.writer(self.io, &write_buffer);

            var http_server = std.http.Server.init(&stream_buf_reader.interface, &stream_buf_writer.interface);
            while (true) {
                var req = receiveRequest(&http_server) orelse break;

                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();

                const req_allocator = arena.allocator();
                const ctx: Context = .{
                    .io = self.io,
                    .server_allocator = self.allocator,
                    .request_allocator = req_allocator,
                };

                handleRequest(&self.router, ctx, &self.state, &req) catch |err| {
                    if (err == error.ConnectionClose) break;
                    req.respond(@errorName(err), .{ .status = .internal_server_error }) catch continue;
                };
            }
        }

        fn receiveRequest(http_server: *std.http.Server) ?HttpRequest {
            return http_server.receiveHead() catch |err| {
                if (err != error.HttpConnectionClosing) {
                    std.log.err("Failed to receive head: {}", .{err});
                }
                return null;
            };
        }

        fn handleRequest(router: *const Router, ctx: Context, state: *State, req: *HttpRequest) !void {
            const target = normalizedTarget(req.head.target);
            const method = req.head.method;

            // Fast path: exact match via hash map.
            if (router.routes.get(target)) |route_entry| {
                if (route_entry.handlers.get(method)) |handler| {
                    const res = handler.execute(ctx, state, null, req) catch |err| {
                        if (utils.isMemberOfErrorSet(extract.WebSocketError, err)) return;
                        try req.respond(@errorName(err), .{ .status = .internal_server_error });
                        return;
                    };
                    try response.respond(req, res);
                } else {
                    return respondNotFound(req);
                }
                return;
            }

            // Slow path: linear scan over parametric routes.
            for (router.parametric_routes.items) |*route| {
                if (route.match(target)) {
                    if (route.entry.handlers.get(method)) |handler| {
                        const res = handler.execute(ctx, state, route.pattern, req) catch |err| {
                            if (utils.isMemberOfErrorSet(extract.WebSocketError, err)) return;
                            try req.respond(@errorName(err), .{ .status = .internal_server_error });
                            return;
                        };
                        try response.respond(req, res);
                    } else {
                        return respondNotFound(req);
                    }
                    return;
                }
            }

            return respondNotFound(req);
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
    };
}

test {
    _ = std.testing.refAllDecls(utils);
}

test "handleRequest returns 404 for unknown route" {
    const TestRouter = ServerRouter(void);
    const TestServer = Server(void);

    var router: TestRouter = .init(std.testing.allocator);
    defer router.deinit();

    const req_bytes = "GET /missing HTTP/1.1\r\n\r\n";
    var stream_buf_reader = std.Io.Reader.fixed(req_bytes);
    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = std.Io.Writer.fixed(&write_buffer);
    var http_server = std.http.Server.init(&stream_buf_reader, &stream_buf_writer);
    var req = try http_server.receiveHead();

    var state: void = {};
    const ctx: Context = .{
        .io = undefined,
        .server_allocator = std.testing.allocator,
        .request_allocator = std.testing.allocator,
    };

    try TestServer.handleRequest(&router, ctx, &state, &req);
    try stream_buf_writer.flush();

    const output = write_buffer[0..stream_buf_writer.end];
    try std.testing.expect(std.mem.indexOf(u8, output, "404") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Not Found") != null);
}

test "handleRequest returns 404 for method mismatch" {
    const TestRouter = ServerRouter(void);
    const TestServer = Server(void);

    var router: TestRouter = .init(std.testing.allocator);
    defer router.deinit();

    const handlers = struct {
        fn postOnly(ctx: Context, _: *void) !Response {
            return Response.text(ctx.request_allocator, .ok, "ok", null);
        }
    };

    try router.post("/users", &handlers.postOnly);

    const req_bytes = "GET /users HTTP/1.1\r\n\r\n";
    var stream_buf_reader = std.Io.Reader.fixed(req_bytes);
    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = std.Io.Writer.fixed(&write_buffer);
    var http_server = std.http.Server.init(&stream_buf_reader, &stream_buf_writer);
    var req = try http_server.receiveHead();

    var state: void = {};
    const ctx: Context = .{
        .io = undefined,
        .server_allocator = std.testing.allocator,
        .request_allocator = std.testing.allocator,
    };

    try TestServer.handleRequest(&router, ctx, &state, &req);
    try stream_buf_writer.flush();

    const output = write_buffer[0..stream_buf_writer.end];
    try std.testing.expect(std.mem.indexOf(u8, output, "404") != null);
}

test "handleRequest ignores websocket extractor errors" {
    const TestRouter = ServerRouter(void);
    const TestServer = Server(void);

    var router: TestRouter = .init(std.testing.allocator);
    defer router.deinit();

    const handlers = struct {
        fn noop(socket: *std.http.Server.WebSocket) !void {
            _ = socket;
        }

        fn websocketRoute(ctx: Context, _: *void, ws: extract.WebSocket) !Response {
            try ws.onConnected(noop, .{});
            return Response.ok(ctx.request_allocator, null, null);
        }
    };

    try router.get("/ws", &handlers.websocketRoute);

    const req_bytes = "GET /ws HTTP/1.1\r\n\r\n";
    var stream_buf_reader = std.Io.Reader.fixed(req_bytes);
    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = std.Io.Writer.fixed(&write_buffer);
    var http_server = std.http.Server.init(&stream_buf_reader, &stream_buf_writer);
    var req = try http_server.receiveHead();

    var state: void = {};
    const ctx: Context = .{
        .io = undefined,
        .server_allocator = std.testing.allocator,
        .request_allocator = std.testing.allocator,
    };

    try TestServer.handleRequest(&router, ctx, &state, &req);
    try stream_buf_writer.flush();
    try std.testing.expectEqual(@as(usize, 0), stream_buf_writer.end);
}
