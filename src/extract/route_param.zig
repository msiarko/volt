const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Request = std.http.Server.Request;
const StructField = std.builtin.Type.StructField;

const Context = @import("../http/context.zig").Context;
const utils = @import("utils.zig");

const EXTRACTOR_ID: []const u8 = "VOLT_ROUTE_PARAM_EXTRACTOR";

fn extract(comptime name: []const u8, route_pattern: ?[]const u8, req: *Request) RouteParam(name) {
    return .{ .value = resolveValue(name, route_pattern, req.head.target) };
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
                if (!isValidEncodedPathSegment(req_seg)) return null;
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

fn isHexDigit(c: u8) bool {
    return switch (c) {
        '0'...'9', 'a'...'f', 'A'...'F' => true,
        else => false,
    };
}

fn isValidEncodedPathSegment(seg: []const u8) bool {
    var i: usize = 0;
    while (i < seg.len) {
        const c = seg[i];

        if (std.ascii.isWhitespace(c) or c < 0x20 or c == 0x7f) return false;

        if (c == '%') {
            if (i + 2 >= seg.len) return false;
            if (!isHexDigit(seg[i + 1]) or !isHexDigit(seg[i + 2])) return false;
            i += 3;
            continue;
        }

        i += 1;
    }

    return true;
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
        const Self = @This();

        pub const ID: []const u8 = EXTRACTOR_ID;
        pub const PARAM_NAME: []const u8 = name;

        value: ?[]const u8,

        pub fn init(ctx: Context) Self {
            return extract(name, ctx.request);
        }
    };
}

pub const Resolver = struct {
    pub fn matches(comptime Extractor: type) bool {
        if (!@hasDecl(Extractor, "ID")) return false;
        return std.mem.eql(u8, @field(Extractor, "ID"), EXTRACTOR_ID);
    }

    pub fn resolve(comptime Extractor: type, arena: Allocator, route_pattern: ?[]const u8, req: *Request) Extractor {
        _ = arena;
        comptime assert(@hasDecl(Extractor, "PARAM_NAME"));
        return extract(@field(Extractor, "PARAM_NAME"), route_pattern, req);
    }
};

const Server = std.http.Server;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const testing = std.testing;

test "RouteParam.init returns value when key matches" {
    const req_bytes = "GET /users/42 HTTP/1.1\r\n\r\n";
    var stream_buf_reader = Reader.fixed(req_bytes);
    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = Writer.fixed(&write_buffer);
    var http_server = Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    const result = extract("id", "/users/:id", &http_req);
    try testing.expectEqualStrings("42", result.value.?);
}

test "RouteParam.init returns null when key is absent" {
    const req_bytes = "GET /users/alice HTTP/1.1\r\n\r\n";
    var stream_buf_reader = Reader.fixed(req_bytes);
    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = Writer.fixed(&write_buffer);
    var http_server = Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    const result = extract("id", "/accounts/:name", &http_req);
    try testing.expect(result.value == null);
}

test "RouteParam.init resolves multiple params from one pattern" {
    const req_bytes = "GET /teams/abc/users/42 HTTP/1.1\r\n\r\n";
    var stream_buf_reader = Reader.fixed(req_bytes);
    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = Writer.fixed(&write_buffer);
    var http_server = Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    const team_id = extract("team_id", "/teams/:team_id/users/:user_id", &http_req);
    const user_id = extract("user_id", "/teams/:team_id/users/:user_id", &http_req);

    try testing.expectEqualStrings("abc", team_id.value.?);
    try testing.expectEqualStrings("42", user_id.value.?);
}

test "RouteParam.init keeps valid encoded segment" {
    const req_bytes = "GET /blocks/hello%20world HTTP/1.1\r\n\r\n";
    var stream_buf_reader = Reader.fixed(req_bytes);
    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = Writer.fixed(&write_buffer);
    var http_server = Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    const result = extract("name", "/blocks/:name", &http_req);
    try testing.expectEqualStrings("hello%20world", result.value.?);
}

test "RouteParam.init rejects malformed encoded segment" {
    const req_bytes = "GET /blocks/hello%2 HTTP/1.1\r\n\r\n";
    var stream_buf_reader = Reader.fixed(req_bytes);
    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = Writer.fixed(&write_buffer);
    var http_server = Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    const result = extract("name", "/blocks/:name", &http_req);
    try testing.expectEqual(null, result.value);
}

test "RouteParam.extract returns null when route pattern is missing" {
    const req_bytes = "GET /users/42 HTTP/1.1\r\n\r\n";
    var stream_buf_reader = Reader.fixed(req_bytes);
    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = Writer.fixed(&write_buffer);
    var http_server = Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    const result = extract("id", null, &http_req);
    try testing.expectEqual(null, result.value);
}

test "RouteParam.extract strips query from target and route pattern" {
    const req_bytes = "GET /users/42?verbose=true HTTP/1.1\r\n\r\n";
    var stream_buf_reader = Reader.fixed(req_bytes);
    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = Writer.fixed(&write_buffer);
    var http_server = Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    const result = extract("id", "/users/:id?unused=true", &http_req);
    try testing.expectEqualStrings("42", result.value.?);
}

test "RouteParam.Resolver.matches identifies route param extractor types" {
    const OtherExtractor = struct {
        pub const ID: []const u8 = "OTHER_EXTRACTOR";
        pub const PARAM_NAME: []const u8 = "id";
    };

    try testing.expect(Resolver.matches(RouteParam("id")));
    try testing.expect(!Resolver.matches(utils.TestExtractor));
    try testing.expect(!Resolver.matches(OtherExtractor));
}

test "RouteParam.Resolver.resolve uses route pattern" {
    const req_bytes = "GET /users/42 HTTP/1.1\r\n\r\n";
    var stream_buf_reader = Reader.fixed(req_bytes);
    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = Writer.fixed(&write_buffer);
    var http_server = Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    const resolved = Resolver.resolve(RouteParam("id"), testing.allocator, "/users/:id", &http_req);
    try testing.expectEqualStrings("42", resolved.value.?);
}
