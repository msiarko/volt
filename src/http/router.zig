const std = @import("std");
const Request = std.http.Server.Request;
const Response = @import("response.zig").Response;
const Server = @import("server.zig").Server;
const Context = @import("context.zig").Context;
const ext = @import("extractors");
const json = ext.json;
const web_socket = ext.web_socket;
const Param = std.builtin.Type.Fn.Param;

pub fn Router(comptime State: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        routes: std.StringHashMap(RouteEntry),

        const VTable = struct {
            execute: *const fn (*const anyopaque, Context, *State, req: *Request) anyerror!Response,
        };

        const Handler = struct {
            ptr: *const anyopaque,
            vtable: VTable,

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

            fn resolveParams(comptime Func: type, comptime Values: type, values: Values, req: *Request) Params(Func) {
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
                        const Extracted = json.getExtractedType(param_type);
                        params[i] = json.Json(Extracted).extract(ctx.arena, req);
                    } else if (comptime web_socket.matches(param_type)) {
                        params[i] = web_socket.extract(req);
                    }
                }

                return params;
            }

            pub fn init(comptime HandlerFunction: type, h: *const anyopaque) @This() {
                const impl = struct {
                    fn exec(ptr: *const anyopaque, ctx: Context, state: *State, req: *Request) !Response {
                        const values = .{ ctx, state };
                        const params = resolveParams(HandlerFunction, @TypeOf(values), values, req);
                        const fun: HandlerFunction = @ptrCast(@alignCast(ptr));
                        return @call(.auto, fun, params);
                    }
                };

                return .{
                    .ptr = h,
                    .vtable = .{
                        .execute = impl.exec,
                    },
                };
            }

            pub fn execute(self: *const Handler, ctx: Context, state: *State, req: *Request) !Response {
                return self.vtable.execute(self.ptr, ctx, state, req);
            }
        };

        const RouteEntry = struct {
            handlers: std.AutoHashMap(std.http.Method, Handler),
        };

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator, .routes = .init(allocator) };
        }

        pub fn deinit(self: *Self) void {
            var it = self.routes.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.handlers.deinit();
            }

            self.routes.deinit();
        }

        fn addRoute(self: *Self, method: std.http.Method, path: []const u8, handler: Handler) !void {
            var res = try self.routes.getOrPut(path);
            if (!res.found_existing) {
                res.value_ptr.* = .{
                    .handlers = .init(self.allocator),
                };
            }

            try res.value_ptr.handlers.put(method, handler);
        }

        pub fn get(self: *Self, path: []const u8, handler: anytype) !void {
            try self.addRoute(.GET, path, makeHandler(handler));
        }

        pub fn post(self: *Self, path: []const u8, handler: anytype) !void {
            try self.addRoute(.POST, path, makeHandler(handler));
        }

        pub fn put(self: *Self, path: []const u8, handler: anytype) !void {
            try self.addRoute(.PUT, path, makeHandler(handler));
        }

        pub fn delete(self: *Self, path: []const u8, handler: anytype) !void {
            try self.addRoute(.DELETE, path, makeHandler(handler));
        }

        pub fn patch(self: *Self, path: []const u8, handler: anytype) !void {
            try self.addRoute(.PATCH, path, makeHandler(handler));
        }

        fn makeHandler(handler: anytype) Handler {
            const FuncPtr = @TypeOf(handler);
            const func_ptr_info = @typeInfo(FuncPtr);
            if (func_ptr_info != .pointer or !func_ptr_info.pointer.is_const) {
                @compileError("handler must be a const pointer type");
            }

            const func_type_info = @typeInfo(func_ptr_info.pointer.child);
            if (func_type_info != .@"fn") {
                @compileError("handler must be a const pointer type to a function");
            }

            const RetType = func_type_info.@"fn".return_type.?;
            const ret_type_info = @typeInfo(RetType);
            if (ret_type_info != .error_union or ret_type_info.error_union.payload != Response) {
                @compileError("handler must return !Response");
            }

            return .init(FuncPtr, @ptrCast(handler));
        }
    };
}
