const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Request = std.http.Server.Request;
const AllocatorError = std.mem.Allocator.Error;
const ReaderError = std.Io.Reader.Error;
const ParseError = std.json.ParseError(std.json.Scanner);

const Context = @import("../http/context.zig").Context;

const EXTRACTOR_ID: []const u8 = "VOLT_JSON_EXTRACTOR";

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

/// Creates a `Json` extractor type.
///
/// The resulting extractor struct contains:
/// - `result`: `JsonError!T`
///
/// `result` is successful when request validation and JSON parsing succeed.
/// Validation requires:
/// - a method that supports request bodies,
/// - `Content-Type: application/json`,
/// - a non-zero `Content-Length`,
/// - and a valid JSON body that matches `T`.
///
/// The extractor can be used either:
/// - as a router handler parameter (automatic injection), or
/// - manually inside a handler body with `Json(T).init(ctx)`.
///
/// ```zig
/// const Person = struct {
///     name: []const u8,
///     age: u7,
/// };
///
/// fn handleRequest(ctx: Context, person: Json(Person)) !Response {
///     const payload = person.result catch |e| {
///         _ = e;
///         // Handle JSON or validation error.
///         return Response.badRequest();
///     };
///
///     _ = ctx;
///     _ = payload;
///     return Response.ok();
/// }
/// ```
pub fn Json(comptime T: type) type {
    return struct {
        pub const ID: []const u8 = EXTRACTOR_ID;
        pub const PAYLOAD_TYPE: type = T;

        result: JsonError!T,

        pub fn init(ctx: Context) JsonError!T {
            return try extract(T, ctx.request_allocator, ctx.request);
        }
    };
}

pub const Resolver = struct {
    pub fn matches(comptime Extractor: type) bool {
        if (!@hasDecl(Extractor, "ID")) return false;
        return std.mem.eql(u8, @field(Extractor, "ID"), EXTRACTOR_ID);
    }

    pub fn resolve(comptime Extractor: type, arena: Allocator, req: *Request) Extractor {
        comptime assert(@hasDecl(Extractor, "PAYLOAD_TYPE"));
        const result = extract(@field(Extractor, "PAYLOAD_TYPE"), arena, req);
        return .{ .result = result };
    }
};

const Server = std.http.Server;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const testing = std.testing;

test "Json.init returns extractor error when content type header is missing" {
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
        .request_allocator = testing_arena,
        .request = &http_req,
    };

    try testing.expectError(RequestValidationError.ContentTypeMissing, Json(Person).init(test_ctx));
}

test "Json.init returns RequestBodyMissing for methods without a body (GET)" {
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
        .request_allocator = testing_arena,
        .request = &http_req,
    };

    try testing.expectError(RequestValidationError.RequestBodyMissing, Json(Person).init(test_ctx));
}

test "Json.init returns ContentLengthMissing when header is absent" {
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
        .request_allocator = testing_arena,
        .request = &http_req,
    };

    try testing.expectError(RequestValidationError.ContentLengthMissing, Json(Person).init(test_ctx));
}

test "Json.init returns EmptyRequestBody when content length is zero" {
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
        .request_allocator = testing_arena,
        .request = &http_req,
    };

    try testing.expectError(RequestValidationError.EmptyRequestBody, Json(Person).init(test_ctx));
}

test "Json.init returns InvalidContentType when content type header is incorrect" {
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
        .request_allocator = testing_arena,
        .request = &http_req,
    };

    try testing.expectError(RequestValidationError.InvalidContentType, Json(Person).init(test_ctx));
}

test "Json.init successfully parses valid JSON body" {
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
        .request_allocator = testing_arena,
        .request = &http_req,
    };

    const person = try Json(Person).init(test_ctx);
    try testing.expectEqualStrings("Bob", person.name);
    try testing.expectEqual(@as(u8, 30), person.age);
}

test "Json.init surfaces parse errors for invalid JSON" {
    const Person = struct {
        name: []const u8,
        age: u8,
    };

    // Malformed JSON: just an opening brace
    const body = "{";
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
        .request_allocator = testing_arena,
        .request = &http_req,
    };

    _ = Json(Person).init(test_ctx) catch |err| {
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

test "Json.Resolver.matches identifies Json extractor types" {
    const OtherExtractor = struct {
        pub const ID: []const u8 = "OTHER_EXTRACTOR";
        pub const PAYLOAD_TYPE: type = struct {};
    };

    try testing.expect(Resolver.matches(Json(struct { x: u8 })));
    try testing.expect(!Resolver.matches(OtherExtractor));
    try testing.expect(!Resolver.matches(struct {}));
}

test "Json.Resolver.resolve returns parsed payload in result" {
    const Person = struct {
        name: []const u8,
        age: u8,
    };

    const body = "{\"name\":\"Ana\",\"age\":28}";
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

    const resolved = Resolver.resolve(Json(Person), arena.allocator(), &http_req);
    const person = try resolved.result;
    try testing.expectEqualStrings("Ana", person.name);
    try testing.expectEqual(@as(u8, 28), person.age);
}
