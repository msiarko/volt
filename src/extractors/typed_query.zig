const std = @import("std");
const StructField = std.builtin.Type.StructField;
const Allocator = std.mem.Allocator;
const AllocatorError = std.mem.Allocator.Error;
const Request = std.http.Server.Request;

const utils = @import("utils.zig");
const Context = @import("../Context.zig");

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

pub fn TypedQuery(comptime T: type) type {
    assert(T);
    return struct {
        pub const ID: []const u8 = EXTRACTOR_ID;
        pub const PAYLOAD_TYPE: type = T;

        result: TypedQueryError!?*T,

        pub fn init(ctx: Context) TypedQueryError!?*T {
            return try extract(T, ctx.req_arena, ctx.raw_req);
        }
    };
}

pub const Resolver = struct {
    pub const ID: []const u8 = EXTRACTOR_ID;

    pub fn resolve(comptime Extractor: type, ctx: Context) Extractor {
        comptime std.debug.assert(@hasDecl(Extractor, "PAYLOAD_TYPE"));
        return .{ .result = extract(@field(Extractor, "PAYLOAD_TYPE"), ctx.req_arena, ctx.raw_req) };
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
        .req_arena = testing_arena,
        .raw_req = &http_req,
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
        .req_arena = testing_arena,
        .raw_req = &http_req,
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
        .req_arena = testing_arena,
        .raw_req = &http_req,
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
        .req_arena = testing_arena,
        .raw_req = &http_req,
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
        .req_arena = testing_arena,
        .raw_req = &http_req,
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
        .req_arena = testing_arena,
        .raw_req = &http_req,
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
        .req_arena = testing_arena,
        .raw_req = &http_req,
    };

    const typed = try TypedQuery(Filter).init(test_ctx);
    try testing.expect(typed != null);
    try testing.expectEqualStrings("bob", typed.?.name.?);
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

    const test_ctx: Context = .{
        .io = undefined,
        .req_arena = arena.allocator(),
        .raw_req = &http_req,
    };
    const resolved = Resolver.resolve(TypedQuery(Filter), test_ctx);
    const value = try resolved.result;
    try testing.expect(value != null);
    try testing.expectEqualStrings("alice", value.?.name.?);
}
