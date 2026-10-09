const std = @import("std");
const Context = @import("../core/Context.zig");
const Response = @import("../core/Response.zig");
const isExtractor = @import("../extract/root.zig").isExtractor;

pub const logger = @import("logger.zig").logger;
pub const cors = @import("cors.zig").cors;
pub const Cors = @import("cors.zig").Cors;
pub const CorsConfig = @import("cors.zig").CorsConfig;
pub const recovery = @import("recovery.zig").recovery;
pub const requestId = @import("request_id.zig").requestId;

/// Execution continuation interface for middleware pipeline.
/// Call `next.exec(ctx)` to yield control to the next middleware or final route handler.
pub const Next = struct {
    ptr: *const anyopaque,
    exec_fn: *const fn (ptr: *const anyopaque, ctx: *Context) anyerror!Response,

    pub fn exec(self: *Next, ctx: *Context) anyerror!Response {
        return self.exec_fn(self.ptr, ctx);
    }
};

/// Type-erased middleware wrapper supporting function pointers and struct instances.
pub const Middleware = struct {
    ptr: *const anyopaque,
    exec_fn: *const fn (ptr: *const anyopaque, ctx: *Context, next: *Next) anyerror!Response,

    pub fn execute(self: Middleware, ctx: *Context, next: *Next) anyerror!Response {
        return self.exec_fn(self.ptr, ctx, next);
    }

    pub fn fromFn(comptime func: anytype) Middleware {
        return makeMiddleware(func);
    }

    pub fn fromStruct(comptime T: type, instance_ptr: *const T) Middleware {
        return makeMiddleware(instance_ptr);
    }
};

/// Converts any valid middleware representation (stateless function or stateful struct pointer)
/// into a uniform `Middleware` wrapper.
pub fn makeMiddleware(mw: anytype) Middleware {
    const T = @TypeOf(mw);
    if (T == Middleware) return mw;

    const info = @typeInfo(T);
    const FnType: ?type = if (info == .@"fn")
        T
    else if (info == .pointer and @typeInfo(info.pointer.child) == .@"fn")
        info.pointer.child
    else
        null;

    if (FnType) |Fn| {
        const field_types = @typeInfo(std.meta.ArgsTuple(Fn)).@"struct".field_types;
        if (field_types.len != 2) {
            @compileError("Middleware function must accept 2 parameters: (ctx: *Context, next: *Next)");
        }
        const P0 = field_types[0];
        const impl = struct {
            fn exec(ptr: *const anyopaque, ctx: *Context, next: *Next) anyerror!Response {
                const func: *const Fn = @ptrCast(@alignCast(ptr));
                if (P0 == *Context) {
                    return func(ctx, next);
                } else if (P0 == Context) {
                    return func(ctx.*, next);
                } else {
                    @compileError("First parameter of middleware function must be *Context or Context");
                }
            }
        };

        const fn_ptr: *const Fn = if (info == .pointer) mw else &mw;
        return .{
            .ptr = @ptrCast(fn_ptr),
            .exec_fn = impl.exec,
        };
    } else if (info == .pointer and @typeInfo(info.pointer.child) == .@"struct") {
        const Child = info.pointer.child;
        if (!@hasDecl(Child, "exec")) {
            @compileError("Middleware struct " ++ @typeName(Child) ++ " must declare an 'exec' method");
        }
        const impl = struct {
            fn exec(ptr: *const anyopaque, ctx: *Context, next: *Next) anyerror!Response {
                const self_ptr: *const Child = @ptrCast(@alignCast(ptr));
                return self_ptr.exec(ctx, next);
            }
        };
        return .{
            .ptr = @ptrCast(mw),
            .exec_fn = impl.exec,
        };
    } else if (info == .@"struct") {
        if (!@hasDecl(T, "exec")) {
            @compileError("Middleware struct " ++ @typeName(T) ++ " must declare an 'exec' method");
        }
        const impl = struct {
            fn exec(ptr: *const anyopaque, ctx: *Context, next: *Next) anyerror!Response {
                _ = ptr;
                return mw.exec(ctx, next);
            }
        };
        return .{
            .ptr = undefined,
            .exec_fn = impl.exec,
        };
    }

    @compileError("Invalid middleware type: " ++ @typeName(T) ++ ". Expected function 'fn(*Context, *Next) !Response', struct pointer, or struct value with 'exec' method.");
}

/// Comptime-chains a tuple of middlewares and a final handler into a statically dispatched handler.
pub fn Chain(comptime State: type, comptime mws: anytype, comptime handler: anytype) type {
    return struct {
        pub fn exec(ctx: Context, state: State) anyerror!Response {
            var mutable_ctx = ctx;
            return step(0, &mutable_ctx, state);
        }

        fn step(comptime index: usize, ctx: *Context, state: State) anyerror!Response {
            if (comptime index < mws.len) {
                const StepNext = struct {
                    fn exec(ptr: *const anyopaque, c: *Context) anyerror!Response {
                        const s_ptr: *const State = @ptrCast(@alignCast(ptr));
                        return step(index + 1, c, s_ptr.*);
                    }
                };
                var nxt = Next{
                    .ptr = &state,
                    .exec_fn = StepNext.exec,
                };
                const mw_impl = makeMiddleware(mws[index]);
                return mw_impl.execute(ctx, &nxt);
            }

            // Call final handler statically
            const Fn = @TypeOf(handler);
            var args: std.meta.ArgsTuple(Fn) = undefined;
            const type_info = @typeInfo(std.meta.ArgsTuple(Fn));
            const field_types = type_info.@"struct".field_types;
            inline for (field_types, 0..field_types.len) |field_type, i| {
                switch (field_type) {
                    Context => args[i] = ctx.*,
                    State => args[i] = state,
                    else => |Arg| {
                        if (comptime isExtractor(Arg)) {
                            args[i] = Arg.fromContext(ctx.*);
                        } else {
                            @compileError("unable to resolve parameter of type " ++ @typeName(field_type));
                        }
                    },
                }
            }
            return @call(.auto, handler, args);
        }
    };
}

test {
    const refAllDecl = std.testing.refAllDecls;
    _ = refAllDecl(@import("logger.zig"));
    _ = refAllDecl(@import("cors.zig"));
    _ = refAllDecl(@import("recovery.zig"));
    _ = refAllDecl(@import("request_id.zig"));
}
