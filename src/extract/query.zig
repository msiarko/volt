//! Query parameter extractor for the Volt web library.
//!
//! This module provides a lightweight extractor for URL query parameters through
//! the router's parameter injection system. When a handler parameter is typed as
//! `Query("name")`, the library automatically resolves that parameter from the
//! request target query string.

const std = @import("std");
const utils = @import("utils.zig");
const Request = std.http.Server.Request;

const Context = @import("../http/context.zig").Context;

/// Extracts the configured query parameter from the request target.
///
/// This function parses the portion of the request URL after `?`, splits
/// pairs by `&`, and returns the decoded value for the configured key.
///
/// When the raw value contains percent-encoded sequences or `+` characters,
/// a decoded copy is allocated using `allocator`. When no decoding is needed
/// the returned slice points directly into the request target with no allocation.
/// Malformed percent-encoding (e.g. a truncated sequence) returns `error.InvalidPercentEncoding`.
fn initQuery(comptime name: []const u8, allocator: std.mem.Allocator, req: *Request) Query(name) {
    var query_it = utils.queryIterator(req.head.target) orelse return .{ .value = null };
    while (query_it.next()) |entry| {
        if (utils.queryComponentEqualsAsciiIgnoreCaseDecoded(entry.key, name)) {
            const raw = entry.value orelse return .{ .value = null };
            const decoded = utils.decodeQueryComponent(allocator, raw) catch |err| return .{ .value = err };
            return .{ .value = decoded, ._owns_value = decoded.ptr != raw.ptr };
        }
    }

    return .{ .value = null };
}

/// Creates a Query extractor type for a specific query parameter key.
///
/// The `value` field is `anyerror!?[]const u8` with three possible states:
/// - `null` when the parameter is missing or has an empty value
/// - `error.InvalidPercentEncoding` when the value contains malformed percent-encoding
/// - `[]const u8` slice when the parameter exists with a valid, non-empty value
///
/// Key matching supports encoded keys (for example `first%20name` matches
/// `Query("first name")`).
///
/// Returned values are URL-decoded (percent-encoding and `+` → space). When
/// the raw value does not contain any encoded sequences the slice borrows
/// directly from the request target; otherwise a decoded copy is allocated
/// from the request arena and freed automatically at the end of the request.
pub fn Query(comptime name: []const u8) type {
    return struct {
        const Self = @This();

        /// Compile-time marker used to identify Query extractor types.
        pub const VOLT_QUERY_EXTRACTOR = true;
        /// Compile-time query parameter name this extractor resolves.
        pub const param_name: []const u8 = name;

        /// Extracted query value for `name`.
        ///
        /// States:
        /// - `null` — parameter absent or empty
        /// - `error.InvalidPercentEncoding` — value contained malformed percent-encoding
        /// - `[]const u8` — successfully decoded value
        value: anyerror!?[]const u8,
        /// Whether `value` was heap-allocated during URL decoding.
        ///
        /// True only when the raw query value contained percent-encoded sequences
        /// or `+` characters and a decoded copy was allocated. False when the value
        /// borrows directly from the request target.
        _owns_value: bool = false,

        /// Releases the decoded value when an allocation was made during extraction.
        ///
        /// Must be called with the same allocator passed to `fromContext` or `resolve`.
        /// Under a request-scoped arena allocator this is optional because the arena
        /// frees all allocations at the end of the request.
        pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
            if (self._owns_value) {
                if (self.value) |maybe_v| {
                    if (maybe_v) |v| allocator.free(v);
                } else |_| {}
            }
        }

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
        ///     if (try q.value) |search_term| {
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

    return T.param_name;
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

    const value = try query.value;
    try std.testing.expect(value != null);
    try std.testing.expectEqualStrings("Ziggy", value.?);
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

    const value = try query.value;
    try std.testing.expect(value != null);
    try std.testing.expectEqualStrings("30", value.?);
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

    try std.testing.expectEqual(null, try query.value);
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

    try std.testing.expectEqual(null, try query.value);
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

    try std.testing.expectEqual(null, try query.value);
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
        const value = try query.value;
        if (case.expected) |expected| {
            try std.testing.expectEqualStrings(expected, value.?);
        } else {
            try std.testing.expect(value == null);
        }
    }
}

test "init matches encoded query keys and decodes value" {
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

    const value = try query.value;
    try std.testing.expect(value != null);
    try std.testing.expectEqualStrings("Zig Lang", value.?);
}

test "init returns error for malformed percent encoding" {
    const req_bytes = std.fmt.comptimePrint("GET /person?name=Zig%2 HTTP/1.1\r\n" ++ "\r\n", .{});
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
    try std.testing.expectError(error.InvalidPercentEncoding, query.value);
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
    const value = try query.value;
    try std.testing.expect(value != null);
    try std.testing.expectEqualStrings("hello%20world", value.?);
}

test "deinit frees allocation when value was encoded" {
    // Use the leak-detecting allocator directly so the test fails if deinit is not called.
    const req_bytes = std.fmt.comptimePrint("GET /search?q=hello+world HTTP/1.1\r\n" ++ "\r\n", .{});
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
    const query = Query("q").fromContext(test_ctx);

    try std.testing.expect(query._owns_value);
    try std.testing.expectEqualStrings("hello world", (try query.value).?);
    query.deinit(std.testing.allocator);
}

test "deinit is a no-op when value is not encoded" {
    const req_bytes = std.fmt.comptimePrint("GET /search?q=hello HTTP/1.1\r\n" ++ "\r\n", .{});
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
    const query = Query("q").fromContext(test_ctx);

    try std.testing.expect(!query._owns_value);
    try std.testing.expectEqualStrings("hello", (try query.value).?);
    query.deinit(std.testing.allocator); // safe to call — no allocation to free
}
