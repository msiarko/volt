const std = @import("std");
const HttpStatus = std.http.Status;
const Request = @import("request.zig").Request;
const Context = @import("context.zig").Context;
const Router = @import("router.zig").Router;

pub fn Server(comptime State: type) type {
    return struct {
        router: Router(State),
        ctx: Context(State),

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, io: std.Io, state: ?*State) !Self {
            return .{
                .router = .init(allocator),
                .ctx = .init(
                    allocator,
                    io,
                    state,
                ),
            };
        }

        pub fn deinit(self: *Self) void {
            self.router.deinit();
        }

        pub fn listen(self: *Self, port: u16) !void {
            const address = try std.Io.net.IpAddress.parse("0.0.0.0", port);
            var server = try std.Io.net.IpAddress.listen(
                &address,
                self.ctx.io,
                .{
                    .reuse_address = true,
                },
            );
            var tasks: std.ArrayList(std.Io.Future(void)) = .empty;
            defer {
                for (tasks.items) |*entry| {
                    entry.cancel(self.ctx.io);
                }

                tasks.deinit(self.ctx.allocator);
                server.deinit(self.ctx.io);
            }

            std.log.info("Server is listening on 0.0.0.0:{d} ...", .{port});

            while (true) {
                const conn = try server.accept(self.ctx.io);
                const task = self.ctx.io.async(handleConnection, .{
                    self,
                    conn,
                });

                try tasks.append(self.ctx.allocator, task);
            }
        }

        fn handleConnection(
            server: *Self,
            conn: std.Io.net.Stream,
        ) void {
            defer conn.close(server.ctx.io);

            var read_buffer: [4096]u8 = undefined;
            var stream_buf_reader = conn.reader(server.ctx.io, &read_buffer);

            var write_buffer: [4096]u8 = undefined;
            var stream_buf_writer = conn.writer(server.ctx.io, &write_buffer);

            var http_server = std.http.Server.init(&stream_buf_reader.interface, &stream_buf_writer.interface);

            while (true) {
                var req = http_server.receiveHead() catch |err| {
                    std.log.err("Failed to receive head: {}", .{err});
                    break;
                };

                var arena = std.heap.ArenaAllocator.init(server.ctx.allocator);
                defer arena.deinit();

                const req_allocator = arena.allocator();
                const request: Request = .{
                    .allocator = req_allocator,
                    .http_req = &req,
                };

                handleRequest(&server.router, server.ctx, request) catch |err| {
                    if (err == error.ConnectionClose) break;
                    std.log.err("Handler failed: {}", .{err});
                    request.http_req.respond("Internal Server Error", .{ .status = .internal_server_error }) catch {};
                };
            }
        }

        fn handleRequest(router: *const Router(State), ctx: Context(State), req: Request) !void {
            var target = req.getTarget();
            if (std.mem.indexOfScalar(u8, target, '?')) |idx| {
                target = target[0..idx];
            }

            const method = req.getMethod();

            if (router.routes.get(target)) |route_entry| {
                if (route_entry.handlers.get(method)) |handler| {
                    return try handler.execute(ctx, req);
                } else {
                    return req.http_req.respond("Method Not Allowed", .{ .status = .method_not_allowed });
                }
            } else {
                var buf: [1024]u8 = undefined;
                var len: usize = 0;

                const s = std.fmt.bufPrint(buf[len..], "Not Found target: '{s}'\nKnown routes:\n", .{target}) catch "";
                len += s.len;
                var it = router.routes.iterator();
                while (it.next()) |entry| {
                    const e = std.fmt.bufPrint(buf[len..], " - '{s}'\n", .{entry.key_ptr.*}) catch "";
                    len += e.len;
                }
                return req.http_req.respond(buf[0..len], .{ .status = .not_found });
            }
        }
    };
}
