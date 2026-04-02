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

    pub fn body_as_json(self: *const @This(), comptime T: type) !std.json.Parsed(T) {
        if (self.http_req.head.content_length == null) return error.BodyLengthUnknown;
        if (self.http_req.head.content_type) |content_type| {
            if (!std.ascii.eqlIgnoreCase(content_type, "application/json")) return error.UnsupportedContentType;
        }

        if (self.http_req.head.method != .POST and
            self.http_req.head.method != .PUT and
            self.http_req.head.method != .PATCH)
        {
            return error.MethodNotAllowed;
        }

        const transfer_buffer = try self.allocator.alloc(u8, self.http_req.head.content_length.?);
        defer self.allocator.free(transfer_buffer);

        const reader = self.http_req.server.reader.bodyReader(
            transfer_buffer,
            self.http_req.head.transfer_encoding,
            self.http_req.head.content_length,
        );

        const data = try reader.readAlloc(self.allocator, self.http_req.head.content_length.?);
        defer self.allocator.free(data);

        return try std.json.parseFromSlice(T, self.allocator, data, .{});
    }

    pub fn upgradeWebsocket(self: *const @This()) !WebSocket {
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
