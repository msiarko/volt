//! WebSocket extractor for the Volt web library.
//!
//! This module provides automatic WebSocket upgrade handling through the
//! router's parameter injection system. When a handler parameter is detected
//! as a WebSocket type, the library automatically handles the HTTP upgrade
//! handshake and provides the WebSocket connection to the handler.

const std = @import("std");
const Request = std.http.Server.Request;
const StructField = std.builtin.Type.StructField;
const Socket = std.http.Server.WebSocket;
const http = @import("http");
const utils = @import("utils.zig");

/// Key used to identify WebSocket extractor types at compile time.
const WS_EXTRACTOR_KEY: []const u8 = "WS_EXTRACTOR";

pub const WebSocketError = error{
    WebSocketUpgradeFailed,
    WebSocketKeyMissing,
    NotWebSocketUpgrade,
    WebSocketHandlerFailed,
};

/// Checks if a type is a WebSocket extractor by examining its structure.
///
/// This function uses compile-time reflection to determine if the given type
/// has a field named "key" with the default value "WS_EXTRACTOR".
///
/// Parameters:
/// - `T`: The type to check
///
/// Returns: true if T is a WebSocket extractor type, false otherwise
///
/// This is used by the router to automatically detect WebSocket parameters
/// in handler function signatures.
pub fn matches(comptime T: type) bool {
    return utils.matches(T, WS_EXTRACTOR_KEY);
}

/// Creates a WebSocket extractor from an HTTP request.
///
/// This function wraps an HTTP request in a WebSocket extractor struct,
/// preparing it for potential WebSocket upgrade handling.
///
/// Parameters:
/// - `req`: The HTTP request that may be upgraded to WebSocket
///
/// Returns: WebSocket extractor instance
///
/// The returned WebSocket can be used with onConnected() to handle
/// the actual WebSocket handshake and connection.
pub fn init(req: *Request) WebSocket {
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

    /// Extractor key for type identification
    key: []const u8 = WS_EXTRACTOR_KEY,
    /// The underlying WebSocket connection
    socket: WebSocketError!Socket,

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
        const args_fileds = args_type_info.@"struct".fields;
        const params = comptime getParamsTypes(handler_params_len, args_fileds);
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

    /// Converts the WebSocket extractor to an HTTP Response.
    ///
    /// This method allows WebSocket extractors to be returned from HTTP
    /// handlers, triggering the WebSocket upgrade process through the
    /// response handling system.
    ///
    /// Returns: HTTP Response containing the WebSocket upgrade
    ///
    /// This is typically used as the return value from route handlers
    /// that handle WebSocket connections.
    pub fn intoResponse(self: Self) http.Response {
        return .{ .web_socket = self };
    }
};

const testing = std.testing;

test "matches returns true for WebSocket extractor" {
    try std.testing.expect(comptime matches(WebSocket));
}

test "matches returns false for non-WebSocket extractor" {
    const Person = struct {
        name: []const u8,
        age: u7,
    };

    try std.testing.expect(!comptime matches(Person));
}
