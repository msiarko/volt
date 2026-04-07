//! Query parameter extractor for the Volt web library.
//!
//! This module provides a lightweight extractor for URL query parameters through
//! the router's parameter injection system. When a handler parameter is typed as
//! `Query("name")`, the library automatically resolves that parameter from the
//! request target query string.

const std = @import("std");
const utils = @import("utils.zig");
const Request = std.http.Server.Request;
const StructField = std.builtin.Type.StructField;

/// Key used to identify Query extractor types at compile time.
const QUERY_EXTRACTOR_KEY: []const u8 = "QUERY_EXTRACTOR";

/// Checks if a type is a Query extractor by examining its structure.
///
/// This function uses compile-time reflection to determine if the given type
/// has a field named "key" with the default value "QUERY_EXTRACTOR".
pub fn matches(comptime T: type) bool {
    return utils.matches(T, QUERY_EXTRACTOR_KEY);
}

/// Returns the compile-time query parameter name from a Query extractor type.
///
/// Compile errors:
/// - `Type is not a Query extractor`: Triggered when `matches(T)` is false
pub fn getParamName(comptime T: type) []const u8 {
    if (!matches(T)) {
        @compileError("Type is not a Query extractor");
    }

    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (std.mem.eql(u8, field.name, "name")) {
            if (StructField.defaultValue(field)) |name| {
                return name;
            }
        }
    }
}

/// Creates a Query extractor type for a specific query parameter key.
///
/// The returned type contains an optional string value that is:
/// - `null` when the parameter is missing
/// - `null` when the parameter exists but has an empty value
/// - `[]const u8` slice when the parameter exists with a non-empty value
pub fn Query(comptime name: []const u8) type {
    return struct {
        const Self = @This();

        /// Extractor key for type identification.
        key: []const u8 = QUERY_EXTRACTOR_KEY,
        /// Extracted query value for `name`, or null when not available.
        value: ?[]const u8,
        /// Query parameter name this extractor resolves.
        name: []const u8 = name,

        /// Extracts the configured query parameter from the request target.
        ///
        /// This method parses the portion of the request URL after `?`, splits
        /// pairs by `&`, and returns the value for the configured key.
        pub fn init(req: *Request) Self {
            var start_idx = std.mem.findScalar(u8, req.head.target, '?') orelse return .{ .value = null };
            start_idx += 1;
            var query_params = std.mem.splitScalar(u8, req.head.target[start_idx..], '&');
            while (query_params.next()) |first_param| {
                var key_value = std.mem.splitScalar(u8, first_param, '=');
                const key = key_value.next() orelse continue;
                if (std.mem.eql(u8, key, name)) {
                    if (key_value.next()) |value| {
                        if (value.len == 0) {
                            return .{ .value = null };
                        }

                        return .{ .value = value };
                    }
                }
            }

            return .{ .value = null };
        }
    };
}

test "init returns Query with value when query parameter is present" {
    const req_bytes = std.fmt.comptimePrint("GET /person?name=Ziggy HTTP/1.1\r\n" ++ "\r\n", .{});
    var stream_buf_reader = std.Io.Reader.fixed(req_bytes);

    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = std.Io.Writer.fixed(&write_buffer);

    var http_server = std.http.Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    const query = Query("name").init(&http_req);

    try std.testing.expect(query.value != null);
    try std.testing.expectEqualStrings("Ziggy", query.value.?);
}

test "init returns Query with value when multiple query parameters are present" {
    const req_bytes = std.fmt.comptimePrint("GET /person?name=Ziggy&age=30 HTTP/1.1\r\n" ++ "\r\n", .{});
    var stream_buf_reader = std.Io.Reader.fixed(req_bytes);

    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = std.Io.Writer.fixed(&write_buffer);

    var http_server = std.http.Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    const query = Query("age").init(&http_req);

    try std.testing.expect(query.value != null);
    try std.testing.expectEqualStrings("30", query.value.?);
}

test "init returns Query without value when query parameter is not present" {
    const req_bytes = std.fmt.comptimePrint("GET /person?name=Ziggy&age=30 HTTP/1.1\r\n" ++ "\r\n", .{});
    var stream_buf_reader = std.Io.Reader.fixed(req_bytes);

    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = std.Io.Writer.fixed(&write_buffer);

    var http_server = std.http.Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    const query = Query("nonexistent").init(&http_req);

    try std.testing.expectEqual(null, query.value);
}

test "init returns Query without value when query parameter is present but has no value" {
    const req_bytes = std.fmt.comptimePrint("GET /person?name=&age=30 HTTP/1.1\r\n" ++ "\r\n", .{});
    var stream_buf_reader = std.Io.Reader.fixed(req_bytes);

    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = std.Io.Writer.fixed(&write_buffer);

    var http_server = std.http.Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    const query = Query("name").init(&http_req);

    try std.testing.expectEqual(null, query.value);
}
