const std = @import("std");
const HttpRequest = std.http.Server.Request;
const WebSocket = std.http.Server.WebSocket;

pub const Request = struct {
    allocator: std.mem.Allocator,
    http_req: *HttpRequest,

    pub fn getTarget(self: @This()) []const u8 {
        return self.http_req.head.target;
    }

    pub fn getMethod(self: @This()) std.http.Method {
        return self.http_req.head.method;
    }

    pub fn header(self: @This(), name: []const u8) ?[]const u8 {
        var it = self.http_req.iterateHeaders();
        while (it.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) {
                return h.value;
            }
        }
        return null;
    }

    pub fn upgradeWebsocket(self: @This()) !WebSocket {
        const upg = self.http_req.upgradeRequested();
        switch (upg) {
            .websocket => |key| {
                if (key) |k| {
                    const ws = try self.http_req.respondWebSocket(.{ .key = k });
                    try self.http_req.server.out.flush();
                    return ws;
                }
            },
            else => {},
        }

        return error.NotWebSocketRequest;
    }
};
