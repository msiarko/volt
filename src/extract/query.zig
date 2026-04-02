const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Request = std.http.Server.Request;
const StructField = std.builtin.Type.StructField;
const AllocatorError = std.mem.Allocator.Error;

const Context = @import("../http/context.zig").Context;
const utils = @import("utils.zig");

const EXTRACTOR_ID: []const u8 = "VOLT_QUERY_EXTRACTOR";

fn extract(comptime name: []const u8, arena: Allocator, req: *Request) QueryError!?[]const u8 {
    var query_it = utils.queryIterator(req.head.target) orelse return null;
    while (query_it.next()) |entry| {
        if (utils.queryComponentEqualsAsciiIgnoreCaseDecoded(entry.key, name)) {
            const raw = entry.value orelse return null;
            const decoded = try utils.decodeQueryComponent(arena, raw);
            return decoded;
        }
    }

    return null;
}

pub const QueryError = utils.DecodingError || AllocatorError;

/// Creates a `Query` extractor type for a single query parameter.
///
/// The resulting extractor struct contains:
/// - `result`: `QueryError!?[]const u8`
///
/// `result` semantics:
/// - `error`: malformed percent-encoding or allocator failure while decoding
/// - `null`: query string missing, parameter missing, or parameter present with an empty value
/// - `[]const u8`: decoded parameter value
///
/// Parameter-name matching is case-insensitive and compares against the decoded key.
/// Value decoding is single-pass (`+` -> space, `%XX` escapes decoded once).
///
/// The extractor can be used either:
/// - as a router handler parameter (automatic injection), or
/// - manually inside a handler body with `Query(name).init(ctx)`.
///
/// ```zig
/// fn handleRequest(ctx: Context, filter: Query("filter")) !Response {
///     const maybe_filter = filter.result catch |e| {
///         _ = e;
///         return Response.badRequest();
///     };
///
///     _ = ctx;
///     _ = maybe_filter;
///     return Response.ok();
/// }
/// ```
pub fn Query(comptime name: []const u8) type {
    assert(name.len > 0);
    return struct {
        pub const ID: []const u8 = EXTRACTOR_ID;
        pub const PARAM_NAME: []const u8 = name;

        result: QueryError!?[]const u8,

        pub fn init(ctx: Context) QueryError!?[]const u8 {
            return try extract(name, ctx.request_allocator, ctx.request);
        }
    };
}

pub const Resolver = struct {
    pub fn matches(comptime Extractor: type) bool {
        if (!@hasDecl(Extractor, "ID")) return false;
        return std.mem.eql(u8, @field(Extractor, "ID"), EXTRACTOR_ID);
    }

    pub fn resolve(comptime Extractor: type, arena: Allocator, req: *Request) Extractor {
        comptime assert(@hasDecl(Extractor, "PARAM_NAME"));
        const result = extract(@field(Extractor, "PARAM_NAME"), arena, req);
        return .{ .result = result };
    }
};

const testing = std.testing;
const Server = std.http.Server;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

test "Query.init returns value when query param is present" {
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
        .request_allocator = testing_arena,
        .request = &http_req,
    };

    const res = try Query("name").init(test_ctx);
    try testing.expect(res != null);
    try testing.expectEqualStrings("zig", res.?);
}

test "Query.init returns null when parameter is absent" {
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
        .request_allocator = testing_arena,
        .request = &http_req,
    };

    const res = try Query("name").init(test_ctx);
    try testing.expectEqual(null, res);
}

test "Query.init returns null for empty parameter value" {
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
        .request_allocator = testing_arena,
        .request = &http_req,
    };

    const res = try Query("name").init(test_ctx);
    // Per extractor behavior an explicit empty value yields `null`
    try testing.expectEqual(null, res);
}

test "Query.init decodes percent-encoded and plus characters" {
    const encoded = "first+name%3Dzig%20lang";
    const req_bytes = std.fmt.comptimePrint("GET /search?name={s} HTTP/1.1\r\n\r\n", .{encoded});
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

    const res = try Query("name").init(test_ctx);
    try testing.expect(res != null);
    try testing.expectEqualStrings("first name=zig lang", res.?);
}

test "Query.init returns InvalidPercentEncoding on malformed escapes" {
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
        .request_allocator = testing_arena,
        .request = &http_req,
    };

    try testing.expectError(utils.DecodingError.InvalidPercentEncoding, Query("name").init(test_ctx));
}

test "Query.init returns null when request has no query string" {
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
        .request_allocator = testing_arena,
        .request = &http_req,
    };

    const res = try Query("name").init(test_ctx);
    try testing.expectEqual(null, res);
}

test "Query.init matches decoded key name case-insensitively" {
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
        .request_allocator = testing_arena,
        .request = &http_req,
    };

    const res = try Query("FIRST NAME").init(test_ctx);
    try testing.expect(res != null);
    try testing.expectEqualStrings("Ana", res.?);
}

test "Query.Resolver.matches identifies query extractor types" {
    const OtherExtractor = struct {
        pub const ID: []const u8 = "OTHER_EXTRACTOR";
        pub const PARAM_NAME: []const u8 = "name";
    };

    try testing.expect(Resolver.matches(Query("name")));
    try testing.expect(!Resolver.matches(utils.TestExtractor));
    try testing.expect(!Resolver.matches(OtherExtractor));
}

test "Query.Resolver.resolve uses extractor PARAM_NAME" {
    const req_bytes = "GET /search?name=zig HTTP/1.1\r\n\r\n";
    var stream_buf_reader = Reader.fixed(req_bytes);

    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = Writer.fixed(&write_buffer);

    var http_server = Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const resolved = Resolver.resolve(Query("name"), arena.allocator(), &http_req);
    const value = try resolved.result;
    try testing.expectEqualStrings("zig", value.?);
}
