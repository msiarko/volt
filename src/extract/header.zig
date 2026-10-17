const std = @import("std");
const Request = std.http.Server.Request;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Context = @import("../core/Context.zig");

const HeaderError = error{
    HeaderNotFound,
};

fn extract(comptime name: []const u8, req: *Request) ![]const u8 {
    var header_it = req.iterateHeaders();
    return while (header_it.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.name, name)) {
            break entry.value;
        }
    } else HeaderError.HeaderNotFound;
}

pub fn Header(comptime name: []const u8) type {
    comptime assert(name.len > 0);
    return struct {
        const Self = @This();

        name: []const u8 = name,
        value: []const u8,

        pub fn init(ctx: Context) !Self {
            return .{ .value = try extract(name, ctx.raw_req) };
        }

        pub fn errorMessage(err: HeaderError) []const u8 {
            return switch (err) {
                HeaderError.HeaderNotFound => std.fmt.comptimePrint("Header '{s}' not found", .{name}),
            };
        }
    };
}

test "init returns Header with value when header is present" {
    const Server = std.http.Server;
    const Reader = std.Io.Reader;
    const Writer = std.Io.Writer;
    const testing = std.testing;
    const testing_allocator = testing.allocator;

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

    const header = try Header("Authorization").init(test_ctx);
    try testing.expectEqualStrings("Bearer token123", header.value);
}

test "init returns Header with value when multiple headers are present" {
    const Server = std.http.Server;
    const Reader = std.Io.Reader;
    const Writer = std.Io.Writer;
    const testing = std.testing;
    const testing_allocator = testing.allocator;

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

    const header = try Header("X-Request-Id").init(test_ctx);
    try testing.expectEqualStrings("abc-123", header.value);
}

test "init returns error when header is not present" {
    const Server = std.http.Server;
    const Reader = std.Io.Reader;
    const Writer = std.Io.Writer;
    const testing = std.testing;
    const testing_allocator = testing.allocator;

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
    try testing.expectError(HeaderError.HeaderNotFound, header);
}

test "init returns error when no headers are present" {
    const Server = std.http.Server;
    const Reader = std.Io.Reader;
    const Writer = std.Io.Writer;
    const testing = std.testing;
    const testing_allocator = testing.allocator;

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
    try testing.expectError(HeaderError.HeaderNotFound, header);
}

test "init header name matching is case-insensitive" {
    const Server = std.http.Server;
    const Reader = std.Io.Reader;
    const Writer = std.Io.Writer;
    const testing = std.testing;
    const testing_allocator = testing.allocator;

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

    const header = try Header("authorization").init(test_ctx);
    try testing.expectEqualStrings("Bearer token123", header.value);
}

test "errorMessage returns correct message for HeaderNotFound" {
    const header_name = "Authorization";
    const err = HeaderError.HeaderNotFound;
    const msg = Header(header_name).errorMessage(err);
    try std.testing.expectEqualStrings("Header 'Authorization' not found", msg);
}
