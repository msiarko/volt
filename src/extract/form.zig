const std = @import("std");
const Allocator = std.mem.Allocator;
const AllocatorError = std.mem.Allocator.Error;
const ReadAllocError = std.Io.Reader.ReadAllocError;
const Context = @import("../core/Context.zig");
const url = @import("url.zig");
const Request = std.http.Server.Request;

const CONTENT_DISPOSITION: []const u8 = "Content-Disposition";

const FormError = url.ParseError || AllocatorError || ReadAllocError || error{
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

    const type_info = @typeInfo(T);
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
        inline for (type_info.@"struct".field_names, type_info.@"struct".field_types) |field_name, field_type| {
            if (std.mem.eql(u8, field_name, key)) {
                @field(out, field_name) = try url.parse(field_type, value);
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

    const type_info = @typeInfo(T);
    var pairs_it = std.mem.splitScalar(u8, content, '&');
    while (pairs_it.next()) |pair| {
        var kv_it = std.mem.splitScalar(u8, pair, '=');
        const key = kv_it.next() orelse return FormError.EmptyFormDataKey;
        const value = kv_it.next() orelse return FormError.EmptyFormDataValue;
        var matched = false;
        inline for (type_info.@"struct".field_names) |field_name| {
            if (std.mem.eql(u8, field_name, key)) {
                matched = true;
            }
        }

        const key_decoded = if (matched)
            key
        else
            try url.decode(arena, key);

        inline for (type_info.@"struct".field_names, type_info.@"struct".field_types) |field_name, field_type| {
            if (std.mem.eql(u8, field_name, key_decoded)) {
                const value_decoded = try url.decode(arena, value);
                @field(out, field_name) = try url.parse(field_type, value_decoded);
            }
        }
    }

    return out;
}

fn extract(comptime T: type, arena: Allocator, req: *Request) FormError!*T {
    const content_type = req.head.content_type orelse return FormError.MissingContentType;
    const content_length = req.head.content_length orelse return FormError.MissingContentLength;
    if (content_length == 0) return FormError.EmptyBody;
    const content = try arena.alloc(u8, content_length);

    const reader = req.server.reader.bodyReader(
        content,
        req.head.transfer_encoding,
        content_length,
    );

    try reader.readSliceAll(content);
    if (std.mem.startsWith(u8, content_type, "multipart/form-data")) {
        const boundary_prefix = "boundary=";
        const boundary_pos = std.mem.findLast(u8, content_type, boundary_prefix) orelse
            return FormError.MissingBoundary;

        const boundary = std.mem.trim(u8, content_type[boundary_pos + boundary_prefix.len ..], "\r\n");
        const delimeter = try arena.print("--{s}", .{boundary});
        defer arena.free(delimeter);

        return extractMultipartFormData(T, arena, delimeter, content);
    } else if (std.mem.eql(u8, content_type, "application/x-www-form-urlencoded")) {
        return extractUrlEncodedFormData(T, arena, content);
    }

    return FormError.UnsupportedContentType;
}

pub fn Form(comptime T: type) type {
    return struct {
        const Self = @This();

        data: *T,

        pub fn init(ctx: Context) FormError!Self {
            return .{ .data = try extract(T, ctx.req_arena, ctx.raw_req) };
        }

        pub fn errorMessage(err: FormError) []const u8 {
            return switch (err) {
                FormError.MissingContentType => "Missing Content-Type header",
                FormError.MissingContentLength => "Missing Content-Length header",
                FormError.EmptyBody => "Request body is empty",
                FormError.MalformedMultipartBody => "Malformed multipart/form-data body",
                FormError.MissingBoundary => "Missing boundary in multipart/form-data Content-Type",
                FormError.UnsupportedContentType => "Unsupported Content-Type for form data",
                FormError.EmptyFormDataKey => "Empty key in form data",
                FormError.EmptyFormDataValue => "Empty value in form data",
                else => |e| @errorName(e),
            };
        }
    };
}

test "init returns Form with value when content type is multipart/form-data" {
    const testing = std.testing;
    const Reader = std.Io.Reader;
    const Writer = std.Io.Writer;
    const Server = std.http.Server;

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

    const form_data = try testing_arena.print(req_bytes, .{ form_content.len, form_content });
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

    const form = try Form(Person).init(test_ctx);
    try testing.expectEqualStrings("Name", form.data.name);
    try testing.expectEqual(30, form.data.age);
}

test "init returns Form with value when content type is application/x-www-form-urlencoded" {
    const testing = std.testing;
    const Reader = std.Io.Reader;
    const Writer = std.Io.Writer;
    const Server = std.http.Server;

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

    const form_data = try testing_arena.print(req_bytes, .{ form_content.len, form_content });
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

    const form = try Form(Person).init(test_ctx);
    try testing.expectEqualStrings("Name White", form.data.name);
    try testing.expectEqual(30, form.data.age);
}

test "init returns error when content type is missing" {
    const testing = std.testing;
    const Reader = std.Io.Reader;
    const Writer = std.Io.Writer;
    const Server = std.http.Server;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const testing_arena = arena.allocator();
    const req_bytes =
        "POST / HTTP/1.1\r\n" ++
        "Accept-Encoding: gzip, deflate, br\r\n" ++
        "Connection: keep-alive\r\n" ++
        "Content-Length: {d}\r\n\r\n{s}";

    const form_content = "name=Name%20White&age=30";

    const form_data = try testing_arena.print(req_bytes, .{ form_content.len, form_content });
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

    try testing.expectError(FormError.MissingContentType, Form(Person).init(test_ctx));
}

test "init returns error when content length is missing" {
    const testing = std.testing;
    const Reader = std.Io.Reader;
    const Writer = std.Io.Writer;
    const Server = std.http.Server;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const testing_arena = arena.allocator();
    const req_bytes =
        "POST / HTTP/1.1\r\n" ++
        "Accept-Encoding: gzip, deflate, br\r\n" ++
        "Connection: keep-alive\r\n" ++
        "Content-Type: application/x-www-form-urlencoded\r\n\r\n{s}";

    const form_content = "name=Name%20White&age=30";

    const form_data = try testing_arena.print(req_bytes, .{form_content});
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

    try testing.expectError(FormError.MissingContentLength, Form(Person).init(test_ctx));
}

test "init returns error when body is empty" {
    const testing = std.testing;
    const Reader = std.Io.Reader;
    const Writer = std.Io.Writer;
    const Server = std.http.Server;

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

    const form_data = try testing_arena.print(req_bytes, .{ form_content.len, form_content });
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

    try testing.expectError(FormError.EmptyBody, Form(Person).init(test_ctx));
}

test "errorMessage returns correct message for FormError" {
    const form_error = FormError.MissingContentType;
    const msg = Form(@This()).errorMessage(form_error);
    try std.testing.expectEqualStrings("Missing Content-Type header", msg);
}

test "errorMessage returns correct message for AllocatorError" {
    const form_error = AllocatorError.OutOfMemory;
    const msg = Form(@This()).errorMessage(form_error);
    try std.testing.expectEqualStrings("OutOfMemory", msg);
}
