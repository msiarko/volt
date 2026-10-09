const std = @import("std");
const Router = @import("../router.zig").Router;
const Response = @import("../core/Response.zig");

pub fn Client(comptime Arg: type) type {
    const RouterType = comptime type_block: {
        if (@typeInfo(Arg) == .@"struct" and @hasDecl(Arg, "handle")) {
            break :type_block Arg;
        } else {
            break :type_block Router(Arg);
        }
    };

    return struct {
        const Self = @This();

        router: *RouterType,
        io: std.Io,
        arena: std.mem.Allocator,

        pub fn init(io: std.Io, arena: std.mem.Allocator, router: *RouterType) Self {
            return .{
                .router = router,
                .io = io,
                .arena = arena,
            };
        }

        pub fn request(
            self: *Self,
            method: std.http.Method,
            path: []const u8,
            body: ?[]const u8,
            headers: ?[]const std.http.Header,
        ) !Response {
            var headers_buf: [2048]u8 = undefined;
            var headers_writer = std.Io.Writer.fixed(&headers_buf);

            if (headers) |hdrs| {
                for (hdrs) |h| {
                    try headers_writer.print("{s}: {s}\r\n", .{ h.name, h.value });
                }
            }

            const formatted_headers = headers_buf[0..headers_writer.end];

            const req_str = if (body) |b|
                try self.arena.print(
                    "{s} {s} HTTP/1.1\r\nHost: localhost\r\n{s}Content-Length: {d}\r\n\r\n{s}",
                    .{ @tagName(method), path, formatted_headers, b.len, b },
                )
            else
                try self.arena.print(
                    "{s} {s} HTTP/1.1\r\nHost: localhost\r\n{s}\r\n",
                    .{ @tagName(method), path, formatted_headers },
                );
            defer self.arena.free(req_str);

            var stream_buf_reader = std.Io.Reader.fixed(req_str);
            var write_buffer: [4096]u8 = undefined;
            var stream_buf_writer = std.Io.Writer.fixed(&write_buffer);

            var http_server = std.http.Server.init(&stream_buf_reader, &stream_buf_writer);
            var http_req = try http_server.receiveHead();

            return self.router.dispatch(self.io, self.arena, &http_req);
        }

        pub fn get(
            self: *Self,
            path: []const u8,
            headers: ?[]const std.http.Header,
        ) !Response {
            return self.request(.GET, path, null, headers);
        }

        pub fn head(
            self: *Self,
            path: []const u8,
            headers: ?[]const std.http.Header,
        ) !Response {
            return self.request(.HEAD, path, null, headers);
        }

        pub fn post(
            self: *Self,
            path: []const u8,
            body: ?[]const u8,
            headers: ?[]const std.http.Header,
        ) !Response {
            return self.request(.POST, path, body, headers);
        }

        pub fn put(
            self: *Self,
            path: []const u8,
            body: ?[]const u8,
            headers: ?[]const std.http.Header,
        ) !Response {
            return self.request(.PUT, path, body, headers);
        }

        pub fn patch(
            self: *Self,
            path: []const u8,
            body: ?[]const u8,
            headers: ?[]const std.http.Header,
        ) !Response {
            return self.request(.PATCH, path, body, headers);
        }

        pub fn delete(
            self: *Self,
            path: []const u8,
            headers: ?[]const std.http.Header,
        ) !Response {
            return self.request(.DELETE, path, null, headers);
        }

        pub fn connect(
            self: *Self,
            path: []const u8,
            headers: ?[]const std.http.Header,
        ) !Response {
            return self.request(.CONNECT, path, null, headers);
        }

        pub fn options(
            self: *Self,
            path: []const u8,
            headers: ?[]const std.http.Header,
        ) !Response {
            return self.request(.OPTIONS, path, null, headers);
        }

        pub fn trace(
            self: *Self,
            path: []const u8,
            headers: ?[]const std.http.Header,
        ) !Response {
            return self.request(.TRACE, path, null, headers);
        }
    };
}

test "Client dispatches GET requests" {
    const testing = std.testing;
    const Context = @import("../core/Context.zig");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var router = Router(void).init(alloc, {});
    defer router.deinit(alloc);

    const getHello = struct {
        fn handle(ctx: Context) !Response {
            return Response.ok(ctx.req_arena, "Hello World", null);
        }
    }.handle;

    try router.get(alloc, "/hello", getHello);

    var client = Client(void).init(testing.io, alloc, &router);

    const res = try client.get("/hello", null);
    try testing.expect(res.attributes != null);
    try testing.expectEqual(std.http.Status.ok, res.attributes.?.status);
    try testing.expectEqualStrings("Hello World", res.attributes.?.content);
}

test "Client dispatches POST requests" {
    const testing = std.testing;
    const Context = @import("../core/Context.zig");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var router = Router(void).init(alloc, {});
    defer router.deinit(alloc);

    const postEcho = struct {
        fn handle(ctx: Context) !Response {
            return Response.json(ctx.req_arena, .created, "{\"status\":\"created\"}", null);
        }
    }.handle;

    try router.post(alloc, "/items", postEcho);

    var client = Client(void).init(testing.io, alloc, &router);

    const res = try client.post("/items", "{\"name\":\"item1\"}", null);
    try testing.expect(res.attributes != null);
    try testing.expectEqual(std.http.Status.created, res.attributes.?.status);
    try testing.expectEqualStrings("{\"status\":\"created\"}", res.attributes.?.content);
}

test "Client dispatches PUT requests" {
    const testing = std.testing;
    const Context = @import("../core/Context.zig");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var router = Router(void).init(alloc, {});
    defer router.deinit(alloc);

    const putItem = struct {
        fn handle(ctx: Context) !Response {
            return Response.ok(ctx.req_arena, "Updated", null);
        }
    }.handle;

    try router.put(alloc, "/items/1", putItem);

    var client = Client(void).init(testing.io, alloc, &router);

    const res = try client.put("/items/1", "update", null);
    try testing.expect(res.attributes != null);
    try testing.expectEqual(std.http.Status.ok, res.attributes.?.status);
    try testing.expectEqualStrings("Updated", res.attributes.?.content);
}

test "Client dispatches PATCH requests" {
    const testing = std.testing;
    const Context = @import("../core/Context.zig");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var router = Router(void).init(alloc, {});
    defer router.deinit(alloc);

    const patchItem = struct {
        fn handle(ctx: Context) !Response {
            return Response.ok(ctx.req_arena, "Patched", null);
        }
    }.handle;

    try router.patch(alloc, "/items/1", patchItem);

    var client = Client(void).init(testing.io, alloc, &router);

    const res = try client.patch("/items/1", "patch", null);
    try testing.expect(res.attributes != null);
    try testing.expectEqual(std.http.Status.ok, res.attributes.?.status);
    try testing.expectEqualStrings("Patched", res.attributes.?.content);
}

test "Client dispatches DELETE requests" {
    const testing = std.testing;
    const Context = @import("../core/Context.zig");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var router = Router(void).init(alloc, {});
    defer router.deinit(alloc);

    const deleteItem = struct {
        fn handle(ctx: Context) !Response {
            return Response.ok(ctx.req_arena, "Deleted", null);
        }
    }.handle;

    try router.delete(alloc, "/items/1", deleteItem);

    var client = Client(void).init(testing.io, alloc, &router);

    const res = try client.delete("/items/1", null);
    try testing.expect(res.attributes != null);
    try testing.expectEqual(std.http.Status.ok, res.attributes.?.status);
    try testing.expectEqualStrings("Deleted", res.attributes.?.content);
}

test "Client returns 404 for nonexistent routes" {
    const testing = std.testing;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var router = Router(void).init(alloc, {});
    defer router.deinit(alloc);

    var client = Client(void).init(testing.io, alloc, &router);

    const res = try client.get("/nonexistent", null);
    try testing.expect(res.attributes != null);
    try testing.expectEqual(std.http.Status.not_found, res.attributes.?.status);
}

test "Client returns 405 for disallowed methods" {
    const testing = std.testing;
    const Context = @import("../core/Context.zig");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var router = Router(void).init(alloc, {});
    defer router.deinit(alloc);

    const getHello = struct {
        fn handle(ctx: Context) !Response {
            return Response.ok(ctx.req_arena, "Hello World", null);
        }
    }.handle;

    try router.get(alloc, "/hello", getHello);

    var client = Client(void).init(testing.io, alloc, &router);

    const res = try client.post("/hello", null, null);
    try testing.expect(res.attributes != null);
    try testing.expectEqual(std.http.Status.method_not_allowed, res.attributes.?.status);
}

test "Client dispatches large request payload" {
    const testing = std.testing;
    const Context = @import("../core/Context.zig");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var router = Router(void).init(alloc, {});
    defer router.deinit(alloc);

    const postLarge = struct {
        fn handle(ctx: Context) !Response {
            return Response.ok(ctx.req_arena, "Large Received", null);
        }
    }.handle;

    try router.post(alloc, "/large", postLarge);

    var client = Client(void).init(testing.io, alloc, &router);

    // Create a 16 KB body payload larger than a fixed 4KB buffer
    const large_body = try alloc.alloc(u8, 16384);
    @memset(large_body, 'A');

    const res = try client.post("/large", large_body, null);
    try testing.expect(res.attributes != null);
    try testing.expectEqual(std.http.Status.ok, res.attributes.?.status);
    try testing.expectEqualStrings("Large Received", res.attributes.?.content);
}
