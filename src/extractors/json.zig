const Request = @import("../request.zig").Request;
const std = @import("std");

pub fn Json(comptime T: type) type {
    return struct {
        value: *T,
    };
}

pub fn isJsonParameter(comptime T: type) bool {
    const t = @typeInfo(T);
    _ = std.mem.find(u8, @typeName(T), "Json(") orelse return false;
    return t == .@"struct" and @hasField(T, "value");
}

pub fn getJsonParameter(comptime T: type) type {
    for (@typeInfo(T).@"struct".fields) |field| {
        if (std.mem.eql(u8, field.name, "value")) {
            return @typeInfo(field.type).pointer.child;
        }
    }

    @compileError("No 'value' field found in Json struct");
}

pub fn extractJson(comptime T: type, req: *const Request) !Json(T) {
    if (!req.http_req.head.method.requestHasBody()) {
        return error.RequestBodyMissing;
    }

    const data = try req.allocator.alloc(u8, req.http_req.head.content_length.?);
    defer req.allocator.free(data);

    const reader = req.http_req.server.reader.bodyReader(
        data,
        req.http_req.head.transfer_encoding,
        req.http_req.head.content_length,
    );

    try reader.readSliceAll(data);
    const parsed = try std.json.parseFromSlice(T, req.allocator, data, .{});
    defer parsed.deinit();

    const v = try req.allocator.create(T);
    errdefer req.allocator.destroy(v);

    v.* = parsed.value;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (field.type == []const u8) {
            const original_slice = @field(parsed.value, field.name);
            @field(v.*, field.name) = try req.allocator.dupe(u8, original_slice);
        }
    }

    return .{
        .value = v,
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
    const req: Request = .{
        .allocator = allocator,
        .http_req = &http_req,
    };

    const json = try extractJson(Person, &req);
    defer json.deinit();

    const person = json.value;
    try std.testing.expectEqual(@as(u7, 15), person.age);
    try std.testing.expectEqualStrings("Ziggy", person.name);
}
