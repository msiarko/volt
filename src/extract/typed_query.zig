const std = @import("std");
const Allocator = std.mem.Allocator;
const AllocatorError = std.mem.Allocator.Error;
const Request = std.http.Server.Request;

const url = @import("url.zig");
const Context = @import("core").Context;
const QueryIterator = @import("QueryIterator.zig");

const TypedQueryError = AllocatorError || url.ParseError;

fn assert(comptime T: type) void {
    const type_info = @typeInfo(T);
    if (type_info != .@"struct") {
        @compileError("Type is not a struct");
    }

    const field_types = type_info.@"struct".field_types;
    const field_names = type_info.@"struct".field_names;

    inline for (field_types, field_names) |field_type, field_name| {
        if (@typeInfo(field_type) != .optional) {
            @compileError(field_name ++ " field must be of type optional");
        }
    }
}

fn extract(comptime T: type, arena: Allocator, req: *Request) TypedQueryError!?*T {
    var query_it = QueryIterator.init(req.head.target) orelse return null;
    var typed_query = try arena.create(T);
    errdefer arena.destroy(typed_query);

    const type_info = @typeInfo(T);
    const field_names = type_info.@"struct".field_names;
    const field_types = type_info.@"struct".field_types;
    inline for (field_names) |field_name| {
        @field(typed_query, field_name) = null;
    }

    while (query_it.next()) |entry| {
        const value = entry.value orelse continue;

        var matched = false;
        inline for (field_names) |field_name| {
            if (std.ascii.eqlIgnoreCase(entry.key, field_name)) {
                matched = true;
            }
        }

        const key = if (matched)
            entry.key
        else
            try url.decode(arena, entry.key);

        inline for (field_names, field_types) |field_name, field_type| {
            if (std.ascii.eqlIgnoreCase(key, field_name)) {
                const decoded_value = try url.decode(arena, value);
                const child_field_type = @typeInfo(field_type).optional.child;
                @field(typed_query, field_name) = try url.parse(child_field_type, decoded_value);
            }
        }
    }

    return typed_query;
}

pub fn TypedQuery(comptime T: type) type {
    comptime assert(T);
    return struct {
        const Self = @This();

        value: ?*T,

        pub fn init(ctx: Context) TypedQueryError!Self {
            return .{ .value = try extract(T, ctx.req_arena, ctx.raw_req) };
        }
    };
}

test "TypedQuery.init returns null when no query string is present" {
    const testing = std.testing;
    const Server = std.http.Server;
    const Reader = std.Io.Reader;
    const Writer = std.Io.Writer;

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

    const filter = try TypedQuery(Filter).init(test_ctx);
    try testing.expectEqual(null, filter.value);
}

test "TypedQuery.init maps fields from query parameters" {
    const testing = std.testing;
    const Server = std.http.Server;
    const Reader = std.Io.Reader;
    const Writer = std.Io.Writer;

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

    const filter = try TypedQuery(Filter).init(test_ctx);
    try testing.expect(filter.value != null);
    try testing.expectEqualStrings("alice", filter.value.?.name.?);
    try testing.expectEqual(30, filter.value.?.age.?);
}

test "TypedQuery.init returns pointer with null fields when query present but no matching fields" {
    const testing = std.testing;
    const Server = std.http.Server;
    const Reader = std.Io.Reader;
    const Writer = std.Io.Writer;

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

    const filter = try TypedQuery(Filter).init(test_ctx);
    // When a query string exists but none of the struct fields are present,
    // the extractor returns a pointer to the struct with all fields set to null.
    try testing.expect(filter.value != null);
    try testing.expectEqual(null, filter.value.?.a);
    try testing.expectEqual(null, filter.value.?.b);
}

test "TypedQuery.init field name matching is case-insensitive" {
    const testing = std.testing;
    const Server = std.http.Server;
    const Reader = std.Io.Reader;
    const Writer = std.Io.Writer;

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

    const filter = try TypedQuery(Filter).init(test_ctx);
    try testing.expect(filter.value != null);
    try testing.expectEqualStrings("Bob", filter.value.?.name.?);
}

test "TypedQuery.init keeps matched empty values as null" {
    const testing = std.testing;
    const Server = std.http.Server;
    const Reader = std.Io.Reader;
    const Writer = std.Io.Writer;

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

    const filter = try TypedQuery(Filter).init(test_ctx);
    try testing.expect(filter.value != null);
    try testing.expectEqual(null, filter.value.?.name);
}

test "TypedQuery.init returns source value when percent decoding is not needed" {
    const testing = std.testing;
    const Server = std.http.Server;
    const Reader = std.Io.Reader;
    const Writer = std.Io.Writer;

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

    const filter = try TypedQuery(Filter).init(test_ctx);
    try testing.expectEqualStrings("bad%2", filter.value.?.name.?);
}

test "TypedQuery.init uses last value for duplicate keys" {
    const testing = std.testing;
    const Server = std.http.Server;
    const Reader = std.Io.Reader;
    const Writer = std.Io.Writer;

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

    const filter = try TypedQuery(Filter).init(test_ctx);
    try testing.expect(filter.value != null);
    try testing.expectEqualStrings("bob", filter.value.?.name.?);
}
