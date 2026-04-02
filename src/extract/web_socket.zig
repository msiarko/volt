const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Request = std.http.Server.Request;
const StructField = std.builtin.Type.StructField;
const Socket = std.http.Server.WebSocket;
const WriterError = std.Io.Writer.Error;
const ExpectedContinueError = std.http.Server.Request.ExpectContinueError;

const Context = @import("../http/context.zig").Context;
const Response = @import("../http/response.zig").Response;
const utils = @import("utils.zig");

fn extract(req: *Request) WebSocketError!Socket {
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
            params[i] = *Socket;
        } else if (i < args_fields.len) {
            params[i] = args_fields[i].type;
        }
    }

    return &params;
}

pub const WebSocketUpgradeError = error{
    WebSocketKeyMissing,
    NotWebSocketUpgrade,
};

pub const WebSocketError = WebSocketUpgradeError || WriterError || ExpectedContinueError;

/// Creates a `WebSocket` extractor.
///
/// The extractor struct contains:
/// - `result`: `WebSocketError!Socket`
///
/// On success, the HTTP request is upgraded and a connected socket is available.
///
/// The extractor can be used either:
/// - as a router handler parameter (automatic injection), or
/// - manually inside a handler body with `WebSocket{ .result = WebSocket.init(ctx) }`.
///
/// In handlers, call `onConnected` to run your connection routine, then return `intoResponse()`.
///
/// ```zig
/// fn handleRequest(ctx: Context, ws: WebSocket) !Response {
///     try ws.onConnected(handleWebSocket, .{ ctx });
///     return ws.intoResponse();
/// }
/// ```
pub const WebSocket = struct {
    const Self = @This();

    result: WebSocketError!Socket,

    pub fn init(ctx: Context) !Socket {
        return try extract(ctx.request);
    }

    pub fn onConnected(self: *const Self, handler: anytype, args: anytype) !void {
        var socket = try self.result;
        const Args = @TypeOf(args);
        const args_type_info = @typeInfo(Args);
        if (args_type_info != .@"struct" and !args_type_info.@"struct".is_tuple) {
            @compileError("args must be a tuple");
        }

        const Handler = @TypeOf(handler);
        const handler_type_info = @typeInfo(Handler);
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

    pub fn intoResponse(self: Self) Response {
        return .{ .web_socket = self };
    }
};

pub const Resolver = struct {
    pub fn matches(comptime Extractor: type) bool {
        return Extractor == WebSocket;
    }

    pub fn resolve(comptime Extractor: type, arena: Allocator, req: *Request) Extractor {
        _ = arena;
        comptime assert(Extractor == WebSocket);
        const result = extract(req);
        return .{ .result = result };
    }
};

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
        .request_allocator = testing.allocator,
        .request = &http_req,
    };
    const ws_result = WebSocket.init(test_ctx);
    try testing.expectEqual(WebSocketError.NotWebSocketUpgrade, ws_result);
}

test "Resolver.matches is true only for WebSocket extractor" {
    try testing.expect(Resolver.matches(WebSocket));
    try testing.expect(!Resolver.matches(utils.TestExtractor));
}

test "Resolver.resolve stores upgrade error for regular HTTP request" {
    const req_bytes = "GET /ws HTTP/1.1\r\n\r\n";
    var stream_buf_reader = Reader.fixed(req_bytes);

    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = Writer.fixed(&write_buffer);

    var http_server = Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    const extracted = Resolver.resolve(WebSocket, testing.allocator, &http_req);
    try testing.expectError(WebSocketError.NotWebSocketUpgrade, extracted.result);
}

test "intoResponse returns web_socket variant" {
    const ws: WebSocket = .{ .result = WebSocketError.NotWebSocketUpgrade };
    const res = ws.intoResponse();

    switch (res) {
        .web_socket => {},
        else => try testing.expect(false),
    }
}

test "onConnected returns stored extractor error" {
    const ws: WebSocket = .{ .result = WebSocketError.NotWebSocketUpgrade };
    const handler = struct {
        fn f(_: *std.http.Server.WebSocket) !void {}
    }.f;

    try testing.expectError(WebSocketError.NotWebSocketUpgrade, ws.onConnected(handler, .{}));
}
