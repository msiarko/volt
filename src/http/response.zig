const std = @import("std");
const HttpStatus = std.http.Status;
const HttpRequest = std.http.Server.Request;
const WebSocket = @import("extractors").web_socket.WebSocket;
const HttpHeader = std.http.Header;

pub const Response = union(enum) {
    const Self = @This();

    web_socket: WebSocket,
    http: HttpResponse,

    fn into_http_response(
        arena: std.mem.Allocator,
        status: HttpStatus,
        content: []const u8,
        content_headers: []const HttpHeader,
        extra_headers: ?[]const HttpHeader,
    ) !Self {
        const headers = try std.mem.concat(
            arena,
            HttpHeader,
            &.{ content_headers, extra_headers orelse &.{} },
        );
        return .{
            .http = .{
                .status = status,
                .content = content,
                .headers = headers,
            },
        };
    }

    pub fn internal_server_error(
        arena: std.mem.Allocator,
        content: []const u8,
        extra_headers: ?[]const HttpHeader,
    ) !Self {
        return into_http_response(
            arena,
            .internal_server_error,
            content,
            &.{},
            extra_headers,
        );
    }

    pub fn json(
        arena: std.mem.Allocator,
        status: HttpStatus,
        content: []const u8,
        extra_headers: ?[]const HttpHeader,
    ) !Self {
        const content_headers: []const HttpHeader = &.{
            .{ .name = "Content-Type", .value = "application/json" },
        };

        return into_http_response(
            arena,
            status,
            content,
            content_headers,
            extra_headers,
        );
    }

    pub fn text(
        arena: std.mem.Allocator,
        status: HttpStatus,
        content: []const u8,
        extra_headers: ?[]const HttpHeader,
    ) !Self {
        const content_headers: []const HttpHeader = &.{
            .{ .name = "Content-Type", .value = "text/plain" },
        };

        return into_http_response(
            arena,
            status,
            content,
            content_headers,
            extra_headers,
        );
    }
};

const HttpResponse = struct {
    const Self = @This();

    status: HttpStatus,
    content: []const u8,
    headers: []const HttpHeader,

    fn into_response(self: Self, request: *HttpRequest) !void {
        return request.respond(self.content, .{
            .status = self.status,
            .extra_headers = self.headers,
        });
    }
};

pub fn respond(req: *HttpRequest, res: Response) !void {
    switch (res) {
        .web_socket => return,
        .http => |http| return http.into_response(req),
    }
}
