const std = @import("std");
const Request = std.http.Server.Request;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Context = @import("../Context.zig");

const EXTRACTOR_ID: []const u8 = "VOLT_HEADER_EXTRACTOR";

fn extract(comptime name: []const u8, req: *Request) Header(name) {
    var header_it = req.iterateHeaders();
    return while (header_it.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.name, name)) {
            break .{ .value = entry.value };
        }
    } else .{ .value = null };
}

pub fn Header(comptime name: []const u8) type {
    assert(name.len > 0);
    return struct {
        const Self = @This();

        pub const ID: []const u8 = EXTRACTOR_ID;
        pub const HEADER_NAME: []const u8 = name;

        value: ?[]const u8,

        pub fn init(ctx: Context) Self {
            return extract(name, ctx.raw_req);
        }
    };
}

pub const Resolver = struct {
    pub const ID: []const u8 = EXTRACTOR_ID;

    pub fn resolve(comptime Extractor: type, ctx: Context) Extractor {
        comptime assert(@hasDecl(Extractor, "HEADER_NAME"));
        return extract(@field(Extractor, "HEADER_NAME"), ctx.raw_req);
    }
};

const Server = std.http.Server;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const testing = std.testing;
const testing_allocator = testing.allocator;
const utils = @import("utils.zig");

test "init returns Header with value when header is present" {
    const req_bytes = "GET / HTTP/1.1\r\nAuthorization: Bearer token123\r\n\r\n";
    var stream_buf_reader = Reader.fixed(req_bytes);

    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = Writer.fixed(&write_buffer);

    var http_server = Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    const test_ctx: Context = .{
        .io = undefined,
        .req_arena = testing_allocator,
        .raw_req = &http_req,
    };
    const header = Header("Authorization").init(test_ctx);

    try testing.expect(header.value != null);
    try testing.expectEqualStrings("Bearer token123", header.value.?);
}

test "init returns Header with value when multiple headers are present" {
    const req_bytes = "GET / HTTP/1.1\r\nContent-Type: application/json\r\nX-Request-Id: abc-123\r\n\r\n";
    var stream_buf_reader = Reader.fixed(req_bytes);

    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = Writer.fixed(&write_buffer);

    var http_server = Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    const test_ctx: Context = .{
        .io = undefined,
        .req_arena = testing_allocator,
        .raw_req = &http_req,
    };
    const header = Header("X-Request-Id").init(test_ctx);

    try testing.expect(header.value != null);
    try testing.expectEqualStrings("abc-123", header.value.?);
}

test "init returns null when header is not present" {
    const req_bytes = "GET / HTTP/1.1\r\nContent-Type: application/json\r\n\r\n";
    var stream_buf_reader = Reader.fixed(req_bytes);

    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = Writer.fixed(&write_buffer);

    var http_server = Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    const test_ctx: Context = .{
        .io = undefined,
        .req_arena = testing_allocator,
        .raw_req = &http_req,
    };
    const header = Header("Authorization").init(test_ctx);

    try testing.expectEqual(null, header.value);
}

test "init returns null when no headers are present" {
    const req_bytes = "GET / HTTP/1.1\r\n\r\n";
    var stream_buf_reader = Reader.fixed(req_bytes);

    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = Writer.fixed(&write_buffer);

    var http_server = Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    const test_ctx: Context = .{
        .io = undefined,
        .req_arena = testing_allocator,
        .raw_req = &http_req,
    };
    const header = Header("Authorization").init(test_ctx);
    try testing.expectEqual(null, header.value);
}

test "init table-driven header extraction" {
    const cases = [_]struct {
        headers: []const u8,
        expected: ?[]const u8,
    }{
        .{ .headers = "Authorization: Bearer tok\r\n", .expected = "Bearer tok" },
        .{ .headers = "Content-Type: text/plain\r\n", .expected = null },
        .{ .headers = "", .expected = null },
    };

    inline for (cases) |case| {
        const req_bytes = std.fmt.comptimePrint("GET / HTTP/1.1\r\n{s}\r\n", .{case.headers});
        var stream_buf_reader = Reader.fixed(req_bytes);

        var write_buffer: [4096]u8 = undefined;
        var stream_buf_writer = Writer.fixed(&write_buffer);

        var http_server = Server.init(&stream_buf_reader, &stream_buf_writer);
        var http_req = try http_server.receiveHead();

        const test_ctx: Context = .{
            .io = undefined,
            .req_arena = testing_allocator,
            .raw_req = &http_req,
        };
        const header = Header("Authorization").init(test_ctx);

        if (case.expected) |expected| {
            try testing.expectEqualStrings(expected, header.value.?);
        } else {
            try testing.expectEqual(null, header.value);
        }
    }
}

test "init header name matching is case-insensitive" {
    const req_bytes = "GET / HTTP/1.1\r\nAuthorization: Bearer token123\r\n\r\n";
    var stream_buf_reader = Reader.fixed(req_bytes);

    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = Writer.fixed(&write_buffer);

    var http_server = Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    const test_ctx: Context = .{
        .io = undefined,
        .req_arena = testing_allocator,
        .raw_req = &http_req,
    };

    const header = Header("authorization").init(test_ctx);
    try testing.expectEqualStrings("Bearer token123", header.value.?);
}

test "Resolver.resolve extracts using extractor HEADER_NAME" {
    const req_bytes = "GET / HTTP/1.1\r\nX-Request-Id: abc-123\r\n\r\n";
    var stream_buf_reader = Reader.fixed(req_bytes);

    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = Writer.fixed(&write_buffer);

    var http_server = Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    const test_ctx: Context = .{
        .io = undefined,
        .req_arena = testing_allocator,
        .raw_req = &http_req,
    };
    const resolved = Resolver.resolve(Header("X-Request-Id"), test_ctx);
    try testing.expectEqualStrings("abc-123", resolved.value.?);
}
