const std = @import("std");
const Allocator = std.mem.Allocator;
const HttpStatus = std.http.Status;
const HttpRequest = std.http.Server.Request;
const HttpHeader = std.http.Header;

const Attributes = struct {
    status: HttpStatus,
    content: []const u8,
    headers: []const HttpHeader = &.{},
};

const Self = @This();

attributes: ?Attributes,

fn intoHttpResponse(
    arena: Allocator,
    status: HttpStatus,
    content: []const u8,
    content_type: []const u8,
    extra_headers: ?[]const HttpHeader,
) !Self {
    const content_headers = [_]HttpHeader{
        .{ .name = "Content-Type", .value = content_type },
    };
    const headers: []const HttpHeader = if (extra_headers) |eh|
        try std.mem.concat(arena, HttpHeader, &.{ &content_headers, eh })
    else
        try arena.dupe(HttpHeader, &content_headers);

    return .{
        .attributes = .{
            .status = status,
            .content = content,
            .headers = headers,
        },
    };
}

/// Creates a 500 Internal Server Error response.
///
/// Parameters:
/// - `arena`: Allocator for response construction
/// - `content`: Error message or content
/// - `headers`: Optional additional headers
///
/// Returns: HTTP 500 response
pub fn internalServerError(
    arena: Allocator,
    content: []const u8,
    headers: ?[]const HttpHeader,
) !Self {
    return text(arena, .internal_server_error, content, headers);
}

/// Creates a JSON response with appropriate Content-Type header.
///
/// Parameters:
/// - `arena`: Allocator for response construction
/// - `status`: HTTP status code (e.g., .ok, .created)
/// - `content`: JSON content as string
/// - `headers`: Optional additional headers
///
/// Returns: HTTP response with JSON content type
///
/// Example:
/// ```zig
/// return Response.json(arena, .ok, "{\"users\": []}", null);
/// ```
pub fn json(
    arena: Allocator,
    status: HttpStatus,
    content: []const u8,
    headers: ?[]const HttpHeader,
) !Self {
    return intoHttpResponse(arena, status, content, "application/json", headers);
}

/// Creates a plain text response with appropriate Content-Type header.
///
/// Parameters:
/// - `arena`: Allocator for response construction
/// - `status`: HTTP status code
/// - `content`: Text content
/// - `headers`: Optional additional headers
///
/// Returns: HTTP response with text content type
///
/// Example:
/// ```zig
/// return Response.text(arena, .ok, "Hello, World!", null);
/// ```
pub fn text(
    arena: Allocator,
    status: HttpStatus,
    content: []const u8,
    extra_headers: ?[]const HttpHeader,
) !Self {
    return intoHttpResponse(arena, status, content, "text/plain", extra_headers);
}

/// Creates a 200 OK response with optional content.
///
/// Parameters:
/// - `arena`: Allocator for response construction
/// - `content`: Response body content, or null for empty body
/// - `headers`: Optional additional headers
///
/// Returns: HTTP 200 OK response
///
/// Example:
/// ```zig
/// return Response.ok(arena, "Operation successful", null);
/// ```
pub fn ok(arena: Allocator, content: ?[]const u8, headers: ?[]const HttpHeader) !Self {
    if (content) |c| {
        return text(arena, .ok, c, headers);
    }

    return intoHttpResponse(arena, .ok, &.{}, &.{}, headers);
}

/// Creates an HTML response with appropriate Content-Type header.
///
/// Parameters:
/// - `arena`: Allocator for response construction
/// - `status`: HTTP status code
/// - `content`: HTML content
/// - `headers`: Optional additional headers
///
/// Returns: HTTP response with HTML content type
///
/// Example:
/// ```zig
/// return Response.html(arena, .ok, "<h1>Welcome</h1>", null);
/// ```
pub fn html(
    arena: Allocator,
    status: HttpStatus,
    content: []const u8,
    headers: ?[]const HttpHeader,
) !Self {
    return intoHttpResponse(arena, status, content, "text/html", headers);
}

pub const empty: Self = .{ .attributes = null };

pub fn send(self: Self, req: *HttpRequest) !void {
    if (self.attributes) |info| {
        return req.respond(info.content, .{
            .status = info.status,
            .extra_headers = info.headers,
        });
    }
}
