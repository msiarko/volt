const Context = @import("../core/Context.zig");
/// Creates a `Json` extractor type.
///
/// The resulting extractor struct contains:
/// - `value`: `T`
///
/// `init` is successful when request validation and JSON parsing succeed.
/// Validation requires:
/// - a method that supports request bodies,
/// - `Content-Type: application/json`,
/// - a non-zero `Content-Length`,
/// - and a valid JSON body that matches `T`.
///
/// The extractor can be used either:
/// - as a router handler parameter (automatic injection), or
/// - manually inside a handler body with `try Json(T).init(ctx)`.
///
/// ```zig
/// const Person = struct {
///     name: []const u8,
///     age: u7,
/// };
///
/// fn handleRequest(ctx: Context, person: Json(Person)) !Response {
///     const payload = person.value;
///
///     _ = payload;
///     return Response.ok(ctx.req_arena, null, null);
/// }
/// ```
pub const Json = @import("json.zig").Json;

/// Creates a `Query` extractor type for a single query parameter.
///
/// The resulting extractor struct contains:
/// - `value`: `?[]const u8`
///
/// `value` semantics:
/// - `null`: query string missing, parameter missing, or parameter present with an empty value
/// - `[]const u8`: decoded parameter value
///
/// Parameter-name matching is case-insensitive and compares against the decoded key.
/// The extractor can be used either:
/// - as a router handler parameter (automatic injection), or
/// - manually inside a handler body with `try Query(name).init(ctx)`.
///
/// ```zig
/// fn handleRequest(ctx: Context, filter: Query("filter")) !Response {
///     const maybe_filter = filter.value;
///
///     _ = maybe_filter;
///     return Response.ok(ctx.req_arena, null, null);
/// }
/// ```
pub const Query = @import("query.zig").Query;

/// Creates a `TypedQuery` extractor type.
///
/// `T` must be a struct where every field is optional.
/// Field names are matched case-insensitively against query keys.
///
/// The resulting extractor struct contains:
/// - `value`: `?*T`
///
/// `value` semantics:
/// - `null`: request target has no query string
/// - `*T`: allocated struct with each field set from matching query keys (unmatched fields are `null`)
///
/// The extractor can be used either:
/// - as a router handler parameter (automatic injection), or
/// - manually inside a handler body with `try TypedQuery(T).init(ctx)`.
///
/// ```zig
/// const Filter = struct {
///     name: ?[]const u8,
///     age: ?u8,
/// };
///
/// fn handleRequest(ctx: Context, filter: TypedQuery(Filter)) !Response {
///     const maybe_filter = filter.value;
///
///     _ = maybe_filter;
///     return Response.ok(ctx.req_arena, null, null);
/// }
/// ```
pub const TypedQuery = @import("typed_query.zig").TypedQuery;

/// Creates a `WebSocket` extractor.
///
/// The extractor struct contains:
/// - `socket`: `Socket`
///
/// On success, the HTTP request is upgraded and a connected socket is available.
///
/// The extractor can be used either:
/// - as a router handler parameter (automatic injection), or
/// - manually inside a handler body with `try WebSocket.init(ctx)`.
///
/// In handlers, call `onConnected` to run your connection routine, then return `Response.empty`.
///
/// ```zig
/// fn handleRequest(ctx: Context, ws: WebSocket) !Response {
///     try ws.onConnected(handleWebSocket, .{ ctx });
///     return Response.empty;
/// }
/// ```
pub const WebSocket = @import("WebSocket.zig");

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
pub const Header = @import("header.zig").Header;

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
pub const RouteParam = @import("route_param.zig").RouteParam;

/// Creates a `Form` extractor type
///
/// The resulting extractor struct contains:
/// - `data`: `*T`
///
/// `init` is successful when parsing succeeds (e.g., valid multipart body, valid percent-encoding, supported content type, successful allocation, etc.)
/// `T` is the decoded form value of type `T`, where `T` is a struct with fields corresponding to form keys.
///
/// Parameter-name matching is case-insensitive and compares against the decoded key.
/// Value decoding is single-pass (`+` -> space, `%XX` escapes decoded once).
///
/// The extractor can be used either:
/// - as a router handler parameter (automatic injection), or
/// - manually inside a handler body with `try Form(T).init(ctx)`.
///
/// ```zig
/// fn handleRequest(ctx: Context, form: Form(Person)) !Response {
///     const form_data = form.data;
///
///     _ = form_data;
///     return Response.ok(ctx.req_arena, null, null);
/// }
/// ```
pub const Form = @import("form.zig").Form;

const method_name = "init";

pub fn isExtractor(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (@hasDecl(T, method_name)) {
        const info = @typeInfo(@TypeOf(@field(T, method_name)));
        if (info != .@"fn") return false;
        const init = info.@"fn";
        const Ret = init.return_type orelse return false;
        const ret_info = @typeInfo(Ret);
        return info == .@"fn" and
            init.param_types.len == 1 and
            init.param_types[0] == Context and
            ret_info.error_union.payload == T;
    }

    return false;
}

test "extractor returns true for a struct with a fromContext method and returns Extractor type" {
    const std = @import("std");

    const TestExtractor = struct {
        pub fn init(ctx: Context) !@This() {
            _ = ctx;
            return .{};
        }
    };

    try std.testing.expect(isExtractor(TestExtractor));
}

test "extractor returns false for a struct without a fromContext method" {
    const std = @import("std");

    const NonExtractor = struct {
        pub fn someOtherMethod() void {}
    };

    try std.testing.expect(!isExtractor(NonExtractor));
}

test "extractor returns false if fromContext return type that is not an extractor itself" {
    const std = @import("std");

    const NonExtractor = struct {
        pub fn fromContext(ctx: Context) !u8 {
            _ = ctx;
            return 5;
        }
    };

    try std.testing.expect(!isExtractor(NonExtractor));
}

test {
    const refAllDecls = @import("std").testing.refAllDecls;
    _ = refAllDecls(@import("json.zig"));
    _ = refAllDecls(@import("query.zig"));
    _ = refAllDecls(@import("typed_query.zig"));
    _ = refAllDecls(@import("header.zig"));
    _ = refAllDecls(@import("route_param.zig"));
    _ = refAllDecls(@import("form.zig"));
    _ = refAllDecls(@import("WebSocket.zig"));
    _ = refAllDecls(@import("QueryIterator.zig"));
    _ = refAllDecls(@import("url.zig"));
}
