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
            var query_it = utils.queryIterator(req.head.target) orelse return .{ .value = null };
            while (query_it.next()) |entry| {
                if (std.ascii.eqlIgnoreCase(entry.key, name)) {
                    return .{ .value = entry.value };
                }
            }

            return .{ .value = null };
        }
    };
}

/// Returns the compile-time query parameter name from a Query extractor type.
///
/// Compile errors:
/// - `expected Query extractor type`: Triggered when the type doesn't match
fn getParamName(comptime T: type) []const u8 {
    if (!Resolver.matches(T)) {
        @compileError("expected Query extractor type");
    }

    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (std.mem.eql(u8, field.name, "name")) {
            if (StructField.defaultValue(field)) |name| {
                return name;
            }
        }
    }
}

/// Resolver for Query extractors in the compile-time registry.
///
/// This struct implements the resolver interface (`matches` and `resolve`) to enable
/// automatic detection and instantiation of Query extractor types during parameter resolution.
pub const Resolver = struct {
    pub fn matches(comptime T: type) bool {
        return utils.matches(T, QUERY_EXTRACTOR_KEY);
    }

    pub fn resolve(comptime T: type, allocator: std.mem.Allocator, req: *Request) T {
        _ = allocator;
        const param_name = comptime getParamName(T);
        return Query(param_name).init(req);
    }
};

test "Resolver.matches returns true for Query extractor" {
    try std.testing.expect(comptime Resolver.matches(Query("name")));
}

test "Resolver.matches returns false for non-Query extractor" {
    const Person = struct {
        name: []const u8,
        age: u8,
    };

    try std.testing.expect(!comptime Resolver.matches(Person));
}

test "getParamName returns configured query name" {
    try std.testing.expectEqualStrings("name", comptime getParamName(Query("name")));
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

test "init returns Query without value when query string is missing" {
    const req_bytes = std.fmt.comptimePrint("GET /person HTTP/1.1\r\n" ++ "\r\n", .{});
    var stream_buf_reader = std.Io.Reader.fixed(req_bytes);

    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = std.Io.Writer.fixed(&write_buffer);

    var http_server = std.http.Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    const query = Query("name").init(&http_req);

    try std.testing.expectEqual(null, query.value);
}

test "init table-driven query extraction" {
    const cases = [_]struct {
        target: []const u8,
        expected: ?[]const u8,
    }{
        .{ .target = "/person?name=Ziggy", .expected = "Ziggy" },
        .{ .target = "/person?name=", .expected = null },
        .{ .target = "/person?age=30", .expected = null },
        .{ .target = "/person", .expected = null },
    };

    inline for (cases) |case| {
        const req_bytes = std.fmt.comptimePrint("GET {s} HTTP/1.1\r\n\r\n", .{case.target});
        var stream_buf_reader = std.Io.Reader.fixed(req_bytes);

        var write_buffer: [4096]u8 = undefined;
        var stream_buf_writer = std.Io.Writer.fixed(&write_buffer);

        var http_server = std.http.Server.init(&stream_buf_reader, &stream_buf_writer);
        var http_req = try http_server.receiveHead();

        const query = Query("name").init(&http_req);
        if (case.expected) |expected| {
            try std.testing.expectEqualStrings(expected, query.value.?);
        } else {
            try std.testing.expectEqual(null, query.value);
        }
    }
}
