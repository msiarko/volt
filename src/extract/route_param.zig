//! Path parameter extractor for the Volt web library.
//!
//! This module provides a lightweight extractor for URL path parameters through
//! the router's parameter injection system. When a handler parameter is typed as
//! `RouteParam("id")`, the library automatically resolves that parameter from the
//! matched route's captured path segments (e.g., `:id` in `/users/:id`).

const std = @import("std");
const Request = std.http.Server.Request;
const StructField = std.builtin.Type.StructField;

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

        // Raw whitespace and ASCII controls are invalid in URI path segments.
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

/// Extracts the configured path parameter by comparing the matched
/// route pattern (e.g., `/users/:id`) against the request target.
fn initRouteParam(comptime name: []const u8, route_pattern: ?[]const u8, req: *Request) RouteParam(name) {
    return .{ .value = resolveValue(name, route_pattern, req.head.target) };
}

/// Creates a RouteParam extractor type for a specific path parameter name.
///
/// The returned type contains an optional string value that is:
/// - `null` when the route has no matching `:name` segment
/// - `[]const u8` slice of the captured segment value otherwise
///
/// Example usage in a route handler:
/// ```zig
/// // Route registered as: router.get("/users/:id", &handler)
/// fn handler(ctx: Context, state: *State, id: RouteParam("id")) !Response {
///     const user_id = id.value orelse return Response.badRequest();
///     // user_id is the captured segment, e.g., "42" for /users/42
/// }
/// ```
pub fn RouteParam(comptime name: []const u8) type {
    return struct {
        const Self = @This();

        /// Compile-time marker used to identify RouteParam extractor types.
        pub const VOLT_ROUTE_PARAM_EXTRACTOR = true;

        /// Path parameter name this extractor resolves.
        name: []const u8 = name,
        /// Captured value of the path segment, or null when not present.
        value: ?[]const u8,
    };
}

fn stripQuery(target: []const u8) []const u8 {
    if (std.mem.findScalar(u8, target, '?')) |idx| {
        return target[0..idx];
    }
    return target;
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

fn getParamName(comptime T: type) []const u8 {
    if (!Resolver.matches(T)) {
        @compileError("expected RouteParam extractor type");
    }

    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (std.mem.eql(u8, field.name, "name")) {
            if (StructField.defaultValue(field)) |n| {
                return n;
            }
        }
    }

    unreachable;
}

/// Resolver for RouteParam extractors in the compile-time registry.
pub const Resolver = struct {
    pub fn matches(comptime T: type) bool {
        return @typeInfo(T) == .@"struct" and
            @hasDecl(T, "VOLT_ROUTE_PARAM_EXTRACTOR") and
            @field(T, "VOLT_ROUTE_PARAM_EXTRACTOR");
    }

    pub fn resolve(comptime T: type, allocator: std.mem.Allocator, route_pattern: ?[]const u8, req: *Request) T {
        _ = allocator;
        const param_name = comptime getParamName(T);
        return initRouteParam(param_name, route_pattern, req);
    }
};

test "Resolver.matches returns true for RouteParam extractor" {
    try std.testing.expect(comptime Resolver.matches(RouteParam("id")));
}

test "Resolver.matches returns false for non-RouteParam type" {
    const Other = struct { name: []const u8 };
    try std.testing.expect(!comptime Resolver.matches(Other));
}

test "RouteParam.init returns value when key matches" {
    const req_bytes = "GET /users/42 HTTP/1.1\r\n\r\n";
    var stream_buf_reader = std.Io.Reader.fixed(req_bytes);
    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = std.Io.Writer.fixed(&write_buffer);
    var http_server = std.http.Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    const result = initRouteParam("id", "/users/:id", &http_req);
    try std.testing.expectEqualStrings("42", result.value.?);
}

test "RouteParam.init returns null when key is absent" {
    const req_bytes = "GET /users/alice HTTP/1.1\r\n\r\n";
    var stream_buf_reader = std.Io.Reader.fixed(req_bytes);
    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = std.Io.Writer.fixed(&write_buffer);
    var http_server = std.http.Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    const result = initRouteParam("id", "/accounts/:name", &http_req);
    try std.testing.expect(result.value == null);
}

test "RouteParam.init resolves multiple params from one pattern" {
    const req_bytes = "GET /teams/abc/users/42 HTTP/1.1\r\n\r\n";
    var stream_buf_reader = std.Io.Reader.fixed(req_bytes);
    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = std.Io.Writer.fixed(&write_buffer);
    var http_server = std.http.Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    const team_id = initRouteParam("team_id", "/teams/:team_id/users/:user_id", &http_req);
    const user_id = initRouteParam("user_id", "/teams/:team_id/users/:user_id", &http_req);

    try std.testing.expectEqualStrings("abc", team_id.value.?);
    try std.testing.expectEqualStrings("42", user_id.value.?);
}

test "RouteParam.init keeps valid encoded segment" {
    const req_bytes = "GET /blocks/hello%20world HTTP/1.1\r\n\r\n";
    var stream_buf_reader = std.Io.Reader.fixed(req_bytes);
    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = std.Io.Writer.fixed(&write_buffer);
    var http_server = std.http.Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    const result = initRouteParam("name", "/blocks/:name", &http_req);
    try std.testing.expectEqualStrings("hello%20world", result.value.?);
}

test "RouteParam.init rejects malformed encoded segment" {
    const req_bytes = "GET /blocks/hello%2 HTTP/1.1\r\n\r\n";
    var stream_buf_reader = std.Io.Reader.fixed(req_bytes);
    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = std.Io.Writer.fixed(&write_buffer);
    var http_server = std.http.Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    const result = initRouteParam("name", "/blocks/:name", &http_req);
    try std.testing.expectEqual(null, result.value);
}
