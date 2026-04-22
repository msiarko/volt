const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Request = std.http.Server.Request;
const StructField = std.builtin.Type.StructField;
const AllocatorError = std.mem.Allocator.Error;

const Context = @import("../Context.zig");
const utils = @import("utils.zig");

const EXTRACTOR_ID: []const u8 = "VOLT_QUERY_EXTRACTOR";

fn extract(comptime name: []const u8, arena: Allocator, req: *Request) AllocatorError!?[]const u8 {
    var query_it = utils.queryIterator(req.head.target) orelse return null;
    while (query_it.next()) |entry| {
        const value = entry.value orelse continue;
        const key = try utils.decodeUrl(arena, entry.key);
        if (std.ascii.eqlIgnoreCase(key, name)) {
            const decoded_value = try utils.decodeUrl(arena, value);
            return decoded_value;
        }
    }

    return null;
}

pub fn Query(comptime name: []const u8) type {
    assert(name.len > 0);
    return struct {
        pub const ID: []const u8 = EXTRACTOR_ID;
        pub const PARAM_NAME: []const u8 = name;

        result: AllocatorError!?[]const u8,

        pub fn init(ctx: Context) AllocatorError!?[]const u8 {
            return try extract(name, ctx.req_arena, ctx.raw_req);
        }
    };
}

pub const Resolver = struct {
    pub const ID: []const u8 = EXTRACTOR_ID;

    pub fn resolve(comptime Extractor: type, ctx: Context) Extractor {
        comptime assert(@hasDecl(Extractor, "PARAM_NAME"));
        return .{ .result = extract(@field(Extractor, "PARAM_NAME"), ctx.req_arena, ctx.raw_req) };
    }
};

const testing = std.testing;
const Server = std.http.Server;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

test "init returns value when query param is present" {
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

    const res = try Query("name").init(test_ctx);
    try testing.expect(res != null);
    try testing.expectEqualStrings("zig", res.?);
}

test "init returns null when parameter is absent" {
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

    const res = try Query("name").init(test_ctx);
    try testing.expectEqual(null, res);
}

test "init returns null for empty parameter value" {
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

    const res = try Query("name").init(test_ctx);
    // Per extractor behavior an explicit empty value yields `null`
    try testing.expectEqual(null, res);
}

test "init returns the source value when percent decoding is not needed" {
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

    const result = try Query("name").init(test_ctx);
    try testing.expectEqualStrings("bad%2", result.?);
}

test "init returns null when request has no query string" {
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

    const res = try Query("name").init(test_ctx);
    try testing.expectEqual(null, res);
}

test "init matches decoded key name case-insensitively" {
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

    const res = try Query("FIRST NAME").init(test_ctx);
    try testing.expect(res != null);
    try testing.expectEqualStrings("Ana", res.?);
}

test "Resolver.resolve uses extractor PARAM_NAME" {
    const req_bytes = "GET /search?name=zig HTTP/1.1\r\n\r\n";
    var stream_buf_reader = Reader.fixed(req_bytes);

    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = Writer.fixed(&write_buffer);

    var http_server = Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const test_ctx: Context = .{
        .io = undefined,
        .req_arena = arena.allocator(),
        .raw_req = &http_req,
    };
    const resolved = Resolver.resolve(Query("name"), test_ctx);
    const value = try resolved.result;
    try testing.expectEqualStrings("zig", value.?);
}
