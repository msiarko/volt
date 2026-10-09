//! Public entrypoint for the Volt web library.
//!
//! Design intent:
//! - Keep control with application code.
//! - Make extraction and allocation choices explicit.
//! - Offer both automatic parameter injection and manual extraction from Context.
//! - Let applications drop down to `ctx.raw_req` for lower-level protocol control
//!   when automatic extraction is not the right fit.
//!
//! Error behavior (important):
//! - If a handler returns an unhandled error, Volt responds with
//!   HTTP 500 and the error name as the plain-text response body.
//! - This is the only intentionally implicit runtime behavior, documented so
//!   applications can decide whether to keep it or map errors explicitly.

/// HTTP server runtime that accepts connections and dispatches requests to a Router.
///
/// Example:
/// ```zig
/// const MyServer = Server;
///
/// Handlers should only allocate request-scoped memory with `ctx.req_arena`.
/// For state updates that require longer-lived allocations, store an allocator in
/// the state struct itself and free those allocations during your state deinit.
/// ```
pub const Server = @import("Server.zig");

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
/// fn myHandler(ctx: Context, state: MyState) !Response {
///     // Automatic extraction via parameter type:
///     // fn myHandler(ctx: Context, state: MyState, body: Json(MyStruct)) !Response
///
///     // Manual extraction for full control:
///     const body = try extract.Json(MyStruct).init(ctx);
///
///     // For lower-level control, use the raw request directly.
///     // This is useful when you want to manage protocol details yourself,
///     // such as custom WebSocket upgrade handling.
///     const req = ctx.raw_req;
///     _ = req;
///
///     return Response.json(ctx.req_arena, .ok, "success", null);
/// }
/// ```
pub const Context = @import("core/Context.zig");

/// HTTP response type used by handlers.
///
/// Use the helper constructors (`json`, `text`, `html`, `ok`,
/// `internal_server_error`) for standard HTTP responses.
///
/// For handlers that already responded directly (for example after a successful
/// WebSocket upgrade), return `Response.empty`.
///
/// Example:
/// ```zig
/// // HTTP JSON response
/// return Response.json(arena, .ok, "{\"message\": \"Hello\"}", null);
///
/// // For flows that already wrote to the socket (e.g. WebSocket upgrade)
/// return Response.empty;
/// ```
pub const Response = @import("core/Response.zig");

/// Creates a generic HTTP router type parameterized by application state.
///
/// The State type parameter allows handlers to access shared application state.
/// The router automatically resolves handler parameters from the request using
/// compile-time reflection and built-in extract support.
///
/// Example:
/// ```zig
/// const MyState = struct { db: Database };
/// const MyRouter = Router(MyState);
///
/// var router: MyRouter = .init(allocator, .{ .db = db });
/// defer router.deinit(allocator);
///
/// fn myHandler(ctx: Context, state: MyState, data: Json(MyStruct)) !Response {
///     // Parameters automatically extracted from request
///     _ = data; // JSON body deserialized to MyStruct
///     _ = state;
///     return Response.ok(ctx.req_arena, null, null);
/// }
///
/// try router.get(allocator, "/users", &myHandler);
///
/// // Stateless handlers for Router(void) should omit state entirely.
/// fn health(ctx: Context) !Response {
///     return Response.ok(ctx.req_arena, null, null);
/// }
/// ```
pub const Router = @import("router.zig").Router;

/// Extractors for request parameters, headers, and body content.
///
/// Example usage:
/// ```zig
/// fn myHandler(ctx: Context, state: MyState, data: Json(MyStruct)) !Response {
///     // Automatic extraction via parameter type:
///     // fn myHandler(ctx: Context, state: MyState, data: Json(MyStruct)) !Response
///     // Manual extraction for full control:
///     const data = try extract.Json(MyStruct).init(ctx);
///     return Response.ok(ctx.req_arena, null, null);
/// }
/// ```
pub const extract = @import("extract/root.zig");
pub const testing = @import("testing/client.zig");
pub const middleware = @import("middleware/root.zig");

test {
    const refAllDecls = @import("std").testing.refAllDecls;
    _ = refAllDecls(Server);
    _ = refAllDecls(@import("router.zig"));
    _ = refAllDecls(Context);
    _ = refAllDecls(Response);
    _ = refAllDecls(testing);
    _ = refAllDecls(middleware);
    _ = refAllDecls(extract);
}
