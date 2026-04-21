const std = @import("std");
const HttpStatus = std.http.Status;
const HttpRequest = std.http.Server.Request;
const WebSocket = @import("extractors/WebSocket.zig");
const HttpHeader = std.http.Header;

/// Unified response type that can represent HTTP responses or WebSocket upgrades.
///
/// This union allows handlers to return either regular HTTP responses with
/// status codes, content, and headers, or trigger WebSocket upgrades.
///
/// Example:
/// ```zig
/// // HTTP JSON response
/// return Response.json(arena, .ok, "{\"message\": \"Hello\"}", null);
///
/// // WebSocket upgrade
/// return web_socket.intoResponse();
/// ```
pub const Response = union(enum) {
    const Self = @This();

    web_socket: ?WebSocket,
    http: HttpResponse,

    fn into_http_response(
        arena: std.mem.Allocator,
        status: HttpStatus,
        content: []const u8,
        content_headers: []const HttpHeader,
        extra_headers: ?[]const HttpHeader,
    ) !Self {
        const headers: []const HttpHeader = if (extra_headers) |eh|
            try std.mem.concat(arena, HttpHeader, &.{ content_headers, eh })
        else
            content_headers;
        return .{
            .http = .{ .status = status, .content = content, .headers = headers },
        };
    }

    /// Creates a 500 Internal Server Error response.
    ///
    /// Parameters:
    /// - `arena`: Allocator for response construction
    /// - `content`: Error message or content
    /// - `extra_headers`: Optional additional headers
    ///
    /// Returns: HTTP 500 response
    pub fn internal_server_error(
        arena: std.mem.Allocator,
        content: []const u8,
        extra_headers: ?[]const HttpHeader,
    ) !Self {
        return text(arena, .internal_server_error, content, extra_headers);
    }

    /// Creates a JSON response with appropriate Content-Type header.
    ///
    /// Parameters:
    /// - `arena`: Allocator for response construction
    /// - `status`: HTTP status code (e.g., .ok, .created)
    /// - `content`: JSON content as string
    /// - `extra_headers`: Optional additional headers
    ///
    /// Returns: HTTP response with JSON content type
    ///
    /// Example:
    /// ```zig
    /// return Response.json(arena, .ok, "{\"users\": []}", null);
    /// ```
    pub fn json(
        arena: std.mem.Allocator,
        status: HttpStatus,
        content: []const u8,
        extra_headers: ?[]const HttpHeader,
    ) !Self {
        const content_headers: []const HttpHeader = &.{
            .{ .name = "Content-Type", .value = "application/json" },
        };

        return into_http_response(arena, status, content, content_headers, extra_headers);
    }

    /// Creates a plain text response with appropriate Content-Type header.
    ///
    /// Parameters:
    /// - `arena`: Allocator for response construction
    /// - `status`: HTTP status code
    /// - `content`: Text content
    /// - `extra_headers`: Optional additional headers
    ///
    /// Returns: HTTP response with text content type
    ///
    /// Example:
    /// ```zig
    /// return Response.text(arena, .ok, "Hello, World!", null);
    /// ```
    pub fn text(
        arena: std.mem.Allocator,
        status: HttpStatus,
        content: []const u8,
        extra_headers: ?[]const HttpHeader,
    ) !Self {
        const content_headers: []const HttpHeader = &.{
            .{ .name = "Content-Type", .value = "text/plain" },
        };

        return into_http_response(arena, status, content, content_headers, extra_headers);
    }

    /// Creates a 200 OK response with optional content.
    ///
    /// Parameters:
    /// - `arena`: Allocator for response construction
    /// - `content`: Response body content, or null for empty body
    /// - `extra_headers`: Optional additional headers
    ///
    /// Returns: HTTP 200 OK response
    ///
    /// Example:
    /// ```zig
    /// return Response.ok(arena, "Operation successful", null);
    /// ```
    pub fn ok(arena: std.mem.Allocator, content: ?[]const u8, extra_headers: ?[]const HttpHeader) !Self {
        if (content) |c| {
            return text(arena, .ok, c, extra_headers);
        }

        return into_http_response(arena, .ok, &.{}, &.{}, extra_headers);
    }

    /// Creates an HTML response with appropriate Content-Type header.
    ///
    /// Parameters:
    /// - `arena`: Allocator for response construction
    /// - `status`: HTTP status code
    /// - `content`: HTML content
    /// - `extra_headers`: Optional additional headers
    ///
    /// Returns: HTTP response with HTML content type
    ///
    /// Example:
    /// ```zig
    /// return Response.html(arena, .ok, "<h1>Welcome</h1>", null);
    /// ```
    pub fn html(
        arena: std.mem.Allocator,
        status: HttpStatus,
        content: []const u8,
        extra_headers: ?[]const HttpHeader,
    ) !Self {
        const content_headers: []const HttpHeader = &.{
            .{ .name = "Content-Type", .value = "text/html" },
        };

        return into_http_response(arena, status, content, content_headers, extra_headers);
    }

    pub fn webSocket(web_socket: ?WebSocket) !Self {
        return .{ .web_socket = web_socket };
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

/// Sends a Response to the client, handling both HTTP and WebSocket responses.
///
/// This is the main entry point for sending responses in the Volt library.
/// For WebSocket responses, this function returns early (upgrade is handled
/// by the WebSocket extractor). For HTTP responses, it delegates to the
/// HttpResponse.into_response method.
///
/// Note:
/// - When a handler error is not handled by application code,
///   server-level fallback sends HTTP 500 with `@errorName(err)` as body.
///   See server execution path for that behavior.
///
/// Parameters:
/// - `req`: The HTTP request to respond to
/// - `res`: The response to send (HTTP or WebSocket)
///
/// Example:
/// ```zig
/// const response = Response.json(arena, .ok, "{\"status\": \"ok\"}", null);
/// try respond(req, response);
/// ```
pub fn respond(req: *HttpRequest, res: Response) !void {
    switch (res) {
        .web_socket => return,
        .http => |http| return http.into_response(req),
    }
}
