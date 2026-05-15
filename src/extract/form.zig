const std = @import("std");
const Allocator = std.mem.Allocator;
const AllocatorError = std.mem.Allocator.Error;
const ReadAllocError = std.Io.Reader.ReadAllocError;
const assert = std.debug.assert;
const Context = @import("core").Context;
const utils = @import("utils.zig");
const Request = std.http.Server.Request;

const EXTRACTOR_ID: []const u8 = "VOLT_FORM_EXTRACTOR";
const CONTENT_DISPOSITION: []const u8 = "Content-Disposition";

const FormError = utils.ParseError || AllocatorError || ReadAllocError || error{
    MissingContentType,
    MissingContentLength,
    EmptyBody,
    MalformedMultipartBody,
    MissingBoundary,
    UnsupportedContentType,
    EmptyFormDataKey,
    EmptyFormDataValue,
};

fn extractMultipartFormData(
    comptime T: type,
    arena: Allocator,
    delimiter: []const u8,
    content: []const u8,
) FormError!*T {
    const out: *T = try arena.create(T);
    errdefer arena.destroy(out);

    var body_it = std.mem.splitSequence(u8, content, delimiter);
    while (body_it.next()) |part| {
        const part_trimmed = std.mem.trim(u8, part, "\r\n");
        if (part_trimmed.len == 0 or std.mem.eql(u8, "--", part_trimmed)) continue;
        var it = std.mem.splitSequence(u8, part_trimmed, "\r\n\r\n");
        const headers = it.next() orelse return FormError.MalformedMultipartBody;
        const key = blk: {
            var part_header_it = std.mem.splitSequence(u8, headers, "\r\n");
            while (part_header_it.next()) |header| {
                if (std.mem.startsWith(u8, header, CONTENT_DISPOSITION)) {
                    const end = header.len - 1;
                    const val = header[CONTENT_DISPOSITION.len + 1 .. end];
                    const start = std.mem.findScalarLast(u8, val, '"') orelse
                        return FormError.MalformedMultipartBody;

                    break :blk val[start + 1 ..];
                }
            } else unreachable;
        };

        const value = it.next() orelse return FormError.MalformedMultipartBody;
        inline for (std.meta.fields(T)) |field| {
            if (std.mem.eql(u8, field.name, key)) {
                @field(out, field.name) = try utils.parse(field.type, value);
            }
        }
    }

    return out;
}

fn extractUrlEncodedFormData(
    comptime T: type,
    arena: std.mem.Allocator,
    content: []const u8,
) FormError!*T {
    const out: *T = try arena.create(T);
    errdefer arena.destroy(out);

    var pairs_it = std.mem.splitScalar(u8, content, '&');
    while (pairs_it.next()) |pair| {
        var kv_it = std.mem.splitScalar(u8, pair, '=');
        const key = kv_it.next() orelse return FormError.EmptyFormDataKey;
        const value = kv_it.next() orelse return FormError.EmptyFormDataValue;
        const key_decoded = try utils.decodeUrl(arena, key);
        const value_decoded = try utils.decodeUrl(arena, value);

        inline for (std.meta.fields(T)) |field| {
            if (std.mem.eql(u8, field.name, key_decoded)) {
                @field(out, field.name) = try utils.parse(field.type, value_decoded);
            }
        }
    }

    return out;
}

fn extract(comptime T: type, arena: Allocator, req: *Request) FormError!*T {
    const content_type = req.head.content_type orelse return FormError.MissingContentType;
    const content_length = req.head.content_length orelse return FormError.MissingContentLength;
    if (content_length == 0) return FormError.EmptyBody;
    const buff = try arena.alloc(u8, content_length);
    defer arena.free(buff);

    const reader = req.server.reader.bodyReader(
        buff,
        req.head.transfer_encoding,
        content_length,
    );

    const content = try reader.readAlloc(arena, content_length);
    if (std.mem.startsWith(u8, content_type, "multipart/form-data")) {
        const boundary_prefix = "boundary=";
        const boundary_pos = std.mem.findLast(u8, content_type, boundary_prefix) orelse
            return FormError.MissingBoundary;

        const boundary = std.mem.trim(u8, content_type[boundary_pos + boundary_prefix.len ..], "\r\n");
        const delimeter = try std.fmt.allocPrint(arena, "--{s}", .{boundary});
        defer arena.free(delimeter);

        return extractMultipartFormData(T, arena, delimeter, content);
    } else if (std.mem.eql(u8, content_type, "application/x-www-form-urlencoded")) {
        return extractUrlEncodedFormData(T, arena, content);
    } else {
        return FormError.UnsupportedContentType;
    }
}

pub fn Form(comptime T: type) type {
    return struct {
        pub const ID: []const u8 = EXTRACTOR_ID;
        pub const PAYLOAD_TYPE: type = T;

        result: FormError!*T,

        pub fn init(ctx: Context) FormError!*T {
            return extract(T, ctx.req_arena, ctx.raw_req);
        }
    };
}

pub const Resolver = struct {
    pub const ID: []const u8 = EXTRACTOR_ID;

    pub fn resolve(comptime Extractor: type, ctx: Context) Extractor {
        comptime assert(@hasDecl(Extractor, "PAYLOAD_TYPE"));
        return .{ .result = extract(@field(Extractor, "PAYLOAD_TYPE"), ctx.req_arena, ctx.raw_req) };
    }
};

const testing = std.testing;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const Server = std.http.Server;

test "init returns Form with value when content type is multipart/form-data" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const testing_arena = arena.allocator();
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

    const form_data = try std.fmt.allocPrint(testing_arena, req_bytes, .{ form_content.len, form_content });
    var stream_buf_reader = Reader.fixed(form_data);

    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = Writer.fixed(&write_buffer);

    var http_server = Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    const test_ctx: Context = .{
        .io = undefined,
        .req_arena = testing_arena,
        .raw_req = &http_req,
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

test "init returns Form with value when content type is application/x-www-form-urlencoded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const testing_arena = arena.allocator();
    const req_bytes =
        "POST / HTTP/1.1\r\n" ++
        "Accept-Encoding: gzip, deflate, br\r\n" ++
        "Connection: keep-alive\r\n" ++
        "Content-Type: application/x-www-form-urlencoded\r\n" ++
        "Content-Length: {d}\r\n\r\n{s}";

    const form_content = "name=Name%20White&age=30";

    const form_data = try std.fmt.allocPrint(testing_arena, req_bytes, .{ form_content.len, form_content });
    var stream_buf_reader = Reader.fixed(form_data);

    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = Writer.fixed(&write_buffer);

    var http_server = Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    const test_ctx: Context = .{
        .io = undefined,
        .req_arena = testing_arena,
        .raw_req = &http_req,
    };

    const Person = struct {
        name: []const u8,
        age: u8,
    };

    const person = Form(Person).init(test_ctx) catch {
        try testing.expect(false);
        return;
    };

    try testing.expectEqualStrings("Name White", person.name);
    try testing.expectEqual(30, person.age);
}

test "init returns error when content type is missing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const testing_arena = arena.allocator();
    const req_bytes =
        "POST / HTTP/1.1\r\n" ++
        "Accept-Encoding: gzip, deflate, br\r\n" ++
        "Connection: keep-alive\r\n" ++
        "Content-Length: {d}\r\n\r\n{s}";

    const form_content = "name=Name%20White&age=30";

    const form_data = try std.fmt.allocPrint(testing_arena, req_bytes, .{ form_content.len, form_content });
    var stream_buf_reader = Reader.fixed(form_data);

    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = Writer.fixed(&write_buffer);

    var http_server = Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    const test_ctx: Context = .{
        .io = undefined,
        .req_arena = testing_arena,
        .raw_req = &http_req,
    };

    const Person = struct {
        name: []const u8,
        age: u8,
    };

    const person = Form(Person).init(test_ctx);

    try testing.expectError(error.MissingContentType, person);
}

test "init returns error when content length is missing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const testing_arena = arena.allocator();
    const req_bytes =
        "POST / HTTP/1.1\r\n" ++
        "Accept-Encoding: gzip, deflate, br\r\n" ++
        "Connection: keep-alive\r\n" ++
        "Content-Type: application/x-www-form-urlencoded\r\n\r\n{s}";

    const form_content = "name=Name%20White&age=30";

    const form_data = try std.fmt.allocPrint(testing_arena, req_bytes, .{form_content});
    var stream_buf_reader = Reader.fixed(form_data);

    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = Writer.fixed(&write_buffer);

    var http_server = Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    const test_ctx: Context = .{
        .io = undefined,
        .req_arena = testing_arena,
        .raw_req = &http_req,
    };

    const Person = struct {
        name: []const u8,
        age: u8,
    };

    const person = Form(Person).init(test_ctx);

    try testing.expectError(error.MissingContentLength, person);
}

test "init returns error when body is empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const testing_arena = arena.allocator();
    const req_bytes =
        "POST / HTTP/1.1\r\n" ++
        "Accept-Encoding: gzip, deflate, br\r\n" ++
        "Connection: keep-alive\r\n" ++
        "Content-Type: application/x-www-form-urlencoded\r\n" ++
        "Content-Length: {d}\r\n\r\n{s}";

    const form_content = "";

    const form_data = try std.fmt.allocPrint(testing_arena, req_bytes, .{ form_content.len, form_content });
    var stream_buf_reader = Reader.fixed(form_data);

    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = Writer.fixed(&write_buffer);

    var http_server = Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    const test_ctx: Context = .{
        .io = undefined,
        .req_arena = testing_arena,
        .raw_req = &http_req,
    };

    const Person = struct {
        name: []const u8,
        age: u8,
    };

    const person = Form(Person).init(test_ctx);
    try testing.expectError(error.EmptyBody, person);
}
