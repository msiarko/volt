const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Request = std.http.Server.Request;
const StructField = std.builtin.Type.StructField;
const WebSocket = std.http.Server.WebSocket;
const WriterError = std.Io.Writer.Error;
const ExpectedContinueError = std.http.Server.Request.ExpectContinueError;

const Context = @import("core").Context;
const utils = @import("utils.zig");

pub const WebSocketUpgradeError = error{
    WebSocketKeyMissing,
    NotWebSocketUpgrade,
};

pub const WebSocketError = WebSocketUpgradeError || WriterError || ExpectedContinueError;

const Self = @This();

result: WebSocketError!WebSocket,

pub fn init(ctx: Context) !WebSocket {
    return try extract(ctx.raw_req);
}

pub fn onConnected(self: *const Self, handler: anytype, args: anytype) !void {
    var socket = try self.result;
    const args_type_info = @typeInfo(@TypeOf(args));
    if (args_type_info != .@"struct" and !args_type_info.@"struct".is_tuple) {
        @compileError("args must be a tuple");
    }

    const handler_type_info = @typeInfo(@TypeOf(handler));
    if (handler_type_info != .@"fn") {
        @compileError("handler must be a function");
    }

    const handler_params_len = handler_type_info.@"fn".params.len;
    const args_fields = args_type_info.@"struct".fields;
    const params = comptime getParamsTypes(handler_params_len, args_fields);
    var new_args: @Tuple(params) = undefined;
    inline for (0..params.len) |i| {
        if (i == params.len - 1) {
            new_args[i] = &socket;
        } else {
            new_args[i] = args[i];
        }
    }

    try @call(.always_inline, handler, new_args);
}

fn extract(req: *Request) WebSocketError!WebSocket {
    const upg = req.upgradeRequested();
    return switch (upg) {
        .websocket => |key| {
            if (key) |k| {
                var ws = try req.respondWebSocket(.{ .key = k });
                try ws.flush();
                return ws;
            }

            return WebSocketError.WebSocketKeyMissing;
        },
        else => return WebSocketError.NotWebSocketUpgrade,
    };
}

fn getParamsTypes(comptime params_len: usize, comptime args_fields: []const StructField) []const type {
    comptime var params: [params_len]type = undefined;
    inline for (0..params_len) |i| {
        if (i == params_len - 1) {
            params[i] = *WebSocket;
        } else if (i < args_fields.len) {
            params[i] = args_fields[i].type;
        }
    }

    return &params;
}

const testing = std.testing;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const Server = std.http.Server;

test "init returns NotWebSocketUpgrade for regular HTTP request" {
    const req_bytes = std.fmt.comptimePrint("GET /ws HTTP/1.1\r\n" ++ "\r\n", .{});
    var stream_buf_reader = Reader.fixed(req_bytes);

    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = Writer.fixed(&write_buffer);

    var http_server = Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    const test_ctx: Context = .{
        .io = undefined,
        .req_arena = testing.allocator,
        .raw_req = &http_req,
    };
    const ws_result = Self.init(test_ctx);
    try testing.expectEqual(WebSocketError.NotWebSocketUpgrade, ws_result);
}

test "onConnected returns stored extractor error" {
    const ws: Self = .{ .result = WebSocketError.NotWebSocketUpgrade };
    const handler = struct {
        fn f(_: *std.http.Server.WebSocket) !void {}
    }.f;

    try testing.expectError(WebSocketError.NotWebSocketUpgrade, ws.onConnected(handler, .{}));
}
