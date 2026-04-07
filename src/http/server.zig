//! HTTP Server implementation for the Volt web library.
//!
//! This module provides a generic HTTP server that can handle requests asynchronously
//! and route them through a configured router. The server supports WebSocket upgrades
//! and provides a context for request handling.

const std = @import("std");
const HttpStatus = std.http.Status;
const HttpRequest = std.http.Server.Request;
const ServerRouter = @import("router.zig").Router;
const IpAddress = std.Io.net.IpAddress;
const ListenOptions = std.Io.net.IpAddress.ListenOptions;
const response = @import("response.zig");
const extractors = @import("extractors");
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
        pub fn listen(self: *Self, address: IpAddress, options: ListenOptions) !void {
            var server = try IpAddress.listen(
                &address,
                self.io,
                options,
            );

            var tasks: std.ArrayList(std.Io.Future(void)) = .empty;
            defer {
                for (tasks.items) |*entry| {
                    entry.cancel(self.io);
                }

                tasks.deinit(self.allocator);
                server.deinit(self.io);
            }

            var buffer: [32]u8 = undefined;
            var fixed_writer = std.Io.Writer.fixed(&buffer);
            try address.format(&fixed_writer);
            try fixed_writer.flush();

            std.log.info("Server is listening on http://{s}", .{buffer[0..fixed_writer.end]});
            while (true) {
                const conn = try server.accept(self.io);
                const task = self.io.async(handleConnection, .{ self, conn });
                try tasks.append(self.allocator, task);
            }
        }

        fn handleConnection(server: *Self, conn: std.Io.net.Stream) void {
            defer conn.close(server.io);

            var read_buffer: [4096]u8 = undefined;
            var stream_buf_reader = conn.reader(server.io, &read_buffer);

            var write_buffer: [4096]u8 = undefined;
            var stream_buf_writer = conn.writer(server.io, &write_buffer);

            var http_server = std.http.Server.init(&stream_buf_reader.interface, &stream_buf_writer.interface);
            while (true) {
                var req = http_server.receiveHead() catch |err| {
                    if (err == error.HttpConnectionClosing) break;
                    std.log.err("Failed to receive head: {}", .{err});
                    break;
                };

                var arena = std.heap.ArenaAllocator.init(server.allocator);
                defer arena.deinit();

                const req_allocator = arena.allocator();
                const ctx: Context = .{
                    .io = server.io,
                    .server_allocator = server.allocator,
                    .request_allocator = req_allocator,
                };

                handleRequest(&server.router, ctx, &server.state, &req) catch |err| {
                    if (err == error.ConnectionClose) break;
                    req.respond(@errorName(err), .{ .status = .internal_server_error }) catch continue;
                };
            }
        }

        fn handleRequest(router: *const Router, ctx: Context, state: *State, req: *HttpRequest) !void {
            var target = req.head.target;
            if (std.mem.indexOfScalar(u8, target, '?')) |idx| {
                target = target[0..idx];
            }

            const method = req.head.method;
            if (router.routes.get(target)) |route_entry| {
                if (route_entry.handlers.get(method)) |handler| {
                    const res = handler.execute(ctx, state, req) catch |err| {
                        if (utils.isMemberOfErrorSet(extractors.WebSocketError, err)) return;
                        try req.respond(@errorName(err), .{ .status = .internal_server_error });
                        return;
                    };
                    try response.respond(req, res);
                } else {
                    return req.respond("Not Found", .{ .status = .not_found });
                }
            } else {
                return req.respond("Not Found", .{ .status = .not_found });
            }
        }
    };
}

test {
    _ = std.testing.refAllDecls(utils);
}
