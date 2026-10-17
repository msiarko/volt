const std = @import("std");
const Allocator = std.mem.Allocator;
const Request = std.http.Server.Request;
const AllocatorError = std.mem.Allocator.Error;
const ReaderError = std.Io.Reader.Error;
const ParseError = std.json.ParseError(std.json.Scanner);

const Context = @import("../core/Context.zig");

fn extract(comptime T: type, arena: Allocator, req: *Request) JsonError!T {
    if (!req.head.method.requestHasBody()) {
        return error.RequestBodyMissing;
    }

    if (req.head.content_type) |content_type| {
        if (!std.mem.eql(u8, content_type, "application/json")) {
            return error.InvalidContentType;
        }
    } else return error.ContentTypeMissing;

    if (req.head.content_length) |content_length| {
        if (content_length == 0) {
            return error.EmptyRequestBody;
        }
    } else return error.ContentLengthMissing;

    const data = try arena.alloc(u8, req.head.content_length.?);
    defer arena.free(data);

    const reader = req.server.reader.bodyReader(
        data,
        req.head.transfer_encoding,
        req.head.content_length,
    );

    try reader.readSliceAll(data);
    return try std.json.parseFromSliceLeaky(T, arena, data, .{ .allocate = .alloc_always });
}

pub const RequestValidationError = error{
    RequestBodyMissing,
    ContentTypeMissing,
    InvalidContentType,
    ContentLengthMissing,
    EmptyRequestBody,
};

pub const JsonError = RequestValidationError || AllocatorError || ReaderError || ParseError;

pub fn Json(comptime T: type) type {
    return struct {
        const Self = @This();

        value: T,

        pub fn init(ctx: Context) JsonError!Self {
            return .{ .value = try extract(T, ctx.req_arena, ctx.raw_req) };
        }

        pub fn errorMessage(err: JsonError) []const u8 {
            return switch (err) {
                RequestValidationError.RequestBodyMissing => "Request body is missing",
                RequestValidationError.ContentTypeMissing => "Missing Content-Type header",
                RequestValidationError.InvalidContentType => "Invalid Content-Type header, expected 'application/json'",
                RequestValidationError.ContentLengthMissing => "Missing Content-Length header",
                RequestValidationError.EmptyRequestBody => "Request body is empty",
                ReaderError.EndOfStream => "Unexpected end of input while reading request body",
                else => |e| @errorName(e),
            };
        }
    };
}

test "init returns extractor error when content type header is missing" {
    const Server = std.http.Server;
    const Reader = std.Io.Reader;
    const Writer = std.Io.Writer;
    const testing = std.testing;

    const Person = struct {
        name: []const u8,
        age: u7,
    };

    const req_bytes = "POST /person HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}";
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

    const result = Json(Person).init(test_ctx);
    try testing.expectError(RequestValidationError.ContentTypeMissing, result);
}

test "init returns RequestBodyMissing for methods without a body (GET)" {
    const Server = std.http.Server;
    const Reader = std.Io.Reader;
    const Writer = std.Io.Writer;
    const testing = std.testing;

    const Person = struct {
        name: []const u8,
        age: u8,
    };

    const req_bytes = "GET /person HTTP/1.1\r\n\r\n";
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

    const result = Json(Person).init(test_ctx);
    try testing.expectError(RequestValidationError.RequestBodyMissing, result);
}

test "init returns ContentLengthMissing when header is absent" {
    const Server = std.http.Server;
    const Reader = std.Io.Reader;
    const Writer = std.Io.Writer;
    const testing = std.testing;

    const Person = struct {
        name: []const u8,
        age: u8,
    };

    const req_bytes = "POST /person HTTP/1.1\r\nContent-Type: application/json\r\n\r\n{}";
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

    const result = Json(Person).init(test_ctx);
    try testing.expectError(RequestValidationError.ContentLengthMissing, result);
}

test "init returns EmptyRequestBody when content length is zero" {
    const Server = std.http.Server;
    const Reader = std.Io.Reader;
    const Writer = std.Io.Writer;
    const testing = std.testing;

    const Person = struct {
        name: []const u8,
        age: u8,
    };

    const req_bytes = "POST /person HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 0\r\n\r\n";
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

    const result = Json(Person).init(test_ctx);
    try testing.expectError(RequestValidationError.EmptyRequestBody, result);
}

test "init returns InvalidContentType when content type header is incorrect" {
    const Server = std.http.Server;
    const Reader = std.Io.Reader;
    const Writer = std.Io.Writer;
    const testing = std.testing;

    const Person = struct {
        name: []const u8,
        age: u8,
    };

    const req_bytes = "POST /person HTTP/1.1\r\nContent-Type: text/plain\r\nContent-Length: 2\r\n\r\n{}";
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

    const result = Json(Person).init(test_ctx);
    try testing.expectError(RequestValidationError.InvalidContentType, result);
}

test "init successfully parses valid JSON body" {
    const Server = std.http.Server;
    const Reader = std.Io.Reader;
    const Writer = std.Io.Writer;
    const testing = std.testing;

    const Person = struct {
        name: []const u8,
        age: u8,
    };

    const body = "{\"name\":\"Bob\",\"age\":30}";
    const req_bytes = std.fmt.comptimePrint("POST /person HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}", .{ body.len, body });

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

    const person = try Json(Person).init(test_ctx);
    try testing.expectEqualStrings("Bob", person.value.name);
    try testing.expectEqual(@as(u8, 30), person.value.age);
}

test "init surfaces parse errors for invalid JSON" {
    const Server = std.http.Server;
    const Reader = std.Io.Reader;
    const Writer = std.Io.Writer;
    const testing = std.testing;

    const Person = struct {
        name: []const u8,
        age: u8,
    };

    // Malformed JSON: just an opening brace
    const body = "{";
    const req_bytes = std.fmt.comptimePrint(
        "POST /person HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ body.len, body },
    );

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

    const result = Json(Person).init(test_ctx);
    _ = result catch |err| {
        // Ensure it's not one of the simple request validation errors
        try testing.expect(err != RequestValidationError.RequestBodyMissing);
        try testing.expect(err != RequestValidationError.ContentTypeMissing);
        try testing.expect(err != RequestValidationError.InvalidContentType);
        try testing.expect(err != RequestValidationError.ContentLengthMissing);
        try testing.expect(err != RequestValidationError.EmptyRequestBody);
        return;
    };

    // If init unexpectedly succeeded, fail the test
    try testing.expect(false);
}

test "errorMessage returns correct message for RequestValidationError" {
    const err = RequestValidationError.ContentTypeMissing;
    const msg = Json(@This()).errorMessage(err);
    try std.testing.expectEqualStrings("Missing Content-Type header", msg);
}

test "errorMessage returns correct message for ReaderError" {
    const err = ReaderError.EndOfStream;
    const msg = Json(@This()).errorMessage(err);
    try std.testing.expectEqualStrings("Unexpected end of input while reading request body", msg);
}
