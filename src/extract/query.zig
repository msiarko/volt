const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Request = std.http.Server.Request;
const AllocatorError = std.mem.Allocator.Error;

const Context = @import("../core/Context.zig");
const QueryIterator = @import("QueryIterator.zig");
const url = @import("url.zig");

fn extract(comptime name: []const u8, arena: Allocator, req: *Request) AllocatorError!?[]const u8 {
    var query_it = QueryIterator.init(req.head.target) orelse return null;
    return while (query_it.next()) |entry| {
        const value = entry.value orelse continue;
        const key = if (std.ascii.eqlIgnoreCase(entry.key, name))
            entry.key
        else
            try url.decode(arena, entry.key);

        if (std.ascii.eqlIgnoreCase(key, name)) {
            const decoded_value = try url.decode(arena, value);
            break decoded_value;
        }
    } else null;
}

pub fn Query(comptime name: []const u8) type {
    comptime assert(name.len > 0);
    return struct {
        const Self = @This();

        name: []const u8 = name,
        value: ?[]const u8,

        pub fn init(ctx: Context) AllocatorError!Self {
            return .{ .value = try extract(name, ctx.req_arena, ctx.raw_req) };
        }
    };
}

test "init returns value when query param is present" {
    const testing = std.testing;
    const Server = std.http.Server;
    const Reader = std.Io.Reader;
    const Writer = std.Io.Writer;

    const req_bytes = "GET /search?name=zig&role=admin HTTP/1.1\r\n\r\n";
    var stream_buf_reader = Reader.fixed(req_bytes);

    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = Writer.fixed(&write_buffer);

    var http_server = Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const testing_arena = arena.allocator();
    const test_ctx: Context = .{
        .io = undefined,
        .req_arena = testing_arena,
        .raw_req = &http_req,
    };

    const result = Query("name").init(test_ctx);
    const query = result catch {
        try testing.expect(false);
        return;
    };

    try testing.expectEqualStrings("name", query.name);
    try testing.expect(query.value != null);
    try testing.expectEqualStrings("zig", query.value.?);
}

test "init returns null when parameter is absent" {
    const testing = std.testing;
    const Server = std.http.Server;
    const Reader = std.Io.Reader;
    const Writer = std.Io.Writer;

    const req_bytes = "GET /search?role=admin HTTP/1.1\r\n\r\n";
    var stream_buf_reader = Reader.fixed(req_bytes);

    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = Writer.fixed(&write_buffer);

    var http_server = Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const testing_arena = arena.allocator();
    const test_ctx: Context = .{
        .io = undefined,
        .req_arena = testing_arena,
        .raw_req = &http_req,
    };

    const result = Query("name").init(test_ctx);
    const query = result catch {
        try testing.expect(false);
        return;
    };

    try testing.expectEqual(null, query.value);
}

test "init returns null for empty parameter value" {
    const testing = std.testing;
    const Server = std.http.Server;
    const Reader = std.Io.Reader;
    const Writer = std.Io.Writer;

    const req_bytes = "GET /search?name=&role=admin HTTP/1.1\r\n\r\n";
    var stream_buf_reader = Reader.fixed(req_bytes);

    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = Writer.fixed(&write_buffer);

    var http_server = Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const testing_arena = arena.allocator();
    const test_ctx: Context = .{
        .io = undefined,
        .req_arena = testing_arena,
        .raw_req = &http_req,
    };

    const result = Query("name").init(test_ctx);
    const query = result catch {
        try testing.expect(false);
        return;
    };
    // Per extractor behavior an explicit empty value yields `null`
    try testing.expectEqual(null, query.value);
}

test "init returns the source value when percent decoding is not needed" {
    const testing = std.testing;
    const Server = std.http.Server;
    const Reader = std.Io.Reader;
    const Writer = std.Io.Writer;

    const req_bytes = "GET /search?name=bad%2 HTTP/1.1\r\n\r\n";
    var stream_buf_reader = Reader.fixed(req_bytes);

    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = Writer.fixed(&write_buffer);

    var http_server = Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const testing_arena = arena.allocator();
    const test_ctx: Context = .{
        .io = undefined,
        .req_arena = testing_arena,
        .raw_req = &http_req,
    };

    const result = Query("name").init(test_ctx);
    const query = result catch {
        try testing.expect(false);
        return;
    };
    try testing.expectEqualStrings("bad%2", query.value.?);
}

test "init returns null when request has no query string" {
    const testing = std.testing;
    const Server = std.http.Server;
    const Reader = std.Io.Reader;
    const Writer = std.Io.Writer;

    const req_bytes = "GET /search HTTP/1.1\r\n\r\n";
    var stream_buf_reader = Reader.fixed(req_bytes);

    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = Writer.fixed(&write_buffer);

    var http_server = Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const testing_arena = arena.allocator();
    const test_ctx: Context = .{
        .io = undefined,
        .req_arena = testing_arena,
        .raw_req = &http_req,
    };

    const result = Query("name").init(test_ctx);
    const query = result catch {
        try testing.expect(false);
        return;
    };
    try testing.expectEqual(null, query.value);
}

test "init matches decoded key name case-insensitively" {
    const testing = std.testing;
    const Server = std.http.Server;
    const Reader = std.Io.Reader;
    const Writer = std.Io.Writer;

    const req_bytes = "GET /search?first%20name=Ana HTTP/1.1\r\n\r\n";
    var stream_buf_reader = Reader.fixed(req_bytes);

    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = Writer.fixed(&write_buffer);

    var http_server = Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const testing_arena = arena.allocator();
    const test_ctx: Context = .{
        .io = undefined,
        .req_arena = testing_arena,
        .raw_req = &http_req,
    };

    const result = Query("FIRST NAME").init(test_ctx);
    const query = result catch {
        try testing.expect(false);
        return;
    };
    try testing.expect(query.value != null);
    try testing.expectEqualStrings("Ana", query.value.?);
}
