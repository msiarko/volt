//! HTTP header extractor for the Volt web library.
//!
//! This module provides a lightweight extractor for HTTP request headers through
//! the router's parameter injection system. When a handler parameter is typed as
//! `Header("name")`, the library automatically resolves that parameter from the
//! incoming request headers.

const std = @import("std");
const Request = std.http.Server.Request;
const utils = @import("utils.zig");
const StructField = std.builtin.Type.StructField;

/// Key used to identify Header extractor types at compile time.
const HEADER_EXTRACTOR_KEY: []const u8 = "HEADER_EXTRACTOR";

/// Creates a Header extractor type for a specific HTTP header name.
///
/// The returned type contains an optional string value that is:
/// - `null` when the header is absent from the request
/// - `[]const u8` slice when the header is present (may be an empty string)
///
/// Header name comparison is case-sensitive and follows the exact casing
/// supplied to the extractor.
///
/// Example usage in a router handler:
/// ```zig
/// fn handleRequest(ctx: Context, auth: Header("Authorization")) !Response {
///     const token = auth.value orelse return Response.unauthorized();
///     // Use token...
/// }
/// ```
pub fn Header(comptime name: []const u8) type {
    return struct {
        const Self = @This();

        /// Extractor key for type identification.
        key: []const u8 = HEADER_EXTRACTOR_KEY,
        /// HTTP header name this extractor resolves.
        name: []const u8 = name,
        /// Extracted header value, or null when the header is absent.
        value: ?[]const u8,

        /// Extracts the configured HTTP header from the request.
        ///
        /// Iterates over all request headers and returns the value of the first
        /// header whose name equals `name`. Returns `null` when no matching
        /// header is found.
        pub fn init(req: *Request) Self {
            var header_it = req.iterateHeaders();
            while (header_it.next()) |entry| {
                if (std.mem.eql(u8, entry.name, name)) {
                    return .{ .value = entry.value };
                }
            }

            return .{ .value = null };
        }
    };
}

/// Returns the compile-time header name from a Header extractor type.
///
/// Compile errors:
/// - `expected Header extractor type`: Triggered when the type doesn't match.
fn getParamName(comptime T: type) []const u8 {
    if (!Resolver.matches(T)) {
        @compileError("expected Header extractor type");
    }

    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (std.mem.eql(u8, field.name, "name")) {
            if (StructField.defaultValue(field)) |name| {
                return name;
            }
        }
    }
}

/// Resolver for Header extractors in the compile-time registry.
///
/// This struct implements the resolver interface (`matches` and `resolve`) to enable
/// automatic detection and instantiation of Header extractor types during parameter
/// resolution.
pub const Resolver = struct {
    pub fn matches(comptime T: type) bool {
        return utils.matches(T, HEADER_EXTRACTOR_KEY);
    }

    pub fn resolve(comptime T: type, allocator: std.mem.Allocator, req: *Request) T {
        _ = allocator;
        const param_name = comptime getParamName(T);
        return Header(param_name).init(req);
    }
};

test "Resolver.matches returns true for Header extractor" {
    try std.testing.expect(comptime Resolver.matches(Header("Authorization")));
}

test "Resolver.matches returns false for non-Header extractor" {
    const Person = struct {
        name: []const u8,
        age: u8,
    };

    try std.testing.expect(!comptime Resolver.matches(Person));
}

test "getParamName returns configured header name" {
    try std.testing.expectEqualStrings("Authorization", comptime getParamName(Header("Authorization")));
}

test "init returns Header with value when header is present" {
    const req_bytes = "GET / HTTP/1.1\r\nAuthorization: Bearer token123\r\n\r\n";
    var stream_buf_reader = std.Io.Reader.fixed(req_bytes);

    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = std.Io.Writer.fixed(&write_buffer);

    var http_server = std.http.Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    const header = Header("Authorization").init(&http_req);

    try std.testing.expect(header.value != null);
    try std.testing.expectEqualStrings("Bearer token123", header.value.?);
}

test "init returns Header with value when multiple headers are present" {
    const req_bytes = "GET / HTTP/1.1\r\nContent-Type: application/json\r\nX-Request-Id: abc-123\r\n\r\n";
    var stream_buf_reader = std.Io.Reader.fixed(req_bytes);

    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = std.Io.Writer.fixed(&write_buffer);

    var http_server = std.http.Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    const header = Header("X-Request-Id").init(&http_req);

    try std.testing.expect(header.value != null);
    try std.testing.expectEqualStrings("abc-123", header.value.?);
}

test "init returns null when header is not present" {
    const req_bytes = "GET / HTTP/1.1\r\nContent-Type: application/json\r\n\r\n";
    var stream_buf_reader = std.Io.Reader.fixed(req_bytes);

    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = std.Io.Writer.fixed(&write_buffer);

    var http_server = std.http.Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    const header = Header("Authorization").init(&http_req);

    try std.testing.expectEqual(null, header.value);
}

test "init returns null when no headers are present" {
    const req_bytes = "GET / HTTP/1.1\r\n\r\n";
    var stream_buf_reader = std.Io.Reader.fixed(req_bytes);

    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = std.Io.Writer.fixed(&write_buffer);

    var http_server = std.http.Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    const header = Header("Authorization").init(&http_req);

    try std.testing.expectEqual(null, header.value);
}

test "init table-driven header extraction" {
    const cases = [_]struct {
        headers: []const u8,
        expected: ?[]const u8,
    }{
        .{ .headers = "Authorization: Bearer tok\r\n", .expected = "Bearer tok" },
        .{ .headers = "Content-Type: text/plain\r\n", .expected = null },
        .{ .headers = "", .expected = null },
    };

    inline for (cases) |case| {
        const req_bytes = std.fmt.comptimePrint("GET / HTTP/1.1\r\n{s}\r\n", .{case.headers});
        var stream_buf_reader = std.Io.Reader.fixed(req_bytes);

        var write_buffer: [4096]u8 = undefined;
        var stream_buf_writer = std.Io.Writer.fixed(&write_buffer);

        var http_server = std.http.Server.init(&stream_buf_reader, &stream_buf_writer);
        var http_req = try http_server.receiveHead();

        const header = Header("Authorization").init(&http_req);

        if (case.expected) |expected| {
            try std.testing.expectEqualStrings(expected, header.value.?);
        } else {
            try std.testing.expectEqual(null, header.value);
        }
    }
}
