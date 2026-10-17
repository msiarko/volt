const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Request = std.http.Server.Request;
const WebSocket = std.http.Server.WebSocket;
const WriterError = std.Io.Writer.Error;
const ExpectedContinueError = std.http.Server.Request.ExpectContinueError;

const Context = @import("../core/Context.zig");

pub const WebSocketUpgradeError = error{
    WebSocketKeyMissing,
    NotWebSocketUpgrade,
};

pub const WebSocketError = WebSocketUpgradeError || WriterError || ExpectedContinueError;

const Self = @This();

socket: WebSocket,

pub fn init(ctx: Context) WebSocketError!Self {
    return .{ .socket = try extract(ctx.raw_req) };
}

pub fn errorMessage(err: WebSocketError) []const u8 {
    return switch (err) {
        WebSocketUpgradeError.WebSocketKeyMissing => "WebSocket key missing in request",
        WebSocketUpgradeError.NotWebSocketUpgrade => "Request is not a WebSocket upgrade",
        ExpectedContinueError.HttpExpectationFailed => "Expect-Continue not supported for WebSocket upgrade",
        ExpectedContinueError.WriteFailed => "Failed to write Expect-Continue response",
    };
}

pub fn onConnected(self: *const Self, handler: anytype, args: anytype) !void {
    const args_type_info = @typeInfo(@TypeOf(args));
    if (args_type_info != .@"struct" and !args_type_info.@"struct".is_tuple) {
        @compileError("args must be a tuple");
    }

    const handler_type_info = @typeInfo(@TypeOf(handler));
    if (handler_type_info != .@"fn") {
        @compileError("handler must be a function");
    }

    const handler_params_len = handler_type_info.@"fn".param_attrs.len;
    const field_types = args_type_info.@"struct".field_types;
    const params = comptime getParamsTypes(handler_params_len, field_types);
    var new_args: @Tuple(params) = undefined;
    inline for (0..params.len) |i| {
        if (i == params.len - 1) {
            new_args[i] = &self.socket;
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

fn getParamsTypes(comptime params_len: usize, comptime param_types: []const type) []const type {
    comptime var params: [params_len]type = undefined;
    inline for (0..params_len) |i| {
        if (i == params_len - 1) {
            params[i] = *WebSocket;
        } else if (i < param_types.len) {
            params[i] = param_types[i];
        }
    }

    return &params;
}

test "init returns NotWebSocketUpgrade for regular HTTP request" {
    const testing = std.testing;
    const Reader = std.Io.Reader;
    const Writer = std.Io.Writer;
    const Server = std.http.Server;

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

test "init returns WebSocketUpgradeError.WebSocketKeyMissing for WebSocket upgrade request without key" {
    const err = WebSocketError.WebSocketKeyMissing;
    const msg = errorMessage(err);
    try std.testing.expectEqualStrings("WebSocket key missing in request", msg);
}
