const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const AllocatorError = std.mem.Allocator.Error;
const Request = std.http.Server.Request;
const StructField = std.builtin.Type.StructField;

const Context = @import("../Context.zig");
const utils = @import("utils.zig");

const EXTRACTOR_ID: []const u8 = "VOLT_ROUTE_PARAM_EXTRACTOR";

fn extract(comptime name: []const u8, arena: Allocator, route_pattern: ?[]const u8, req: *Request) AllocatorError!?[]const u8 {
    const decoded_target = try utils.decodeUrl(arena, req.head.target);
    return resolveValue(name, route_pattern, decoded_target);
}

fn resolveValue(name: []const u8, route_pattern: ?[]const u8, req_target: []const u8) ?[]const u8 {
    const pattern = route_pattern orelse return null;
    const req_path = stripQuery(req_target);
    const pattern_path = stripQuery(pattern);
    const req_trimmed = if (req_path.len > 0 and req_path[0] == '/') req_path[1..] else req_path;
    const pattern_trimmed = if (pattern_path.len > 0 and pattern_path[0] == '/') pattern_path[1..] else pattern_path;
    var req_it = std.mem.splitScalar(u8, req_trimmed, '/');
    var pattern_it = std.mem.splitScalar(u8, pattern_trimmed, '/');
    while (pattern_it.next()) |pat_seg| {
        const req_seg = req_it.next() orelse return null;
        if (pat_seg.len > 0 and pat_seg[0] == ':') {
            if (std.mem.eql(u8, pat_seg[1..], name)) {
                return req_seg;
            }
        } else if (!std.mem.eql(u8, pat_seg, req_seg)) {
            return null;
        }
    }

    return null;
}

fn stripQuery(target: []const u8) []const u8 {
    if (std.mem.findScalar(u8, target, '?')) |idx| {
        return target[0..idx];
    }

    return target;
}

/// Creates a 'RouteParam' extractor type
///
/// Fields:
/// - `value`: An optional slice of bytes that contains the value of the route parameter if it is present in the request, or `null` if the parameter is absent.
///
/// The extractor can be used either:
/// - as a router handler parameter (automatic injection), or
/// - manually inside a handler body with `RouteParam(name).init(ctx)`.
///
/// ```zig
/// fn handleRequest(ctx: Context, id: RouteParam("id")) !Response {
///    if (id.value) |id_value| {
///       // Use id_value...
///    }
/// }
/// ```
pub fn RouteParam(comptime name: []const u8) type {
    assert(name.len > 0);
    return struct {
        pub const ID: []const u8 = EXTRACTOR_ID;
        pub const PARAM_NAME: []const u8 = name;

        result: AllocatorError!?[]const u8,

        pub fn init(ctx: Context) AllocatorError!?[]const u8 {
            return extract(name, ctx.req_arena, ctx.raw_req);
        }
    };
}

pub const Resolver = struct {
    pub fn matches(comptime Extractor: type) bool {
        if (!@hasDecl(Extractor, "ID")) return false;
        return std.mem.eql(u8, @field(Extractor, "ID"), EXTRACTOR_ID);
    }

    pub fn resolve(comptime Extractor: type, arena: Allocator, route_pattern: ?[]const u8, req: *Request) Extractor {
        comptime assert(@hasDecl(Extractor, "PARAM_NAME"));
        const result = extract(@field(Extractor, "PARAM_NAME"), arena, route_pattern, req);
        return .{ .result = result };
    }
};

const Server = std.http.Server;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const testing = std.testing;

test "extract returns value when key matches" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const req_bytes = "GET /users/42 HTTP/1.1\r\n\r\n";
    var stream_buf_reader = Reader.fixed(req_bytes);
    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = Writer.fixed(&write_buffer);
    var http_server = Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    const result = try extract("id", arena.allocator(), "/users/:id", &http_req);
    try testing.expectEqualStrings("42", result.?);
}

test "extract returns null when key is absent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const req_bytes = "GET /users/alice HTTP/1.1\r\n\r\n";
    var stream_buf_reader = Reader.fixed(req_bytes);
    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = Writer.fixed(&write_buffer);
    var http_server = Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    const result = try extract("id", arena.allocator(), "/accounts/:name", &http_req);
    try testing.expect(result == null);
}

test "extract resolves multiple params from one pattern" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const req_bytes = "GET /teams/abc/users/42 HTTP/1.1\r\n\r\n";
    var stream_buf_reader = Reader.fixed(req_bytes);
    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = Writer.fixed(&write_buffer);
    var http_server = Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    const allocator = arena.allocator();
    const team_id = try extract("team_id", allocator, "/teams/:team_id/users/:user_id", &http_req);
    const user_id = try extract("user_id", allocator, "/teams/:team_id/users/:user_id", &http_req);

    try testing.expectEqualStrings("abc", team_id.?);
    try testing.expectEqualStrings("42", user_id.?);
}

test "extract returns decoded segment" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const req_bytes = "GET /blocks/hello%20world HTTP/1.1\r\n\r\n";
    var stream_buf_reader = Reader.fixed(req_bytes);
    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = Writer.fixed(&write_buffer);
    var http_server = Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    const result = try extract("name", arena.allocator(), "/blocks/:name", &http_req);
    try testing.expectEqualStrings("hello world", result.?);
}

test "extract returns original segment on malformed percent escape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const req_bytes = "GET /blocks/hello%2 HTTP/1.1\r\n\r\n";
    var stream_buf_reader = Reader.fixed(req_bytes);
    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = Writer.fixed(&write_buffer);
    var http_server = Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    const result = try extract("name", arena.allocator(), "/blocks/:name", &http_req);
    try testing.expectEqualStrings("hello%2", result.?);
}

test "extract returns null when route pattern is missing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const req_bytes = "GET /users/42 HTTP/1.1\r\n\r\n";
    var stream_buf_reader = Reader.fixed(req_bytes);
    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = Writer.fixed(&write_buffer);
    var http_server = Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    const result = try extract("id", arena.allocator(), null, &http_req);
    try testing.expectEqual(null, result);
}

test "extract strips query from target and route pattern" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const req_bytes = "GET /users/42?verbose=true HTTP/1.1\r\n\r\n";
    var stream_buf_reader = Reader.fixed(req_bytes);
    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = Writer.fixed(&write_buffer);
    var http_server = Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    const result = try extract("id", arena.allocator(), "/users/:id?unused=true", &http_req);
    try testing.expectEqualStrings("42", result.?);
}

test "Resolver.matches identifies route param extractor types" {
    const OtherExtractor = struct {
        pub const ID: []const u8 = "OTHER_EXTRACTOR";
        pub const PARAM_NAME: []const u8 = "id";
    };

    try testing.expect(Resolver.matches(RouteParam("id")));
    try testing.expect(!Resolver.matches(utils.TestExtractor));
    try testing.expect(!Resolver.matches(OtherExtractor));
}

test "Resolver.resolve uses route pattern" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const req_bytes = "GET /users/42 HTTP/1.1\r\n\r\n";
    var stream_buf_reader = Reader.fixed(req_bytes);
    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = Writer.fixed(&write_buffer);
    var http_server = Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    const resolved = Resolver.resolve(RouteParam("id"), arena.allocator(), "/users/:id", &http_req);
    try testing.expectEqualStrings("42", (try resolved.result).?);
}
