const std = @import("std");
const Context = @import("../http/context.zig").Context;
const Response = @import("../http/response.zig").Response;
const Next = @import("../http/middleware.zig").Next;

/// Console logging middleware for HTTP requests.
///
/// Logs incoming requests with method, path, and HTTP protocol version.
/// Upon request completion, logs either the response status or error with processing duration.
///
/// **Important:** This middleware should be placed **first in the middleware chain**
/// for accurate request processing time measurements. Middleware registered before
/// ConsoleLogger will not be included in the logged duration.
///
/// Output uses ANSI colors for clarity:
/// - Requests are logged in cyan
/// - Responses are colorized by HTTP status class
///   - 2xx: green, 3xx: yellow, 4xx/5xx: red, 1xx: cyan
/// - Middleware/runtime errors are logged in red
///
/// Example:
/// ```zig
/// try router.use(ConsoleLogger);  // Register first
/// try router.use(OtherMiddleware);
/// ```
///
/// Output format:
/// - Request:  [CYAN]METHOD /path HTTP/1.1[RESET]
/// - Response: [GREEN]METHOD /path HTTP/1.1 -> STATUS (duration ms)[RESET]
/// - Error:    [RED]METHOD /path HTTP/1.1 -> ERROR: ErrorName (duration ms)[RESET]
pub const ConsoleLogger = struct {
    const Self = @This();

    method: []const u8,
    path: []const u8,
    http_version: []const u8,
    io: std.Io,

    pub fn init(ctx: *Context) !Self {
        const req = ctx.request;
        const method = req.head.method;
        const version = req.head.version;
        const method_str = @tagName(method);
        const http_version_str = formatHttpVersion(version);

        return .{
            .method = method_str,
            .path = normalizedTarget(req.head.target),
            .http_version = http_version_str,
            .io = ctx.io,
        };
    }

    fn normalizedTarget(target: []const u8) []const u8 {
        if (std.mem.findScalar(u8, target, '?')) |idx| {
            return target[0..idx];
        }

        return target;
    }

    pub fn handle(self: *const Self, next: *const Next) !Response {
        const start = std.Io.Timestamp.now(self.io, .awake);

        const response = next.run() catch |err| {
            const duration_ms = start.durationTo(std.Io.Timestamp.now(self.io, .awake)).toMilliseconds();
            logError(self.method, self.path, self.http_version, err, duration_ms);
            return err;
        };

        const duration_ms = start.durationTo(std.Io.Timestamp.now(self.io, .awake)).toMilliseconds();
        logResponse(self.method, self.path, self.http_version, response, duration_ms);

        return response;
    }

    fn logResponse(method: []const u8, path: []const u8, version: []const u8, response: Response, duration_ms: i64) void {
        const status_code, const color = switch (response) {
            .http => |http_resp| .{ @intFromEnum(http_resp.status), colorForStatusClass(http_resp.status.class()) },
            .web_socket => .{ 101, "\x1b[36m" }, // Switching Protocols (1xx)
        };
        const reset = "\x1b[0m";
        std.log.info("{s}{s} {s} {s} -> {d} ({d}ms){s}", .{ color, method, path, version, status_code, duration_ms, reset });
    }

    fn colorForStatusClass(class: std.http.Status.Class) []const u8 {
        return switch (class) {
            .informational => "\x1b[36m", // cyan
            .success => "\x1b[32m", // green
            .redirect => "\x1b[33m", // yellow
            .client_error, .server_error => "\x1b[31m", // red
        };
    }

    fn logError(method: []const u8, path: []const u8, version: []const u8, err: anyerror, duration_ms: i64) void {
        const error_name = @errorName(err);
        const red = "\x1b[31m";
        const reset = "\x1b[0m";
        std.log.err("{s}{s} {s} {s} -> ERROR: {s} ({d}ms){s}", .{ red, method, path, version, error_name, duration_ms, reset });
    }

    fn formatHttpVersion(version: std.http.Version) []const u8 {
        return switch (version) {
            .@"HTTP/1.0" => "HTTP/1.0",
            .@"HTTP/1.1" => "HTTP/1.1",
        };
    }
};
