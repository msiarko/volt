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
const Context = @import("../http/context.zig").Context;

/// Extracts the configured query parameter from the request target.
///
/// This function parses the portion of the request URL after `?`, splits
/// pairs by `&`, and returns the value for the configured key.
fn initQuery(comptime name: []const u8, allocator: std.mem.Allocator, req: *Request) Query(name) {
    var query_it = utils.queryIterator(req.head.target) orelse return .{ .value = null };
    while (query_it.next()) |entry| {
        if (utils.queryComponentEqualsAsciiIgnoreCaseDecoded(entry.key, name)) {
            const value = if (entry.value) |raw_value|
                if (utils.queryComponentNeedsDecoding(raw_value))
                    utils.decodeQueryComponent(allocator, raw_value) catch null
                else
                    raw_value
            else
                null;

            return .{ .value = value };
        }
    }

    return .{ .value = null };
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

        /// Compile-time marker used to identify Query extractor types.
        pub const VOLT_QUERY_EXTRACTOR = true;

        /// Extracted query value for `name`, or null when not available.
        value: ?[]const u8,
        /// Query parameter name this extractor resolves.
        name: []const u8 = name,

        /// Extracts the configured query parameter from request context.
        ///
        /// When a request context is available, use this method for manual extraction.
        ///
        /// Parameters:
        /// - `ctx`: Request context (any type with request field). Use `ctx.io` for
        ///   any I/O operations required within the surrounding handler.
        ///
        /// Returns: Query extractor with the parameter value or null
        ///
        /// Example usage in a handler body:
        /// ```zig
        /// fn search(ctx: Context, state: *MyState) !Response {
        ///     const q = Query("q").fromContext(ctx);
        ///     if (q.value) |search_term| {
        ///         // Use search_term...
        ///     }
        /// }
        /// ```
        pub fn fromContext(ctx: Context) Self {
            return initQuery(name, ctx.request_allocator, ctx.request);
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
        return @typeInfo(T) == .@"struct" and
            @hasDecl(T, "VOLT_QUERY_EXTRACTOR") and
            @field(T, "VOLT_QUERY_EXTRACTOR");
    }

    pub fn resolve(comptime T: type, allocator: std.mem.Allocator, req: *Request) T {
        const param_name = comptime getParamName(T);
        return initQuery(param_name, allocator, req);
    }

    pub fn resolveWithContext(comptime T: type, ctx: Context) T {
        const param_name = comptime getParamName(T);
        return Query(param_name).fromContext(ctx);
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

    const test_ctx: Context = .{
        .io = undefined,
        .server_allocator = std.testing.allocator,
        .request_allocator = std.testing.allocator,
        .request = &http_req,
    };
    const query = Query("name").fromContext(test_ctx);

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

    const test_ctx: Context = .{
        .io = undefined,
        .server_allocator = std.testing.allocator,
        .request_allocator = std.testing.allocator,
        .request = &http_req,
    };
    const query = Query("age").fromContext(test_ctx);

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

    const test_ctx: Context = .{
        .io = undefined,
        .server_allocator = std.testing.allocator,
        .request_allocator = std.testing.allocator,
        .request = &http_req,
    };
    const query = Query("nonexistent").fromContext(test_ctx);

    try std.testing.expectEqual(null, query.value);
}

test "init returns Query without value when query parameter is present but has no value" {
    const req_bytes = std.fmt.comptimePrint("GET /person?name=&age=30 HTTP/1.1\r\n" ++ "\r\n", .{});
    var stream_buf_reader = std.Io.Reader.fixed(req_bytes);

    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = std.Io.Writer.fixed(&write_buffer);

    var http_server = std.http.Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    const test_ctx: Context = .{
        .io = undefined,
        .server_allocator = std.testing.allocator,
        .request_allocator = std.testing.allocator,
        .request = &http_req,
    };
    const query = Query("name").fromContext(test_ctx);

    try std.testing.expectEqual(null, query.value);
}

test "init returns Query without value when query string is missing" {
    const req_bytes = std.fmt.comptimePrint("GET /person HTTP/1.1\r\n" ++ "\r\n", .{});
    var stream_buf_reader = std.Io.Reader.fixed(req_bytes);

    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = std.Io.Writer.fixed(&write_buffer);

    var http_server = std.http.Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    const test_ctx: Context = .{
        .io = undefined,
        .server_allocator = std.testing.allocator,
        .request_allocator = std.testing.allocator,
        .request = &http_req,
    };
    const query = Query("name").fromContext(test_ctx);

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

        const test_ctx: Context = .{
            .io = undefined,
            .server_allocator = std.testing.allocator,
            .request_allocator = std.testing.allocator,
            .request = &http_req,
        };
        const query = Query("name").fromContext(test_ctx);
        if (case.expected) |expected| {
            try std.testing.expectEqualStrings(expected, query.value.?);
        } else {
            try std.testing.expectEqual(null, query.value);
        }
    }
}

test "init decodes encoded query keys and values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const req_bytes = std.fmt.comptimePrint("GET /person?first%20name=Zig+Lang HTTP/1.1\r\n" ++ "\r\n", .{});
    var stream_buf_reader = std.Io.Reader.fixed(req_bytes);

    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = std.Io.Writer.fixed(&write_buffer);

    var http_server = std.http.Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    const test_ctx: Context = .{
        .io = undefined,
        .server_allocator = std.testing.allocator,
        .request_allocator = arena.allocator(),
        .request = &http_req,
    };
    const query = Query("first name").fromContext(test_ctx);

    try std.testing.expect(query.value != null);
    try std.testing.expectEqualStrings("Zig Lang", query.value.?);
}

test "init returns null for malformed encoded query value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const req_bytes = std.fmt.comptimePrint("GET /person?name=Zig%2 HTTP/1.1\r\n" ++ "\r\n", .{});
    var stream_buf_reader = std.Io.Reader.fixed(req_bytes);

    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = std.Io.Writer.fixed(&write_buffer);

    var http_server = std.http.Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    const test_ctx: Context = .{
        .io = undefined,
        .server_allocator = std.testing.allocator,
        .request_allocator = arena.allocator(),
        .request = &http_req,
    };

    const query = Query("name").fromContext(test_ctx);
    try std.testing.expectEqual(null, query.value);
}

test "init decodes double-encoded query value only once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const req_bytes = std.fmt.comptimePrint("GET /person?name=hello%2520world HTTP/1.1\r\n" ++ "\r\n", .{});
    var stream_buf_reader = std.Io.Reader.fixed(req_bytes);

    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = std.Io.Writer.fixed(&write_buffer);

    var http_server = std.http.Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    const test_ctx: Context = .{
        .io = undefined,
        .server_allocator = std.testing.allocator,
        .request_allocator = arena.allocator(),
        .request = &http_req,
    };

    const query = Query("name").fromContext(test_ctx);
    try std.testing.expect(query.value != null);
    try std.testing.expectEqualStrings("hello%20world", query.value.?);
}

