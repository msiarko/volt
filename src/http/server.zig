const std = @import("std");
const HttpStatus = std.http.Status;
const HttpRequst = std.http.Server.Request;
const ServerRouter = @import("router.zig").Router;
const IpAddress = std.Io.net.IpAddress;
const ListenOptions = std.Io.net.IpAddress.ListenOptions;

pub const Context = @import("context.zig").Context;
const response = @import("response.zig");
pub const Response = response.Response;

pub fn Server(comptime State: type) type {
    return struct {
        const Self = @This();
        const Router = ServerRouter(State);

        router: Router,
        io: std.Io,
        allocator: std.mem.Allocator,
        state: State,

        pub fn init(allocator: std.mem.Allocator, io: std.Io, state: State) !Self {
            return .{
                .router = .init(allocator),
                .io = io,
                .allocator = allocator,
                .state = state,
            };
        }

        pub fn deinit(self: *Self) void {
            self.router.deinit();
        }

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
                    .gpa = server.allocator,
                    .arena = req_allocator,
                };

                handleRequest(&server.router, ctx, &server.state, &req) catch |err| {
                    if (err == error.ConnectionClose) break;
                    req.respond(@errorName(err), .{ .status = .internal_server_error }) catch continue;
                };
            }
        }

        fn handleRequest(router: *const Router, ctx: Context, state: *State, req: *HttpRequst) !void {
            var target = req.head.target;
            if (std.mem.indexOfScalar(u8, target, '?')) |idx| {
                target = target[0..idx];
            }

            const method = req.head.method;
            if (router.routes.get(target)) |route_entry| {
                if (route_entry.handlers.get(method)) |handler| {
                    const res = handler.execute(ctx, state, req) catch |err| {
                        if (err == error.WebSocketHandlerFailed) return;
                        if (err == error.NotWebSocketUpgrade) return;
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
