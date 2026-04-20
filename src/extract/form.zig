const std = @import("std");
const Context = @import("../http/context.zig").Context;
const utils = @import("utils.zig");
const Request = std.http.Server.Request;

const EXTRACTOR_ID: []const u8 = "VOLT_FORM_EXTRACTOR";
const CONTENT_DISPOSITION: []const u8 = "Content-Disposition: form-data; name=\"";

fn extract(comptime T: type, arena: std.mem.Allocator, req: *Request) !*T {
    const content_type = req.head.content_type orelse return error.MissingContentType;
    const content_length = req.head.content_length orelse return error.MissingContentLength;
    if (std.mem.startsWith(u8, content_type, "multipart/form-data")) {
        var result: *T = try arena.create(T);
        errdefer arena.destroy(result);

        const buff = try arena.alloc(u8, content_length);
        defer arena.free(buff);

        const reader = req.server.reader.bodyReader(
            buff,
            req.head.transfer_encoding,
            content_length,
        );

        const content = try reader.readAlloc(arena, content_length);
        const boundary_pos = std.mem.findLast(u8, content_type, "boundary=") orelse return error.BoundaryMissing;
        const boundary = std.mem.trim(u8, content_type[boundary_pos + 9 ..], "\r\n");
        const splitter = try std.fmt.allocPrint(arena, "--{s}", .{boundary});
        defer arena.free(splitter);

        var body_it = std.mem.splitSequence(u8, content, splitter);
        while (body_it.next()) |part| {
            const part_trimmed = std.mem.trim(u8, part, "\r\n");
            if (part_trimmed.len == 0 or std.mem.eql(u8, "--", part_trimmed)) continue;
            var it = std.mem.splitSequence(u8, part_trimmed, "\r\n\r\n");
            const headers = it.next() orelse continue;
            var part_header_it = std.mem.splitSequence(u8, headers, "\r\n");
            const key = blk: {
                while (part_header_it.next()) |header| {
                    if (std.mem.startsWith(u8, header, CONTENT_DISPOSITION)) {
                        const name_start = CONTENT_DISPOSITION.len;
                        const name_end = std.mem.findLast(u8, header[name_start..], "\"") orelse continue;
                        break :blk header[name_start .. name_start + name_end];
                    }
                }

                unreachable;
            };

            const value = it.next() orelse continue;
            inline for (std.meta.fields(T)) |field| {
                if (std.mem.eql(u8, field.name, key)) {
                    @field(result, field.name) = try utils.parse(field.type, value);
                }
            }
        }

        return result;
    }

    return error.Unimplemented; // TODO: implement x-www-form-urlencoded support
}

pub fn Form(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const ID: []const u8 = EXTRACTOR_ID;

        result: anyerror!*T,

        pub fn init(ctx: Context) !*T {
            return extract(T, ctx.request_allocator, ctx.request);
        }
    };
}

const testing = std.testing;
var testing_arena: std.heap.ArenaAllocator = .init(testing.allocator);
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const Server = std.http.Server;

test "init returns Form with value when form data is present" {
    const testing_allocator = testing_arena.allocator();
    defer testing_arena.deinit();

    const req_bytes =
        "POST / HTTP/1.1\r\n" ++
        "Accept-Encoding: gzip, deflate, br\r\n" ++
        "Connection: keep-alive\r\n" ++
        "Content-Type: multipart/form-data; boundary=--------------------------727622845833790348454509\r\n" ++
        "Content-Length: {d}\r\n\r\n{s}";

    const form_content =
        "----------------------------727622845833790348454509\r\n" ++
        "Content-Disposition: form-data; name=\"name\"\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "\r\n" ++
        "Name\r\n" ++
        "----------------------------727622845833790348454509\r\n" ++
        "Content-Disposition: form-data; name=\"age\"\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "\r\n" ++
        "30\r\n" ++
        "----------------------------727622845833790348454509--\r\n";

    const form_data = try std.fmt.allocPrint(testing_allocator, req_bytes, .{ form_content.len, form_content });
    var stream_buf_reader = Reader.fixed(form_data);

    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = Writer.fixed(&write_buffer);

    var http_server = Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    const test_ctx: Context = .{
        .io = undefined,
        .request_allocator = testing_allocator,
        .request = &http_req,
    };

    const Person = struct {
        name: []const u8,
        age: u8,
    };

    const person = Form(Person).init(test_ctx) catch {
        try testing.expect(false);
        return;
    };

    try testing.expectEqualStrings("Name", person.name);
    try testing.expectEqual(30, person.age);
}
