//! Automatic parameter extraction system for HTTP request handlers.
//!
//! This module provides the core infrastructure for automatically extracting
//! parameters from HTTP requests and injecting them into handler functions.
//! It uses compile-time reflection to identify extractor types (Json, WebSocket, Query)
//! and pass the appropriate values to handlers.

const std = @import("std");
const Request = std.http.Server.Request;
const Param = std.builtin.Type.Fn.Param;
const http = @import("http");
const Context = http.Context;
const json = @import("json.zig");
const web_socket = @import("web_socket.zig");
const query = @import("query.zig");

pub const Json = json.Json;
pub const WebSocket = web_socket.WebSocket;
pub const WebSocketError = web_socket.WebSocketError;
pub const Query = query.Query;

fn getParamsTypes(func_params: []const Param) []const type {
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

fn funcParams(comptime T: type) []const Param {
    const func_type_info = @typeInfo(T).pointer.child;
    return @typeInfo(func_type_info).@"fn".params;
}

/// Resolves handler function parameters from request context and extractors.
///
/// This function uses compile-time reflection to examine a handler function's
/// parameters and populate them with values from the provided context, state,
/// and request. It automatically detects and handles special types like Json and
/// WebSocket and Query through their respective extractors.
///
/// Parameters:
/// - `Func`: The handler function type to extract parameters for
/// - `Values`: A struct type containing context and state values
/// - `values`: The actual context and state values
/// - `req`: The HTTP request to extract data from
///
/// Returns: A tuple of resolved parameters matching the handler's signature
///
/// The resolution process:
/// 1. Examines the handler function's parameters
/// 2. Matches each parameter against available values
/// 3. For unmatched parameters, attempts to extract using registered extractors
/// 4. Returns a tuple of resolved values ready to pass to the handler
///
/// Example:
/// ```zig
/// fn myHandler(ctx: Context, state: *MyState, data: Json(MyType)) !Response {
///     // Parameters automatically resolved and injected
/// }
/// ```
pub inline fn resolveParams(comptime Func: type, comptime Values: type, values: Values, req: *Request) Params(Func) {
    const func_params = comptime funcParams(Func);
    const func_param_types = comptime getParamsTypes(func_params);
    var params: Params(Func) = undefined;
    const ctx_name = comptime getFieldName(Context, Values) orelse
        @compileError("no context field found in values");

    const ctx: Context = @field(values, ctx_name);
    inline for (func_param_types, 0..func_params.len) |param_type, i| {
        if (comptime getFieldName(param_type, Values)) |n| {
            params[i] = @field(values, n);
        } else if (comptime json.matches(param_type)) {
            const ExtractedType = json.Extracted(param_type);
            params[i] = json.Json(ExtractedType).init(ctx.request_allocator, req);
        } else if (comptime web_socket.matches(param_type)) {
            params[i] = web_socket.init(req);
        } else if (comptime query.matches(param_type)) {
            const param_name = comptime query.getParamName(param_type);
            params[i] = query.Query(param_name).init(req);
        } else {
            @compileError("unable to resolve parameter of type " ++ @typeName(param_type));
        }
    }

    return params;
}

test {
    _ = std.testing.refAllDecls(json);
}

test {
    _ = std.testing.refAllDecls(web_socket);
}

test {
    _ = std.testing.refAllDecls(query);
}
