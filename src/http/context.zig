//! Request execution context for the Volt web library.
//!
//! The Context provides handlers with access to I/O operations and memory
//! allocators needed for processing HTTP requests. It separates persistent
//! allocations from request-scoped allocations using different allocators.

const std = @import("std");
const Request = std.http.Server.Request;

/// Execution context passed to all HTTP request handlers.
///
/// The Context provides the essential resources needed for request processing:
/// - I/O interface for network operations
/// - General-purpose allocator for persistent data
/// - Arena allocator for request-scoped temporary allocations
/// - Raw request pointer for manual extractor usage
///
/// This separation allows for efficient memory management where temporary
/// request data can be freed at the end of each request while persistent
/// data remains allocated.
///
/// **I/O:** All I/O operations within handlers and middleware must use `ctx.io`
/// rather than obtaining a separate I/O handle. This ensures correct participation
/// in the async event loop and proper cancellation support.
///
/// Example usage in a handler:
/// ```zig
/// fn myHandler(ctx: Context, state: *MyState) !Response {
///     // Automatic extraction via parameter type:
///     // fn myHandler(ctx: Context, state: *MyState, body: Json(MyStruct)) !Response
///
///     // Manual extraction for full control:
///     const body = extract.Json(MyStruct).fromContext(ctx);
///
///     // For lower-level control, use the raw request directly.
///     // This is useful when you want to manage protocol details yourself,
///     // such as custom WebSocket upgrade handling.
///     const req = ctx.request;
///     _ = req;
///
///     // Use ctx.server_allocator for data that must outlive the request
///     const persistent = try ctx.server_allocator.dupe(u8, some_data);
///     _ = persistent; // caller must free this
///
///     return Response.json(ctx.request_allocator, .ok, "success", null);
/// }
/// ```
pub const Context = struct {
    /// Compile-time marker used by the extractor system to identify request
    /// context types without a cross-module import. Do not use directly.
    pub const VOLT_REQUEST_CONTEXT = true;

    /// I/O interface for network operations and async I/O.
    io: std.Io,

    /// Allocator for persistent allocations that must outlive the request.
    /// Memory allocated here must be manually freed.
    server_allocator: std.mem.Allocator,

    /// Arena allocator scoped to the current request.
    /// All memory is freed automatically at the end of the request.
    /// Preferred for most handler operations.
    request_allocator: std.mem.Allocator,

    /// Raw HTTP request. Valid only for the lifetime of the current request.
    /// Use this to call extractors manually inside handler bodies, or to take
    /// lower-level control over request handling when you do not want Volt's
    /// automatic extraction path to perform work on your behalf.
    ///
    ///     const body = extract.Json(MyType).fromContext(ctx);
    ///     const q    = extract.Query("name").fromContext(ctx);
    ///
    /// For protocol-specific control, such as handling a WebSocket upgrade
    /// directly, operate on `ctx.request` yourself instead of using the
    /// automatic extractor.
    ///
    /// Do not store this pointer in state that outlives the request.
    request: *Request,
};
