const std = @import("std");
const Request = @import("request.zig").Request;
const Context = @import("context.zig").Context;

pub fn Router(comptime State: type) type {
    return struct {
        allocator: std.mem.Allocator,
        routes: std.StringHashMap(RouteEntry),

        const VTable = struct {
            execute: *const fn (*const anyopaque, Context(State), Request) anyerror!void,
        };

        const Handler = struct {
            ptr: *const anyopaque,
            vtable: VTable,

            pub fn init(comptime HandlerFunction: type, h: *const anyopaque) @This() {
                const impl = struct {
                    fn exec(ptr: *const anyopaque, ctx: Context(State), req: Request) !void {
                        const hf = @typeInfo(HandlerFunction);
                        const func_params = @typeInfo(hf.pointer.child).@"fn".params;
                        comptime var func_param_types: [func_params.len]type = undefined;

                        inline for (func_params, 0..) |param_type, i| {
                            func_param_types[i] = param_type.type.?;
                        }

                        var params: @Tuple(&func_param_types) = undefined;

                        inline for (func_param_types, 0..) |param_type, i| {
                            if (param_type == Context(State)) params[i] = ctx;
                            if (param_type == Request) params[i] = req;
                        }

                        const fun: HandlerFunction = @ptrCast(@alignCast(ptr));
                        try @call(.auto, fun, params);
                    }
                };
                return .{
                    .ptr = h,
                    .vtable = .{
                        .execute = impl.exec,
                    },
                };
            }

            pub fn execute(self: *const Handler, ctx: Context(State), req: Request) !void {
                try self.vtable.execute(self.ptr, ctx, req);
            }
        };

        const RouteEntry = struct {
            handlers: std.AutoHashMap(std.http.Method, Handler),
        };

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .routes = .init(allocator),
            };
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

            comptime {
                var reqest_param_count: comptime_int = 0;
                for (func_type_info.@"fn".params) |param| {
                    if (param.type.? == Request) {
                        reqest_param_count += 1;
                    }
                }
                if (reqest_param_count == 0) {
                    @compileError("handler must take a Request parameter");
                }

                if (reqest_param_count > 1) {
                    @compileError("handler must take only one Request parameter");
                }
            }

            const RetType = func_type_info.@"fn".return_type.?;
            const ret_type_info = @typeInfo(RetType);
            if (ret_type_info != .error_union or ret_type_info.error_union.payload != void) {
                @compileError("handler must be a void-returning function");
            }

            return .init(FuncPtr, @ptrCast(handler));
        }
    };
}
