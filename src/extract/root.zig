//! Automatic parameter extraction system for HTTP request handlers.
//!
//! This module provides the core infrastructure for automatically extracting
//! parameters from HTTP requests and injecting them into handler functions.
//! It uses compile-time reflection to identify extractor types (Json, WebSocket,
//! Query, TypedQuery, Header, and RouteParam) and pass appropriate values to handlers
//! through a compile-time resolver registry pattern.
//!
//! Design intent:
//! - Automatic extraction should remove boilerplate, not hide control.
//! - The same extractors are available manually via `fromContext` when handlers
//!   want explicit extraction order, branching, or custom error mapping.
//! - Handlers can mix styles: use automatic injection for simple cases and
//!   manual extraction from `Context` for request-specific control.
//! - For lower-level protocol handling, use `ctx.request` directly.

const std = @import("std");
const Request = std.http.Server.Request;
const FnParam = std.builtin.Type.Fn.Param;
const json = @import("json.zig");
const web_socket = @import("web_socket.zig");
const query = @import("query.zig");
const typed_query = @import("typed_query.zig");
const header = @import("header.zig");
const route_param = @import("route_param.zig");

/// Returns the name of the first field in V whose type carries the
/// `VOLT_REQUEST_CONTEXT` marker declaration. Used to locate the request
/// context inside the handler parameter tuple without importing `http`.
fn getContextFieldName(comptime V: type) ?[]const u8 {
    inline for (@typeInfo(V).@"struct".fields) |f| {
        if (@typeInfo(f.type) == .@"struct" and @hasDecl(f.type, "VOLT_REQUEST_CONTEXT")) {
            return f.name;
        }
    }
    return null;
}

pub const Json = json.Json;
pub const WebSocket = web_socket.WebSocket;
pub const WebSocketError = web_socket.WebSocketError;
pub const Query = query.Query;
pub const TypedQuery = typed_query.TypedQuery;
pub const Header = header.Header;
pub const RouteParam = route_param.RouteParam;

/// Compile-time collection of extractor resolvers.
///
/// Each resolver in this tuple must implement:
/// - `matches(comptime T: type) bool`: Returns true if resolver can build T
/// - `resolve(comptime T: type, allocator, req) T`: Builds T from request data
///
/// The `resolveParams` function iterates this collection to discover and dispatch
/// to the appropriate extractor for each handler parameter type.
const JsonResolver = json.Resolver;
const WebSocketResolver = web_socket.Resolver;
const QueryResolver = query.Resolver;
const TypedQueryResolver = typed_query.Resolver;
const HeaderResolver = header.Resolver;
const ParamResolver = route_param.Resolver;

const extractor_resolvers = .{
    JsonResolver,
    WebSocketResolver,
    QueryResolver,
    TypedQueryResolver,
    HeaderResolver,
};

fn getParamsTypes(func_params: []const FnParam) []const type {
    comptime var func_param_types: [func_params.len]type = undefined;
    inline for (func_params, 0..) |param_type, i| {
        func_param_types[i] = param_type.type.?;
    }

    return &func_param_types;
}

fn getFieldName(comptime T: type, comptime V: type) ?[]const u8 {
    inline for (@typeInfo(V).@"struct".fields) |f| {
        if (f.type == T) return f.name;
    }

    return null;
}

fn Params(comptime T: type) type {
    const func_params = funcParams(T);
    const func_param_types = getParamsTypes(func_params);
    return @Tuple(func_param_types);
}

fn funcParams(comptime T: type) []const FnParam {
    const func_type_info = @typeInfo(T).pointer.child;
    return @typeInfo(func_type_info).@"fn".params;
}

/// Resolves handler function parameters from request context and extract support.
///
/// This function uses compile-time reflection to examine a handler function's
/// parameters and populate them with values from the provided context, state,
/// and request. It automatically detects and handles special types like Json and
/// WebSocket and Query and TypedQuery through their respective extract types.
///
/// Parameters:
/// - `Func`: The handler function type to extract parameters for
/// - `Values`: A struct type containing context and state values
/// - `values`: The actual context and state values
/// - `route_pattern`: Matched route pattern (e.g., "/users/:id") or null for exact routes
/// - `req`: The HTTP request to extract data from
///
/// Returns: A tuple of resolved parameters matching the handler's signature
///
/// The resolution process:
/// 1. Examines the handler function's parameters
/// 2. Matches each parameter against available values
/// 3. For unmatched parameters, attempts to extract using registered extract types
/// 4. Returns a tuple of resolved values ready to pass to the handler
///
/// Example:
/// ```zig
/// fn myHandler(ctx: Context, state: *MyState, data: Json(MyType)) !Response {
///     // Parameters automatically resolved and injected
/// }
///
/// fn myHandlerManual(ctx: Context, state: *MyState) !Response {
///     // Same extractor, but invoked manually for more explicit control.
///     const data = Json(MyType).fromContext(ctx);
///     _ = state;
///     _ = data;
///     return Response.ok(ctx.request_allocator, null, null);
/// }
/// ```
pub inline fn resolveParams(
    comptime Func: type,
    comptime Values: type,
    request_allocator: std.mem.Allocator,
    values: Values,
    route_pattern: ?[]const u8,
    req: *Request,
) Params(Func) {
    const func_params = comptime funcParams(Func);
    const func_param_types = comptime getParamsTypes(func_params);
    var params: Params(Func) = undefined;
    const ctx_field = comptime getContextFieldName(Values);
    inline for (func_param_types, 0..func_params.len) |param_type, i| {
        if (comptime getFieldName(param_type, Values)) |n| {
            params[i] = @field(values, n);
        } else {
            comptime var resolved = false;
            inline for (extractor_resolvers) |Resolver| {
                if (!resolved and comptime Resolver.matches(param_type)) {
                    if (comptime ctx_field) |cf| {
                        if (comptime @hasDecl(Resolver, "resolveWithContext")) {
                            params[i] = Resolver.resolveWithContext(param_type, @field(values, cf));
                        } else {
                            params[i] = Resolver.resolve(param_type, request_allocator, req);
                        }
                    } else {
                        params[i] = Resolver.resolve(param_type, request_allocator, req);
                    }
                    resolved = true;
                }
            }

            if (!resolved and comptime ParamResolver.matches(param_type)) {
                params[i] = ParamResolver.resolve(param_type, request_allocator, route_pattern, req);
                resolved = true;
            }

            if (!resolved) {
                @compileError("unable to resolve parameter of type " ++ @typeName(param_type));
            }
        }
    }

    return params;
}

test {
    _ = std.testing.refAllDecls(json);
    _ = std.testing.refAllDecls(web_socket);
    _ = std.testing.refAllDecls(query);
    _ = std.testing.refAllDecls(typed_query);
    _ = std.testing.refAllDecls(route_param);
    _ = std.testing.refAllDecls(header);
}
