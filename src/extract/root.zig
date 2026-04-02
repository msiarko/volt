const std = @import("std");
const Allocator = std.mem.Allocator;
const Request = std.http.Server.Request;
const FnParam = std.builtin.Type.Fn.Param;

const json = @import("json.zig");
const web_socket = @import("web_socket.zig");
const query = @import("query.zig");
const typed_query = @import("typed_query.zig");
const header = @import("header.zig");
const route_param = @import("route_param.zig");

pub const Json = json.Json;
pub const WebSocket = web_socket.WebSocket;
pub const WebSocketError = web_socket.WebSocketError;
pub const Query = query.Query;
pub const TypedQuery = typed_query.TypedQuery;
pub const Header = header.Header;
pub const RouteParam = route_param.RouteParam;

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

pub inline fn resolveParams(
    comptime Func: type,
    comptime Values: type,
    request_allocator: Allocator,
    values: Values,
    route_pattern: ?[]const u8,
    req: *Request,
) Params(Func) {
    const func_params = comptime funcParams(Func);
    const func_param_types = comptime getParamsTypes(func_params);
    var params: Params(Func) = undefined;
    inline for (func_param_types, 0..func_params.len) |param_type, i| {
        if (comptime getFieldName(param_type, Values)) |n| {
            params[i] = @field(values, n);
        } else {
            comptime var resolved = false;
            inline for (extractor_resolvers) |Resolver| {
                if (!resolved and comptime Resolver.matches(param_type)) {
                    params[i] = Resolver.resolve(param_type, request_allocator, req);
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

const testing = std.testing;
const Server = std.http.Server;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const Context = @import("../http/context.zig").Context;

test "resolveParams resolves context field and extractor parameters" {
    const Handler = struct {
        fn f(
            ctx: Context,
            id: RouteParam("id"),
            name: Query("name"),
            x_request_id: Header("X-Request-Id"),
        ) void {
            _ = ctx;
            _ = id;
            _ = name;
            _ = x_request_id;
        }
    };

    const req_bytes = "GET /users/42?name=alice HTTP/1.1\r\nX-Request-Id: req-1\r\n\r\n";
    var stream_buf_reader = Reader.fixed(req_bytes);
    var write_buffer: [4096]u8 = undefined;
    var stream_buf_writer = Writer.fixed(&write_buffer);
    var http_server = Server.init(&stream_buf_reader, &stream_buf_writer);
    var http_req = try http_server.receiveHead();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const ctx: Context = .{
        .io = undefined,
        .request_allocator = arena.allocator(),
        .request = &http_req,
    };

    const values = .{ .ctx = ctx };
    const params = resolveParams(
        @TypeOf(&Handler.f),
        @TypeOf(values),
        arena.allocator(),
        values,
        "/users/:id",
        &http_req,
    );

    try testing.expectEqual(@intFromPtr(ctx.request), @intFromPtr(params[0].request));
    try testing.expectEqualStrings("42", params[1].value.?);
    try testing.expectEqualStrings("alice", (try params[2].result).?);
    try testing.expectEqualStrings("req-1", params[3].value.?);
}

test {
    _ = std.testing.refAllDecls(json);
    _ = std.testing.refAllDecls(web_socket);
    _ = std.testing.refAllDecls(query);
    _ = std.testing.refAllDecls(typed_query);
    _ = std.testing.refAllDecls(route_param);
    _ = std.testing.refAllDecls(header);
}
