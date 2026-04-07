//! JSON extractor for automatic request body deserialization.
//!
//! This module provides automatic JSON parsing from HTTP request bodies through
//! the router's parameter injection system. When a handler parameter is detected
//! as a Json(T) type, the library automatically parses the request body as JSON
//! and provides the deserialized data to the handler.

const std = @import("std");
const Request = std.http.Server.Request;
const StructField = std.builtin.Type.StructField;
const utils = @import("utils.zig");

/// Key used to identify JSON extractor types at compile time.
const JSON_EXTRACTOR_KEY: []const u8 = "JSON_EXTRACTOR";

/// Checks if a type is a JSON extractor by examining its structure.
///
/// This function uses compile-time reflection to determine if the given type
/// has a field named "key" with the default value "JSON_EXTRACTOR".
///
/// Parameters:
/// - `T`: The type to check
///
/// Returns: true if T is a JSON extractor type, false otherwise
///
/// This is used by the router to automatically detect JSON parameters
/// in handler function signatures.
pub fn matches(comptime T: type) bool {
    return utils.matches(T, JSON_EXTRACTOR_KEY);
}

/// Extracts the payload type from a Json extractor type.
///
/// This function performs compile-time reflection to locate the `value` field
/// on the extractor and unwraps its type shape (`anyerror!*U`) to return `U`.
///
/// Before unwrapping, it validates that `T` matches the Json extractor marker
/// via `matches(T)`. If not, compilation fails.
///
/// Parameters:
/// - `T`: A Json(U) extractor type (must define a `value` field)
///
/// Returns: The extracted payload type `U`
///
/// Compile errors:
/// - `Type is not a Json extractor`: Triggered when `matches(T)` is false
///
/// Example:
/// ```zig
/// const Person = struct { name: []const u8, age: u32 };
/// const ExtractedType = Extracted(Json(Person)); // Person
/// ```
pub fn Extracted(comptime T: type) type {
    if (!matches(T)) {
        @compileError("Type is not a Json extractor");
    }

    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (std.mem.eql(u8, field.name, "value")) {
            return @typeInfo(@typeInfo(field.type).error_union.payload).pointer.child;
        }
    }
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

        /// Extractor key for type identification
        key: []const u8 = JSON_EXTRACTOR_KEY,
        /// The extracted value or an error
        value: anyerror!*T,

        /// Extracts and parses JSON from an HTTP request body.
        ///
        /// This method reads the request body, parses it as JSON, and converts
        /// it to the target type T. String fields are automatically duplicated
        /// to ensure they remain valid beyond the request.
        ///
        /// Parameters:
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
        ///
        /// The returned value should be checked for errors and deinit() should
        /// be called when the extracted data is no longer needed.
        pub fn init(allocator: std.mem.Allocator, req: *Request) Self {
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

        /// Cleans up resources allocated during JSON extraction.
        ///
        /// This method frees all memory allocated for the parsed JSON data,
        /// including duplicated strings and the main data structure.
        ///
        /// Parameters:
        /// - `allocator`: The same allocator used for extraction
        ///
        /// This should be called when the extracted JSON data is no longer needed.
        /// If extraction failed (value is an error), this is a no-op.
        pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
            const value = self.value catch return;
            inline for (@typeInfo(T).@"struct".fields) |field| {
                if (field.type == []const u8) {
                    allocator.free(@field(value.*, field.name));
                }
            }

            allocator.destroy(value);
        }
    };
}

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

    const json = Json(Person).init(allocator, &http_req);
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

    const json = Json(Person).init(allocator, &http_req);
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

    const json = Json(Person).init(allocator, &http_req);
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

    const json = Json(Person).init(allocator, &http_req);
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

    const json = Json(Person).init(allocator, &http_req);
    defer json.deinit(allocator);

    const result = json.value;
    try std.testing.expectError(error.EmptyRequestBody, result);
}

test "matches returns true for Json extractor" {
    const Person = struct {
        name: []const u8,
        age: u7,
    };

    try std.testing.expect(comptime matches(Json(Person)));
}

test "matches returns false for non-Json extractor" {
    const Person = struct {
        name: []const u8,
        age: u7,
    };

    try std.testing.expect(!comptime matches(Person));
}
