//! WebSocket extractor for the Volt web library.
//!
//! This module provides automatic WebSocket upgrade handling through the
//! router's parameter injection system. When a handler parameter is detected
//! as a WebSocket type, the library automatically handles the HTTP upgrade
//! handshake and provides the WebSocket connection to the handler.
//!
//! Applications that want more control can skip the automatic extractor and
//! use `ctx.request` directly from `Context` to inspect or manage the upgrade
//! flow themselves.

const std = @import("std");
const Request = std.http.Server.Request;
const StructField = std.builtin.Type.StructField;
const Socket = std.http.Server.WebSocket;
const Context = @import("../http/context.zig").Context;

pub const WebSocketError = error{
    /// Failed to perform WebSocket upgrade handshake.
    WebSocketUpgradeFailed,
    /// Request missing required Sec-WebSocket-Key header.
    WebSocketKeyMissing,
    /// Request is not a WebSocket upgrade request.
    NotWebSocketUpgrade,
    /// WebSocket handler function execution failed.
    WebSocketHandlerFailed,
};

/// Resolver for WebSocket extractors in the compile-time registry.
///
/// This struct implements the resolver interface (`matches` and `resolve`) to enable
/// automatic detection and instantiation of WebSocket extractor types during parameter resolution.
pub const Resolver = struct {
    pub fn matches(comptime T: type) bool {
        return @typeInfo(T) == .@"struct" and
            @hasDecl(T, "VOLT_WEBSOCKET_EXTRACTOR") and
            @field(T, "VOLT_WEBSOCKET_EXTRACTOR");
    }

    pub fn resolve(comptime T: type, allocator: std.mem.Allocator, req: *Request) T {
        _ = allocator;
        return initWebSocket(req);
    }

    pub fn resolveWithContext(comptime T: type, ctx: Context) T {
        return WebSocket.fromContext(ctx);
    }
};

/// Attempts to upgrade the connection to WebSocket.
///
/// Returns a WebSocket error on failure (missing key, not an upgrade request, etc.)
fn initWebSocket(req: *Request) WebSocket {
    const upg = req.upgradeRequested();
    return switch (upg) {
        .websocket => |key| {
            if (key) |k| {
                var ws = req.respondWebSocket(.{ .key = k }) catch return .{ .socket = WebSocketError.WebSocketUpgradeFailed };
                ws.flush() catch return .{ .socket = WebSocketError.WebSocketUpgradeFailed };
                defer ws.flush() catch {};
                return .{ .socket = ws };
            }

            return .{ .socket = WebSocketError.WebSocketKeyMissing };
        },
        else => return .{ .socket = WebSocketError.NotWebSocketUpgrade },
    };
}

/// WebSocket extractor and upgrade handler.
///
/// This struct represents a WebSocket upgrade request and provides
/// methods to handle the upgrade process and execute WebSocket handlers.
///
/// Example usage in a router handler:
/// ```zig
/// fn websocketHandler(ctx: Context, state: *MyState, ws: WebSocket) !Response {
///     return ws.intoResponse();
/// }
///
/// // In your route setup:
/// try router.get("/ws", &websocketHandler);
/// ```
pub const WebSocket = struct {
    const Self = @This();

    /// Compile-time marker used to identify WebSocket extractor types.
    pub const VOLT_WEBSOCKET_EXTRACTOR = true;

    /// The underlying WebSocket connection
    socket: WebSocketError!Socket,

    /// Upgrades the request connection to WebSocket from request context.
    ///
    /// When a request context is available, use this method for manual extraction.
    /// This still performs Volt's automatic handshake behavior. If you need
    /// lower-level control over when or how the upgrade happens, use
    /// `ctx.request` directly instead.
    ///
    /// Parameters:
    /// - `ctx`: Request context (any type with request field). Use `ctx.io` for
    ///   any I/O operations required within the surrounding handler.
    ///
    /// Returns: WebSocket extractor with upgraded socket or error
    pub fn fromContext(ctx: Context) Self {
        return initWebSocket(ctx.request);
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

    /// Handles WebSocket upgrade and executes the WebSocket handler.
    ///
    /// This method performs the WebSocket handshake, establishes the connection,
    /// and calls the provided handler function with the WebSocket connection
    /// and any additional arguments.
    ///
    /// Parameters:
    /// - `handler`: Function to handle the WebSocket connection
    /// - `args`: Tuple of additional arguments to pass to the handler
    ///
    /// The handler function signature should be:
    /// `fn(args..., *std.http.Server.WebSocket) !void`
    ///
    /// Example:
    /// ```zig
    /// fn handleConnection(name: []const u8, ws: *Socket) !void {
    ///     const message = try ws.readMessage();
    ///     try ws.writeMessage(.{ .text = try std.fmt.allocPrint(ctx.request_allocator, "Hello {s}!", .{name}) });
    /// }
    ///
    /// try ws.onConnected(handleConnection, .{"Alice"});
    /// ```
    pub fn onConnected(self: *const Self, handler: anytype, args: anytype) !void {
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
                var socket = try self.socket;
                new_args[i] = &socket;
            } else {
                new_args[i] = args[i];
            }
        }

        @call(.always_inline, handler, new_args) catch return WebSocketError.WebSocketHandlerFailed;
    }
};

const testing = std.testing;

test "Resolver.matches returns true for WebSocket extractor" {
    try std.testing.expect(comptime Resolver.matches(WebSocket));
}

test "Resolver.matches returns false for non-WebSocket extractor" {
    const Person = struct {
        name: []const u8,
        age: u7,
    };

    try std.testing.expect(!comptime Resolver.matches(Person));
}

test "init returns NotWebSocketUpgrade for regular HTTP request" {
    const req_bytes = std.fmt.comptimePrint("GET /ws HTTP/1.1\r\n" ++ "\r\n", .{});
    var stream_buf_reader = std.Io.Reader.fixed(req_bytes);

    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = std.Io.Writer.fixed(&write_buffer);

    var http_server = std.http.Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    const test_ctx: Context = .{
        .io = undefined,
        .server_allocator = std.testing.allocator,
        .request_allocator = std.testing.allocator,
        .request = &http_req,
        ._cache = null,
    };
    const ws = WebSocket.fromContext(test_ctx);
    try std.testing.expectError(WebSocketError.NotWebSocketUpgrade, ws.socket);
}
