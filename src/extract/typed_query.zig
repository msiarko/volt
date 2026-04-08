//! Typed query extractor for structured URL query parsing.
//!
//! This module provides a struct-based query extractor that maps query
//! parameters to fields on a user-defined type. It is designed for handlers
//! that need multiple query parameters grouped into one typed value.

const std = @import("std");
const utils = @import("utils.zig");
const Context = @import("../http/context.zig").Context;

/// Parses request query parameters into a typed struct.
///
/// Behavior:
/// - Returns `.value = null` when no query string exists
/// - Returns `.value = null` when all matched values are empty or absent
/// - Returns `.value = typed_ptr` when at least one non-empty field matched
/// - Returns `.value = err` on allocation failures
///
/// Compile errors:
/// - `Type is not a struct`: `T` is not a struct type
/// - `<field> field must be of type ?[]const u8`: invalid field type in `T`
fn initTypedQuery(comptime T: type, arena: std.mem.Allocator, req: *std.http.Server.Request) TypedQuery(T) {
    const type_info = @typeInfo(T);
    if (type_info != .@"struct") {
        @compileError("Type is not a struct");
    }

    const fields = type_info.@"struct".fields;
    comptime {
        for (fields) |field| {
            if (field.type != ?[]const u8) {
                @compileError(field.name ++ " field must be of type ?[]const u8");
            }
        }
    }

    var query_it = utils.queryIterator(req.head.target) orelse return .{ .value = null };
    const typed_query = arena.create(T) catch |err| return .{ .value = err };
    inline for (fields) |field| {
        @field(typed_query.*, field.name) = null;
    }

    var value_set = false;
    while (query_it.next()) |entry| {
        inline for (fields) |field| {
            if (std.ascii.eqlIgnoreCase(entry.key, field.name)) {
                if (entry.value) |value| {
                    value_set = true;
                    @field(typed_query.*, field.name) = value;
                }
            }
        }
    }

    if (!value_set) {
        arena.destroy(typed_query);
        return .{ .value = null };
    }

    return .{ .value = typed_query };
}

/// Creates a TypedQuery extractor type for structured query parsing.
///
/// The payload type `T` must be a struct where every field is `?[]const u8`.
/// Each field name is used as a query key. Missing or empty keys remain null.
pub fn TypedQuery(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Compile-time marker used to identify TypedQuery extractor types.
        pub const VOLT_TYPED_QUERY_EXTRACTOR = true;

        /// Parsed query object, null when no non-empty keys were matched.
        value: anyerror!?*T,

        /// Releases typed query storage.
        ///
        /// Parameters:
        /// - `self`: TypedQuery extractor instance
        /// - `arena`: The allocator used for extraction
        ///
        /// This method is a no-op when extraction resulted in `null` or an error.
        /// Call this once the extracted query object is no longer needed.
        pub fn deinit(self: *Self, arena: std.mem.Allocator) void {
            const val = self.value catch return;
            if (val) |v| {
                arena.destroy(v);
            }
        }

        /// Extracts and parses query from request context.
        ///
        /// When a request context is available, use this method for manual extraction.
        /// The context provides access to the request and per-request caching;
        /// repeated extractions during the same request reuse the parsed result.
        ///
        /// Parameters:
        /// - `ctx`: Request context (any type with request and request_allocator fields).
        ///   Use `ctx.io` for any I/O operations required within the surrounding handler.
        ///
        /// Returns: TypedQuery extractor with parsed value or null
        ///
        /// Example usage in a handler body:
        /// ```zig
        /// fn search(ctx: Context, state: *MyState) !Response {
        ///     var query = TypedQuery(SearchParams).fromContext(ctx);
        ///     defer query.deinit(ctx.request_allocator);
        ///     if (try query.value) |params| {
        ///         // Use params...
        ///     }
        /// }
        /// ```
        pub fn fromContext(ctx: Context) Self {
            const key = "typed_query:" ++ @typeName(T);
            if (ctx._cache) |cache| {
                if (cache.get(key)) |cached| {
                    return .{ .value = @as(*T, @ptrCast(@alignCast(cached))) };
                }
            }
            const self = initTypedQuery(T, ctx.request_allocator, ctx.request);
            if (ctx._cache) |cache| {
                if (self.value) |val| {
                    if (val) |v| {
                        cache.put(key, v) catch {};
                    }
                } else |_| {}
            }
            return self;
        }
    };
}

/// Extracts the payload type from a TypedQuery extractor type.
///
/// This function locates the `value` field and unwraps the nested type shape
/// (`anyerror!?*U`) to return `U`.
///
/// Compile errors:
/// - `expected TypedQuery extractor type`: Triggered when the type doesn't match
fn Extracted(comptime T: type) type {
    if (!Resolver.matches(T)) {
        @compileError("expected TypedQuery extractor type");
    }

    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (std.mem.eql(u8, field.name, "value")) {
            return @typeInfo(@typeInfo(@typeInfo(field.type).error_union.payload).optional.child).pointer.child;
        }
    }
}

/// Resolver for TypedQuery extractors in the compile-time registry.
///
/// This struct implements the resolver interface (`matches` and `resolve`) to enable
/// automatic detection and instantiation of TypedQuery extractor types during parameter resolution.
pub const Resolver = struct {
    pub fn matches(comptime T: type) bool {
        return @typeInfo(T) == .@"struct" and
            @hasDecl(T, "VOLT_TYPED_QUERY_EXTRACTOR") and
            @field(T, "VOLT_TYPED_QUERY_EXTRACTOR");
    }

    pub fn resolve(comptime T: type, allocator: std.mem.Allocator, req: *std.http.Server.Request) T {
        const ExtractedType = Extracted(T);
        return initTypedQuery(ExtractedType, allocator, req);
    }

    pub fn resolveWithContext(comptime T: type, ctx: Context) T {
        const ExtractedType = Extracted(T);
        return TypedQuery(ExtractedType).fromContext(ctx);
    }
};

test "Resolver.matches returns true for TypedQuery extractor" {
    const Filters = struct {
        name: ?[]const u8,
        age: ?[]const u8,
    };

    try std.testing.expect(comptime Resolver.matches(TypedQuery(Filters)));
}

test "Resolver.matches returns false for non-TypedQuery extractor" {
    const Person = struct {
        name: []const u8,
        age: u8,
    };

    try std.testing.expect(!comptime Resolver.matches(Person));
}

test "Extracted returns payload type for TypedQuery extractor" {
    const Filters = struct {
        name: ?[]const u8,
        age: ?[]const u8,
    };

    try std.testing.expect(comptime Extracted(TypedQuery(Filters)) == Filters);
}

test "init returns TypedQuery with values when matching parameters are present" {
    const Filters = struct {
        name: ?[]const u8,
        age: ?[]const u8,
    };

    const allocator = std.testing.allocator;
    const req_bytes = std.fmt.comptimePrint("GET /users?name=Ziggy&age=30 HTTP/1.1\r\n" ++ "\r\n", .{});
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

    var typed_query = TypedQuery(Filters).fromContext(test_ctx);
    defer typed_query.deinit(allocator);

    const filters = (try typed_query.value) orelse unreachable;
    try std.testing.expectEqualStrings("Ziggy", filters.name.?);
    try std.testing.expectEqualStrings("30", filters.age.?);
}

test "init returns TypedQuery with partial values when some parameters are missing" {
    const Filters = struct {
        name: ?[]const u8,
        age: ?[]const u8,
    };

    const allocator = std.testing.allocator;
    const req_bytes = std.fmt.comptimePrint("GET /users?name=Ziggy HTTP/1.1\r\n" ++ "\r\n", .{});
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

    var typed_query = TypedQuery(Filters).fromContext(test_ctx);
    defer typed_query.deinit(allocator);

    const filters = (try typed_query.value) orelse unreachable;
    try std.testing.expectEqualStrings("Ziggy", filters.name.?);
    try std.testing.expectEqual(null, filters.age);
}

test "init returns null when query string is missing" {
    const Filters = struct {
        name: ?[]const u8,
        age: ?[]const u8,
    };

    const allocator = std.testing.allocator;
    const req_bytes = std.fmt.comptimePrint("GET /users HTTP/1.1\r\n" ++ "\r\n", .{});
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

    var typed_query = TypedQuery(Filters).fromContext(test_ctx);
    defer typed_query.deinit(allocator);

    try std.testing.expectEqual(null, try typed_query.value);
}

test "init returns null when query string is empty" {
    const Filters = struct {
        name: ?[]const u8,
        age: ?[]const u8,
    };

    const allocator = std.testing.allocator;
    const req_bytes = std.fmt.comptimePrint("GET /users? HTTP/1.1\r\n" ++ "\r\n", .{});
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

    var typed_query = TypedQuery(Filters).fromContext(test_ctx);
    defer typed_query.deinit(allocator);

    try std.testing.expectEqual(null, try typed_query.value);
}

test "init returns null when all matching parameters are empty" {
    const Filters = struct {
        name: ?[]const u8,
        age: ?[]const u8,
    };

    const allocator = std.testing.allocator;
    const req_bytes = std.fmt.comptimePrint("GET /users?name=&age= HTTP/1.1\r\n" ++ "\r\n", .{});
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

    var typed_query = TypedQuery(Filters).fromContext(test_ctx);
    defer typed_query.deinit(allocator);

    try std.testing.expectEqual(null, try typed_query.value);
}

test "init table-driven typed query extraction" {
    const Filters = struct {
        name: ?[]const u8,
        age: ?[]const u8,
    };

    const cases = [_]struct {
        target: []const u8,
        expected_name: ?[]const u8,
        expected_age: ?[]const u8,
        has_value: bool,
    }{
        .{ .target = "/users?name=Ziggy&age=30", .expected_name = "Ziggy", .expected_age = "30", .has_value = true },
        .{ .target = "/users?name=Ziggy", .expected_name = "Ziggy", .expected_age = null, .has_value = true },
        .{ .target = "/users?name=&age=", .expected_name = null, .expected_age = null, .has_value = false },
        .{ .target = "/users", .expected_name = null, .expected_age = null, .has_value = false },
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
            .request = &http_req,
            .request_allocator = std.testing.allocator,
            ._cache = null,
        };

        var typed_query = TypedQuery(Filters).fromContext(test_ctx);
        defer typed_query.deinit(std.testing.allocator);

        if (case.has_value) {
            const filters = (try typed_query.value) orelse unreachable;
            if (case.expected_name) |expected_name| {
                try std.testing.expect(filters.name != null);
                try std.testing.expectEqualStrings(expected_name, filters.name.?);
            } else {
                try std.testing.expectEqual(null, filters.name);
            }

            if (case.expected_age) |expected_age| {
                try std.testing.expect(filters.age != null);
                try std.testing.expectEqualStrings(expected_age, filters.age.?);
            } else {
                try std.testing.expectEqual(null, filters.age);
            }
        } else {
            try std.testing.expectEqual(null, try typed_query.value);
        }
    }
}
