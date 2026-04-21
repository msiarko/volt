const std = @import("std");
const StructField = std.builtin.Type.StructField;
const Allocator = std.mem.Allocator;
const AllocatorError = std.mem.Allocator.Error;
const Request = std.http.Server.Request;

const utils = @import("utils.zig");
const Context = @import("../http/context.zig").Context;

const EXTRACTOR_ID: []const u8 = "VOLT_TYPED_QUERY_EXTRACTOR";

const TypedQueryError = AllocatorError || utils.ParseError;

fn assert(comptime T: type) void {
    const type_info = @typeInfo(T);
    if (type_info != .@"struct") {
        @compileError("Type is not a struct");
    }

    inline for (std.meta.fields(T)) |field| {
        if (@typeInfo(field.type) != .optional) {
            @compileError(field.name ++ " field must be of type optional");
        }
    }
}

fn extract(comptime T: type, arena: Allocator, req: *Request) TypedQueryError!?*T {
    var query_it = utils.queryIterator(req.head.target) orelse return null;
    var typed_query = try arena.create(T);
    errdefer arena.destroy(typed_query);

    const fields = std.meta.fields(T);
    inline for (fields) |field| {
        @field(typed_query, field.name) = null;
    }

    while (query_it.next()) |entry| {
        const value = entry.value orelse continue;
        const key = try utils.decodeUrl(arena, entry.key);

        inline for (fields) |field| {
            if (std.ascii.eqlIgnoreCase(key, field.name)) {
                const decoded_value = try utils.decodeUrl(arena, value);
                const field_type = @typeInfo(field.type).optional.child;
                @field(typed_query, field.name) = try utils.parse(field_type, decoded_value);
            }
        }
    }

    return typed_query;
}

/// Creates a `TypedQuery` extractor type.
///
/// `T` must be a struct where every field is optional.
/// Field names are matched case-insensitively against query keys.
///
/// The resulting extractor struct contains:
/// - `result`: `QueryError!?*T`
///
/// `result` semantics:
/// - `error`: malformed percent-encoding or allocator failure
/// - `null`: request target has no query string
/// - `*T`: allocated struct with each field set from matching query keys (unmatched fields are `null`)
///
/// Values are single-pass decoded when needed (`+` -> space, `%XX` escapes decoded once).
///
/// The extractor can be used either:
/// - as a router handler parameter (automatic injection), or
/// - manually inside a handler body with `TypedQuery(T).init(ctx)`.
///
/// ```zig
/// const Filter = struct {
///     name: ?[]const u8,
///     age: ?u8,
/// };
///
/// fn handleRequest(ctx: Context, filter: TypedQuery(Filter)) !Response {
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
pub fn TypedQuery(comptime T: type) type {
    assert(T);
    return struct {
        pub const ID: []const u8 = EXTRACTOR_ID;
        pub const PAYLOAD_TYPE: type = T;

        result: TypedQueryError!?*T,

        pub fn init(ctx: Context) TypedQueryError!?*T {
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
        comptime std.debug.assert(@hasDecl(Extractor, "PAYLOAD_TYPE"));
        const result = extract(@field(Extractor, "PAYLOAD_TYPE"), arena, req);
        return .{ .result = result };
    }
};

const testing = std.testing;
const Server = std.http.Server;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

test "TypedQuery.init returns null when no query string is present" {
    const Filter = struct {
        name: ?[]const u8,
        age: ?[]const u8,
    };

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

    const result = try TypedQuery(Filter).init(test_ctx);
    try testing.expectEqual(null, result);
}

test "TypedQuery.init maps fields from query parameters" {
    const Filter = struct {
        name: ?[]const u8,
        age: ?u8,
    };

    const req_bytes = "GET /search?name=alice&age=30 HTTP/1.1\r\n\r\n";
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

    const typed = try TypedQuery(Filter).init(test_ctx);
    try testing.expect(typed != null);
    try testing.expectEqualStrings("alice", typed.?.name.?);
    try testing.expectEqual(30, typed.?.age.?);
}

test "TypedQuery.init returns pointer with null fields when query present but no matching fields" {
    const Filter = struct {
        a: ?[]const u8,
        b: ?[]const u8,
    };

    const req_bytes = "GET /search?q=abc&x=1 HTTP/1.1\r\n\r\n";
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

    const typed = try TypedQuery(Filter).init(test_ctx);
    // When a query string exists but none of the struct fields are present,
    // the extractor returns a pointer to the struct with all fields set to null.
    try testing.expect(typed != null);
    try testing.expectEqual(null, typed.?.a);
    try testing.expectEqual(null, typed.?.b);
}

test "TypedQuery.init field name matching is case-insensitive" {
    const Filter = struct {
        name: ?[]const u8,
    };

    const req_bytes = "GET /search?NaMe=Bob HTTP/1.1\r\n\r\n";
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

    const typed = try TypedQuery(Filter).init(test_ctx);
    try testing.expect(typed != null);
    try testing.expectEqualStrings("Bob", typed.?.name.?);
}

test "TypedQuery.init keeps matched empty values as null" {
    const Filter = struct {
        name: ?[]const u8,
    };

    const req_bytes = "GET /search?name= HTTP/1.1\r\n\r\n";
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

    const typed = try TypedQuery(Filter).init(test_ctx);
    try testing.expect(typed != null);
    try testing.expectEqual(null, typed.?.name);
}

test "TypedQuery.init returns source value when percent decoding is not needed" {
    const Filter = struct {
        name: ?[]const u8,
    };

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

    const typed = try TypedQuery(Filter).init(test_ctx);
    try testing.expectEqualStrings("bad%2", typed.?.name.?);
}

test "TypedQuery.init uses last value for duplicate keys" {
    const Filter = struct {
        name: ?[]const u8,
    };

    const req_bytes = "GET /search?name=alice&name=bob HTTP/1.1\r\n\r\n";
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

    const typed = try TypedQuery(Filter).init(test_ctx);
    try testing.expect(typed != null);
    try testing.expectEqualStrings("bob", typed.?.name.?);
}

test "TypedQuery.Resolver.matches identifies typed query extractor types" {
    const OtherExtractor = struct {
        pub const ID: []const u8 = "OTHER_EXTRACTOR";
        pub const PAYLOAD_TYPE: type = struct { name: ?[]const u8 };
    };

    const Filter = struct {
        name: ?[]const u8,
    };

    try testing.expect(Resolver.matches(TypedQuery(Filter)));
    try testing.expect(!Resolver.matches(utils.TestExtractor));
    try testing.expect(!Resolver.matches(OtherExtractor));
}

test "TypedQuery.Resolver.resolve populates result" {
    const Filter = struct {
        name: ?[]const u8,
    };

    const req_bytes = "GET /search?name=alice HTTP/1.1\r\n\r\n";
    var stream_buf_reader = Reader.fixed(req_bytes);

    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = Writer.fixed(&write_buffer);

    var http_server = Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const resolved = Resolver.resolve(TypedQuery(Filter), arena.allocator(), &http_req);
    const value = try resolved.result;
    try testing.expect(value != null);
    try testing.expectEqualStrings("alice", value.?.name.?);
}
