const std = @import("std");
const Request = std.http.Server.Request;
const StructField = std.builtin.Type.StructField;
const utils = @import("utils.zig");

const JSON_EXTRACTOR_KEY: []const u8 = "JSON_EXTRACTOR";

pub fn matches(comptime T: type) bool {
    return utils.matches(T, JSON_EXTRACTOR_KEY);
}

pub fn getExtractedType(comptime T: type) type {
    for (@typeInfo(T).@"struct".fields) |field| {
        if (std.mem.eql(u8, field.name, "value")) {
            return @typeInfo(@typeInfo(field.type).error_union.payload).pointer.child;
        }
    }

    @compileError("No 'value' field found in Json struct");
}

pub fn Json(comptime T: type) type {
    return struct {
        const Self = @This();

        key: []const u8 = JSON_EXTRACTOR_KEY,
        value: anyerror!*T,

        pub fn extract(allocator: std.mem.Allocator, req: *Request) Self {
            if (!req.head.method.requestHasBody()) {
                return .{ .value = error.RequestBodyMissing };
            }

            const data = allocator.alloc(u8, req.head.content_length.?) catch |err|
                return .{ .value = err };
            defer allocator.free(data);

            const reader = req.server.reader.bodyReader(
                data,
                req.head.transfer_encoding,
                req.head.content_length,
            );
            reader.readSliceAll(data) catch |err| return .{ .value = err };
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

            return .{
                .value = value,
            };
        }

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

test "extract Json" {
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

    const json = Json(Person).extract(allocator, &http_req);
    defer json.deinit(allocator);

    const person = try json.value;
    try std.testing.expectEqual(@as(u7, 15), person.age);
    try std.testing.expectEqualStrings("Ziggy", person.name);
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
