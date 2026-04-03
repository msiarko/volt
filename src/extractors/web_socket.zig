const std = @import("std");
const Request = std.http.Server.Request;
const StructField = std.builtin.Type.StructField;
const Socket = std.http.Server.WebSocket;
const http = @import("http");
const utils = @import("utils.zig");

const WS_EXTRACTOR_KEY: []const u8 = "WS_EXTRACTOR";

pub fn matches(comptime T: type) bool {
    return utils.matches(T, WS_EXTRACTOR_KEY);
}

pub fn extract(req: *Request) WebSocket {
    return .{ .req = req };
}

pub const WebSocket = struct {
    const Self = @This();

    key: []const u8 = WS_EXTRACTOR_KEY,
    req: *Request,

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

    pub fn onUpgrade(self: *const Self, handler: anytype, args: anytype) !void {
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
        const upg = self.req.upgradeRequested();
        switch (upg) {
            .websocket => |key| {
                if (key) |k| {
                    var ws = try self.req.respondWebSocket(.{ .key = k });
                    try ws.flush();
                    defer ws.flush() catch {};
                    var new_args: @Tuple(params) = undefined;
                    inline for (0..params.len) |i| {
                        if (i == params.len - 1) {
                            new_args[i] = &ws;
                        } else {
                            new_args[i] = args[i];
                        }
                    }
                    @call(.always_inline, handler, new_args) catch return error.WebSocketHandlerFailed;
                }
            },
            else => return error.NotWebSocketUpgrade,
        }
    }

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
