//! JSON extractor for automatic request body deserialization.
//!
//! This module provides automatic JSON parsing from HTTP request bodies through
//! the router's parameter injection system. When a handler parameter is detected
//! as a Json(T) type, the library automatically parses the request body as JSON
//! and provides the deserialized data to the handler.

const std = @import("std");
const Request = std.http.Server.Request;
const StructField = std.builtin.Type.StructField;
const Context = @import("../http/context.zig").Context;

/// Extracts and parses JSON from an HTTP request body.
///
/// This function reads the request body, parses it as JSON, and converts
/// it to the target type T. String fields are automatically duplicated
/// to ensure they remain valid beyond the request.
///
/// Parameters:
/// - `T`: The target type to deserialize into
/// - `allocator`: Allocator for parsed data and string duplication
/// - `req`: HTTP request containing the JSON body
///
/// Returns: Json extractor with parsed value or error
///
/// Errors:
/// - `RequestBodyMissing`: Request method doesn't support a body
/// - `ContentTypeMissing`: `Content-Type` header is missing
/// - `InvalidContentType`: `Content-Type` is not `application/json`
/// - `ContentLengthMissing`: `Content-Length` header is missing
/// - `EmptyRequestBody`: `Content-Length` is zero
/// - `InvalidJson`: Request body is not valid JSON
/// - `OutOfMemory`: Allocation failed
/// - I/O errors while reading the request body
/// - JSON decoding errors from `std.json.parseFromSlice`
fn initJson(comptime T: type, allocator: std.mem.Allocator, req: *Request) Json(T) {
    if (!req.head.method.requestHasBody()) {
        return .{ .value = error.RequestBodyMissing };
    }

    if (req.head.content_type) |content_type| {
        if (!std.mem.eql(u8, content_type, "application/json")) {
            return .{ .value = error.InvalidContentType };
        }
    } else return .{ .value = error.ContentTypeMissing };

    if (req.head.content_length) |content_length| {
        if (content_length == 0) {
            return .{ .value = error.EmptyRequestBody };
        }
    } else return .{ .value = error.ContentLengthMissing };

    const data = allocator.alloc(u8, req.head.content_length.?) catch |err|
        return .{ .value = err };
    defer allocator.free(data);

    const reader = req.server.reader.bodyReader(
        data,
        req.head.transfer_encoding,
        req.head.content_length,
    );
    reader.readSliceAll(data) catch |err| return .{ .value = err };
    const isValidJson = std.json.validate(allocator, data) catch |err| return .{ .value = err };
    if (!isValidJson) {
        return .{ .value = error.InvalidJson };
    }

    const parsed = std.json.parseFromSlice(T, allocator, data, .{}) catch |err| return .{ .value = err };
    defer parsed.deinit();

    const value = allocator.create(T) catch |err| return .{ .value = err };
    errdefer allocator.destroy(value);

    value.* = parsed.value;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (field.type == []const u8) {
            const original_slice = @field(parsed.value, field.name);
            @field(value.*, field.name) = allocator.dupe(u8, original_slice) catch |err| return .{ .value = err };
        }
    }

    return .{ .value = value };
}

/// Creates a JSON extractor type for automatic deserialization.
///
/// This generic type provides automatic JSON parsing from HTTP request bodies.
/// The extractor handles reading the request body, parsing JSON, and managing
/// memory for string fields that need to be duplicated.
///
/// Parameters:
/// - `T`: The target type to deserialize JSON into
///
/// Returns: A Json extractor type that can parse T from request bodies
///
/// Example usage in a router handler:
/// ```zig
/// const Person = struct {
///     name: []const u8,
///     age: u32,
/// };
///
/// fn createPerson(ctx: Context, state: *MyState, person: Json(Person)) !Response {
///     const p = try person.value; // Access the parsed Person
///     defer person.deinit(ctx.request_allocator); // Clean up when done
///     // Use p...
///     return Response.json(ctx.request_allocator, .created, "{\"id\": 123}", null);
/// }
/// ```
pub fn Json(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Compile-time marker used to identify Json extractor types.
        pub const VOLT_JSON_EXTRACTOR = true;

        /// The extracted value or an error
        value: anyerror!*T,

        /// Tracks whether this instance owns the extracted data.
        /// Cache hits are non-owning and should not call destroy().
        owns_data: bool = true,

        /// Cleans up resources allocated during JSON extraction.
        ///
        /// This method is only effective if this instance owns the data (not a cache hit).
        /// Cache hit instances have no-op deinit to prevent double-free.
        ///
        /// Parameters:
        /// - `allocator`: The same allocator used for extraction
        ///
        /// This should be called when the extracted JSON data is no longer needed.
        /// If extraction failed (value is an error), this is a no-op.
        pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
            if (!self.owns_data) return; // Cache hit: no-op deinit

            const value = self.value catch return;
            inline for (@typeInfo(T).@"struct".fields) |field| {
                if (field.type == []const u8) {
                    allocator.free(@field(value.*, field.name));
                }
            }

            allocator.destroy(value);
        }

        /// Extracts and parses JSON from request context.
        ///
        /// When a request context is available, use this method for manual extraction.
        /// The context provides access to the request and per-request caching;
        /// repeated extractions during the same request reuse the parsed result.
        ///
        /// Ownership semantics:
        /// - With request cache enabled, all extracted instances are non-owning.
        ///   Data is request-scoped and remains stable for the request lifetime.
        /// - Without request cache, the instance owns extracted data and should call deinit().
        ///
        /// Parameters:
        /// - `ctx`: Request context (any type with request and request_allocator fields).
        ///   Use `ctx.io` for any I/O operations required within the surrounding handler.
        ///
        /// Returns: Json extractor with parsed value or error
        ///
        /// Example usage in a handler body:
        /// ```zig
        /// fn myHandler(ctx: Context, state: *MyState) !Response {
        ///     const body = Json(MyType).fromContext(ctx);
        ///     const data = try body.value;
        ///     defer body.deinit(ctx.request_allocator);
        ///     // Use data...
        /// }
        /// ```
        pub fn fromContext(ctx: Context) Self {
            const key = "json:" ++ @typeName(T);
            if (ctx._cache) |cache| {
                if (cache.get(key)) |cached| {
                    // Cache hit: return non-owning instance
                    return .{
                        .value = @as(*T, @ptrCast(@alignCast(cached))),
                        .owns_data = false,
                    };
                }
            }

            var self = initJson(T, ctx.request_allocator, ctx.request);

            // When request cache is enabled, extracted values are request-scoped and
            // should not be individually freed by extractor instances.
            if (ctx._cache) |cache| {
                self.owns_data = false;
                if (self.value) |val| {
                    cache.put(key, val) catch {};
                } else |_| {}
            } else {
                self.owns_data = true;
            }

            return self;
        }
    };
}

/// Resolver for JSON extractors in the compile-time registry.
///
/// This struct implements the resolver interface (`matches` and `resolve`) to enable
/// automatic detection and instantiation of Json extractor types during parameter resolution.
pub const Resolver = struct {
    fn Extracted(comptime T: type) type {
        if (!Resolver.matches(T)) {
            @compileError("expected Json extractor type");
        }

        inline for (@typeInfo(T).@"struct".fields) |field| {
            if (std.mem.eql(u8, field.name, "value")) {
                return @typeInfo(@typeInfo(field.type).error_union.payload).pointer.child;
            }
        }
    }

    pub fn matches(comptime T: type) bool {
        return @typeInfo(T) == .@"struct" and
            @hasDecl(T, "VOLT_JSON_EXTRACTOR") and
            @field(T, "VOLT_JSON_EXTRACTOR");
    }

    pub fn resolve(comptime T: type, allocator: std.mem.Allocator, req: *Request) T {
        const resolved_type = Extracted(T);
        return initJson(resolved_type, allocator, req);
    }

    pub fn resolveWithContext(comptime T: type, ctx: Context) T {
        const resolved_type = Extracted(T);
        return Json(resolved_type).fromContext(ctx);
    }
};

test "extract returns Json when request is valid" {
    const allocator = std.testing.allocator;

    const Person = struct {
        name: []const u8,
        age: u7,
    };
    const body = "{\"name\":\"Ziggy\",\"age\":15}";

    const req_bytes = std.fmt.comptimePrint("POST /person HTTP/1.1\r\n" ++
        "Content-Type: application/json\r\n" ++
        "Content-Length: {d}\r\n" ++
        "\r\n" ++
        "{s}", .{ body.len, body });

    var stream_buf_reader = std.Io.Reader.fixed(req_bytes);

    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = std.Io.Writer.fixed(&write_buffer);

    var http_server = std.http.Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    const test_ctx: Context = .{
        .io = undefined,
        .server_allocator = std.testing.allocator,
        .request = &http_req,
        .request_allocator = allocator,
        ._cache = null,
    };

    const json = Json(Person).fromContext(test_ctx);
    defer json.deinit(allocator);

    const person = try json.value;
    try std.testing.expectEqual(@as(u7, 15), person.age);
    try std.testing.expectEqualStrings("Ziggy", person.name);
}

test "extract fails when content type is missing" {
    const allocator = std.testing.allocator;

    const Person = struct {
        name: []const u8,
        age: u7,
    };
    const body = "{\"name\":\"Ziggy\",\"age\":15}";

    const req_bytes = std.fmt.comptimePrint("POST /person HTTP/1.1\r\n" ++
        "Content-Length: {d}\r\n" ++
        "\r\n" ++
        "{s}", .{ body.len, body });

    var stream_buf_reader = std.Io.Reader.fixed(req_bytes);

    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = std.Io.Writer.fixed(&write_buffer);

    var http_server = std.http.Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    const test_ctx: Context = .{
        .io = undefined,
        .server_allocator = std.testing.allocator,
        .request = &http_req,
        .request_allocator = allocator,
        ._cache = null,
    };

    const json = Json(Person).fromContext(test_ctx);
    defer json.deinit(allocator);

    const result = json.value;
    try std.testing.expectError(error.ContentTypeMissing, result);
}

test "extract fails when content type is not application/json" {
    const allocator = std.testing.allocator;

    const Person = struct {
        name: []const u8,
        age: u7,
    };
    const body = "{\"name\":\"Ziggy\",\"age\":15}";

    const req_bytes = std.fmt.comptimePrint("POST /person HTTP/1.1\r\n" ++
        "Content-Length: {d}\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "\r\n" ++
        "{s}", .{ body.len, body });

    var stream_buf_reader = std.Io.Reader.fixed(req_bytes);

    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = std.Io.Writer.fixed(&write_buffer);

    var http_server = std.http.Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    const test_ctx: Context = .{
        .io = undefined,
        .server_allocator = std.testing.allocator,
        .request = &http_req,
        .request_allocator = allocator,
        ._cache = null,
    };

    const json = Json(Person).fromContext(test_ctx);
    defer json.deinit(allocator);

    const result = json.value;
    try std.testing.expectError(error.InvalidContentType, result);
}

test "extract fails when content length is missing" {
    const allocator = std.testing.allocator;

    const Person = struct {
        name: []const u8,
        age: u7,
    };
    const body = "{\"name\":\"Ziggy\",\"age\":15}";

    const req_bytes = std.fmt.comptimePrint("POST /person HTTP/1.1\r\n" ++
        "Content-Type: application/json\r\n" ++
        "\r\n" ++
        "{s}", .{body});

    var stream_buf_reader = std.Io.Reader.fixed(req_bytes);

    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = std.Io.Writer.fixed(&write_buffer);

    var http_server = std.http.Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    const test_ctx: Context = .{
        .io = undefined,
        .server_allocator = std.testing.allocator,
        .request = &http_req,
        .request_allocator = allocator,
        ._cache = null,
    };

    const json = Json(Person).fromContext(test_ctx);
    defer json.deinit(allocator);

    const result = json.value;
    try std.testing.expectError(error.ContentLengthMissing, result);
}

test "extract fails when content length is zero" {
    const allocator = std.testing.allocator;

    const Person = struct {
        name: []const u8,
        age: u7,
    };

    const req_bytes = std.fmt.comptimePrint("POST /person HTTP/1.1\r\n" ++
        "Content-Length: {d}\r\n" ++
        "Content-Type: application/json\r\n" ++
        "\r\n", .{0});

    var stream_buf_reader = std.Io.Reader.fixed(req_bytes);

    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = std.Io.Writer.fixed(&write_buffer);

    var http_server = std.http.Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    const test_ctx: Context = .{
        .io = undefined,
        .server_allocator = std.testing.allocator,
        .request = &http_req,
        .request_allocator = allocator,
        ._cache = null,
    };

    const json = Json(Person).fromContext(test_ctx);
    defer json.deinit(allocator);

    const result = json.value;
    try std.testing.expectError(error.EmptyRequestBody, result);
}

test "matches returns true for Json extractor" {
    const Person = struct {
        name: []const u8,
        age: u7,
    };

    try std.testing.expect(comptime Resolver.matches(Json(Person)));
}

test "Extracted returns payload type for Json extractor" {
    const Person = struct {
        name: []const u8,
        age: u7,
    };

    try std.testing.expect(comptime Resolver.Extracted(Json(Person)) == Person);
}

test "matches returns false for non-Json extractor" {
    const Person = struct {
        name: []const u8,
        age: u7,
    };

    try std.testing.expect(!comptime Resolver.matches(Person));
}

test "fromContext keeps cached json stable after deinit" {
    const Person = struct {
        name: []const u8,
        age: u7,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var cache = @import("../http/context.zig").Cache.init(std.testing.allocator);
    defer cache.deinit();

    const body = "{\"name\":\"Ziggy\",\"age\":15}";
    const req_bytes = std.fmt.comptimePrint("POST /person HTTP/1.1\r\n" ++
        "Content-Type: application/json\r\n" ++
        "Content-Length: {d}\r\n" ++
        "\r\n" ++
        "{s}", .{ body.len, body });

    var stream_buf_reader = std.Io.Reader.fixed(req_bytes);

    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = std.Io.Writer.fixed(&write_buffer);

    var http_server = std.http.Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    const test_ctx: Context = .{
        .io = undefined,
        .server_allocator = std.testing.allocator,
        .request = &http_req,
        .request_allocator = arena.allocator(),
        ._cache = &cache,
    };

    const first = Json(Person).fromContext(test_ctx);
    try std.testing.expect(!first.owns_data);

    // Should be a no-op for cached instances.
    first.deinit(arena.allocator());

    const second = Json(Person).fromContext(test_ctx);
    defer second.deinit(arena.allocator());
    try std.testing.expect(!second.owns_data);

    const person = try second.value;
    try std.testing.expectEqualStrings("Ziggy", person.name);
    try std.testing.expectEqual(@as(u7, 15), person.age);
}
