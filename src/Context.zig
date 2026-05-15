const std = @import("std");
const Allocator = std.mem.Allocator;
const Request = std.http.Server.Request;

const Self = @This();

/// I/O interface for network operations and async I/O.
io: std.Io,

/// Arena allocator scoped to the current request.
/// All memory is freed automatically at the end of the request.
/// Preferred for most handler operations.
req_arena: Allocator,

/// Raw HTTP request. Valid only for the lifetime of the current request.
/// Use this to call extractors manually inside handler bodies, or to take
/// lower-level control over request handling when you do not want Volt's
/// automatic extraction path to perform work on your behalf.
///
///     const body = try extract.Json(MyType).init(ctx);
///     const q    = try extract.Query("name").init(ctx);
///
/// Do not store this pointer in state that outlives the request.
raw_req: *Request,

/// The route pattern that matched this request, if any. This is used by some extractors like RouteParam.
route_pattern: ?[]const u8 = null,

/// Convenience initializer for constructing request context values.
///
/// This keeps context construction explicit and stable for tests or
/// custom integrations while matching the current struct shape.
pub fn init(
    io: std.Io,
    req_arena: Allocator,
    raw_req: *Request,
) Self {
    return .{
        .io = io,
        .req_arena = req_arena,
        .raw_req = raw_req,
    };
}
