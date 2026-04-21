const std = @import("std");
const Request = std.http.Server.Request;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Context = @import("../Context.zig");

const EXTRACTOR_ID: []const u8 = "VOLT_HEADER_EXTRACTOR";

fn extract(comptime name: []const u8, req: *Request) Header(name) {
    var header_it = req.iterateHeaders();
    while (header_it.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.name, name)) {
            return .{ .value = entry.value };
        }
    }

    return .{ .value = null };
}

/// Creates a Header extractor type for a specific HTTP header name.
///
/// Fields:
/// - `value` An optional slice of bytes that contains the value of the header if it is present in the request, or `null` if the header is absent
///
/// Header name comparison is case-insensitive.
///
/// Example usage in a router handler:
/// ```zig
/// fn handleRequest(ctx: Context, auth: Header("Authorization")) !Response {
///     const token = auth.value orelse return Response.unauthorized();
///     // Use token...
/// }
///
/// fn handleRequest(ctx: Context) !Response {
///     const auth = try Header("Authorization").init(ctx);
///     const token = auth.value orelse return Response.unauthorized();
///     // Use token...
/// }
/// ```
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
    pub fn matches(comptime Extractor: type) bool {
        if (!@hasDecl(Extractor, "ID")) return false;
        return std.mem.eql(u8, @field(Extractor, "ID"), EXTRACTOR_ID);
    }

    pub fn resolve(comptime Extractor: type, allocator: Allocator, req: *Request) Extractor {
        _ = allocator;
        comptime assert(@hasDecl(Extractor, "HEADER_NAME"));
        return extract(@field(Extractor, "HEADER_NAME"), req);
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

test "Resolver.matches identifies header extractor types" {
    const OtherExtractor = struct {
        pub const ID: []const u8 = "OTHER_EXTRACTOR";
    };

    try testing.expect(Resolver.matches(Header("x-id")));
    try testing.expect(!Resolver.matches(utils.TestExtractor));
    try testing.expect(!Resolver.matches(OtherExtractor));
}

test "Resolver.resolve extracts using extractor HEADER_NAME" {
    const req_bytes = "GET / HTTP/1.1\r\nX-Request-Id: abc-123\r\n\r\n";
    var stream_buf_reader = Reader.fixed(req_bytes);

    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = Writer.fixed(&write_buffer);

    var http_server = Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    const resolved = Resolver.resolve(Header("X-Request-Id"), testing_allocator, &http_req);
    try testing.expectEqualStrings("abc-123", resolved.value.?);
}
