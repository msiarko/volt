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

const std = @import("std");

const json = @import("extractors/json.zig");
const query = @import("extractors/query.zig");
const typed_query = @import("extractors/typed_query.zig");
const header = @import("extractors/header.zig");
const route_param = @import("extractors/route_param.zig");
const form = @import("extractors/form.zig");
const router = @import("router.zig");
const response = @import("response.zig");

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
pub const Context = @import("Context.zig");

pub const extract = struct {
    /// Creates a `Json` extractor type.
    ///
    /// The resulting extractor struct contains:
    /// - `result`: `JsonError!T`
    ///
    /// `result` is successful when request validation and JSON parsing succeed.
    /// Validation requires:
    /// - a method that supports request bodies,
    /// - `Content-Type: application/json`,
    /// - a non-zero `Content-Length`,
    /// - and a valid JSON body that matches `T`.
    ///
    /// The extractor can be used either:
    /// - as a router handler parameter (automatic injection), or
    /// - manually inside a handler body with `Json(T).init(ctx)`.
    ///
    /// ```zig
    /// const Person = struct {
    ///     name: []const u8,
    ///     age: u7,
    /// };
    ///
    /// fn handleRequest(ctx: Context, person: Json(Person)) !Response {
    ///     const payload = person.result catch |e| {
    ///         _ = e;
    ///         // Handle JSON or validation error.
    ///         return Response.badRequest();
    ///     };
    ///
    ///     _ = ctx;
    ///     _ = payload;
    ///     return Response.ok();
    /// }
    /// ```
    pub const Json = json.Json;

    /// Creates a `Query` extractor type for a single query parameter.
    ///
    /// The resulting extractor struct contains:
    /// - `result`: `QueryError!?[]const u8`
    ///
    /// `result` semantics:
    /// - `error`: malformed percent-encoding or allocator failure while decoding
    /// - `null`: query string missing, parameter missing, or parameter present with an empty value
    /// - `[]const u8`: decoded parameter value
    ///
    /// Parameter-name matching is case-insensitive and compares against the decoded key.
    /// The extractor can be used either:
    /// - as a router handler parameter (automatic injection), or
    /// - manually inside a handler body with `Query(name).init(ctx)`.
    ///
    /// ```zig
    /// fn handleRequest(ctx: Context, filter: Query("filter")) !Response {
    ///     const maybe_filter = filter.result catch |e| {
    ///         _ = e;
    ///         return Response.badRequest();
    ///     };
    ///
    ///     _ = ctx;
    ///     _ = maybe_filter;
    ///     return Response.ok();
    /// }
    /// ```
    pub const Query = query.Query;

    /// Creates a `TypedQuery` extractor type.
    ///
    /// `T` must be a struct where every field is optional.
    /// Field names are matched case-insensitively against query keys.
    ///
    /// The resulting extractor struct contains:
    /// - `result`: `QueryError!?*T`
    ///
    /// `result` semantics:
    /// - `error`: malformed percent-encoding or allocator failure
    /// - `null`: request target has no query string
    /// - `*T`: allocated struct with each field set from matching query keys (unmatched fields are `null`)
    ///
    /// The extractor can be used either:
    /// - as a router handler parameter (automatic injection), or
    /// - manually inside a handler body with `TypedQuery(T).init(ctx)`.
    ///
    /// ```zig
    /// const Filter = struct {
    ///     name: ?[]const u8,
    ///     age: ?u8,
    /// };
    ///
    /// fn handleRequest(ctx: Context, filter: TypedQuery(Filter)) !Response {
    ///     const maybe_filter = filter.result catch |e| {
    ///         _ = e;
    ///         return Response.badRequest();
    ///     };
    ///
    ///     _ = ctx;
    ///     _ = maybe_filter;
    ///     return Response.ok();
    /// }
    /// ```
    pub const TypedQuery = typed_query.TypedQuery;

    /// Creates a `WebSocket` extractor.
    ///
    /// The extractor struct contains:
    /// - `result`: `WebSocketError!Socket`
    ///
    /// On success, the HTTP request is upgraded and a connected socket is available.
    ///
    /// The extractor can be used either:
    /// - as a router handler parameter (automatic injection), or
    /// - manually inside a handler body with `WebSocket{ .result = WebSocket.init(ctx) }`.
    ///
    /// In handlers, call `onConnected` to run your connection routine, then return `intoResponse()`.
    ///
    /// ```zig
    /// fn handleRequest(ctx: Context, ws: WebSocket) !Response {
    ///     try ws.onConnected(handleWebSocket, .{ ctx });
    ///     return ws.intoResponse();
    /// }
    /// ```
    pub const WebSocket = @import("extractors/WebSocket.zig");

    /// Creates a Header extractor type for a specific HTTP header name.
    ///
    /// Fields:
    /// - `value` An optional slice of bytes that contains the value of the header if it is present in the request,
    /// or `null` if the header is absent
    ///
    /// Header name comparison is case-insensitive.
    ///
    /// Example usage in a router handler:
    /// ```zig
    /// fn handleRequest(ctx: Context, auth: Header("Authorization")) !Response {
    ///     const token = auth.value orelse return Response.unauthorized();
    ///     // Use token...
    /// }
    ///
    /// fn handleRequest(ctx: Context) !Response {
    ///     const auth = try Header("Authorization").init(ctx);
    ///     const token = auth.value orelse return Response.unauthorized();
    ///     // Use token...
    /// }
    /// ```
    pub const Header = header.Header;

    /// Creates a 'RouteParam' extractor type
    ///
    /// Fields:
    /// - `value`: An optional slice of bytes that contains the value of the route parameter if it is present in the request, or `null` if the parameter is absent.
    ///
    /// The extractor can be used only as a router handler parameter (automatic injection), or
    ///
    /// ```zig
    /// fn handleRequest(ctx: Context, id: RouteParam("id")) !Response {
    ///    if (id.value) |id_value| {
    ///       // Use id_value...
    ///    }
    /// }
    /// ```
    pub const RouteParam = route_param.RouteParam;

    /// Creates a `Form` extractor type
    ///
    /// The resulting extractor struct contains:
    /// - `result`: `FormError!*T`
    ///
    /// `result` semantics:
    /// - `error`: parsing error (e.g., malformed multipart body, invalid percent-encoding, unsupported content type, allocator failure, etc.)
    /// - `T`: decoded form value of type `T`, where `T` is a struct with fields corresponding to form keys
    ///
    /// Parameter-name matching is case-insensitive and compares against the decoded key.
    /// Value decoding is single-pass (`+` -> space, `%XX` escapes decoded once).
    ///
    /// The extractor can be used either:
    /// - as a router handler parameter (automatic injection), or
    /// - manually inside a handler body with `Form(T).init(ctx)`.
    ///
    /// ```zig
    /// fn handleRequest(ctx: Context, form: Form(Person)) !Response {
    ///     const form_data = form.result catch |e| {
    ///         _ = e;
    ///         return Response.badRequest();
    ///     };
    ///
    ///     _ = ctx;
    ///     _ = form_data;
    ///     return Response.ok();
    /// }
    /// ```
    pub const Form = form.Form;
};

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
pub const Router = router.Router;

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
pub const Response = response.Response;

test {
    const testing = std.testing;
    _ = testing.refAllDecls(json);
    _ = testing.refAllDecls(query);
    _ = testing.refAllDecls(typed_query);
    _ = testing.refAllDecls(header);
    _ = testing.refAllDecls(route_param);
    _ = testing.refAllDecls(form);
    _ = testing.refAllDecls(router);
    _ = testing.refAllDecls(response);
    _ = testing.refAllDecls(Server);
}
