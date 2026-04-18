const std = @import("std");
const Request = std.http.Server.Request;

/// Execution context passed to all HTTP request handlers.
///
/// The Context provides the essential resources needed for request processing:
/// - I/O interface for network operations
/// - Arena allocator for request-scoped temporary allocations
/// - Raw request pointer for manual extractor usage
///
/// Request-scoped data is freed automatically at the end of each request.
///
/// **I/O:** Request/connection I/O within handlers must use
/// `ctx.io` rather than obtaining a separate I/O handle. This ensures correct
/// participation in the async event loop and proper cancellation support.
/// Diagnostic logging may use `std.log`.
///
/// Example usage in a handler:
/// ```zig
/// fn myHandler(ctx: Context, state: *MyState) !Response {
///     // Automatic extraction via parameter type:
///     // fn myHandler(ctx: Context, state: *MyState, body: Json(MyStruct)) !Response
///
///     // Manual extraction for full control:
///     const body = try extract.Json(MyStruct).init(ctx);
///
///     // For lower-level control, use the raw request directly.
///     // This is useful when you want to manage protocol details yourself,
///     // such as custom WebSocket upgrade handling.
///     const req = ctx.request;
///     _ = req;
///
///     return Response.json(ctx.request_allocator, .ok, "success", null);
/// }
/// ```
pub const Context = struct {
    /// I/O interface for network operations and async I/O.
    io: std.Io,

    /// Arena allocator scoped to the current request.
    /// All memory is freed automatically at the end of the request.
    /// Preferred for most handler operations.
    request_allocator: std.mem.Allocator,

    /// Raw HTTP request. Valid only for the lifetime of the current request.
    /// Use this to call extractors manually inside handler bodies, or to take
    /// lower-level control over request handling when you do not want Volt's
    /// automatic extraction path to perform work on your behalf.
    ///
    ///     const body = try extract.Json(MyType).init(ctx);
    ///     const q    = try extract.Query("name").init(ctx);
    ///
    /// Do not store this pointer in state that outlives the request.
    request: *Request,

    /// Convenience initializer for constructing request context values.
    ///
    /// This keeps context construction explicit and stable for tests or
    /// custom integrations while matching the current struct shape.
    pub fn init(
        io: std.Io,
        request_allocator: std.mem.Allocator,
        request: *Request,
    ) Context {
        return .{
            .io = io,
            .request_allocator = request_allocator,
            .request = request,
        };
    }
};
