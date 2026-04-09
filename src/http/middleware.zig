const std = @import("std");
const Context = @import("context.zig").Context;
const Response = @import("response.zig").Response;

/// Factory function that creates a fresh middleware Entry.
/// Called once per request to instantiate a new middleware with isolated state.
/// Middleware instance storage is request-scoped; this function allocates the
/// middleware struct with `ctx.request_allocator`.
/// Context is passed so middleware can choose allocator strategy for any
/// additional internal allocations (request-scoped or server-wide).
pub const MiddlewareFactory = *const fn (ctx: *Context) anyerror!Entry;

pub const Entry = struct {
    ptr: *anyopaque,
    execute: *const fn (
        ptr: *anyopaque,
        next: *const Next,
    ) anyerror!Response,
    destroy: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,
};

pub const Next = struct {
    ptr: *const anyopaque,
    call: *const fn (ptr: *const anyopaque) anyerror!Response,

    pub fn run(self: *const Next) anyerror!Response {
        return self.call(self.ptr);
    }
};

pub const Terminal = struct {
    ptr: *const anyopaque,
    call: *const fn (ptr: *const anyopaque) anyerror!Response,
};

pub const Chain = struct {
    const Self = @This();
    const Allocator = std.mem.Allocator;

    allocator: Allocator,
    entries: std.ArrayList(Entry),

    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
            .entries = .empty,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.entries.items) |entry| {
            entry.destroy(entry.ptr, self.allocator);
        }
        self.entries.deinit(self.allocator);
    }

    /// Initializes a chain from a set of middleware factories.
    /// Each factory is called once to create a fresh middleware instance for this request.
    /// Middleware instance storage is request-scoped.
    /// Context still allows middleware internals to choose allocator strategy.
    /// Request/connection I/O inside middleware must use `ctx.io` to
    /// participate correctly in the async event loop.
    pub fn initFromFactories(ctx: *Context, factories: []const MiddlewareFactory) !Self {
        const allocator = ctx.request_allocator;
        var self = Chain.init(allocator);
        errdefer self.deinit();

        for (factories) |factory| {
            const entry = try factory(ctx);
            try self.entries.append(allocator, entry);
        }

        return self;
    }

    pub fn run(
        self: *Self,
        ctx: *Context,
        terminal: Terminal,
    ) anyerror!Response {
        const Runner = struct {
            const RunnerSelf = @This();

            chain: *Self,
            ctx: *Context,
            terminal: Terminal,

            const Cursor = struct {
                runner: *const RunnerSelf,
                index: usize,

                fn call(ptr: *const anyopaque) anyerror!Response {
                    const cursor_self: *const Cursor = @ptrCast(@alignCast(ptr));
                    return cursor_self.runner.runFrom(cursor_self.index);
                }
            };

            fn runFrom(runner_self: *const @This(), index: usize) anyerror!Response {
                if (index >= runner_self.chain.entries.items.len) {
                    return runner_self.terminal.call(runner_self.terminal.ptr);
                }

                const entry = runner_self.chain.entries.items[index];
                const cursor = Cursor{
                    .runner = runner_self,
                    .index = index + 1,
                };

                const next: Next = .{
                    .ptr = &cursor,
                    .call = Cursor.call,
                };

                return entry.execute(entry.ptr, &next);
            }
        };

        var runner = Runner{
            .chain = self,
            .ctx = ctx,
            .terminal = terminal,
        };

        return runner.runFrom(0);
    }

    fn isResponseErrorUnion(comptime T: type) bool {
        const info = @typeInfo(T);
        return info == .error_union and info.error_union.payload == Response;
    }

    fn validateMiddlewareType(comptime M: type) void {
        switch (@typeInfo(M)) {
            .@"struct" => {},
            else => @compileError("middleware must be a struct type"),
        }

        if (!@hasDecl(M, "handle")) {
            @compileError("middleware must define handle(self: *const Self, next: *const Next) !Response");
        }

        const Handle = @TypeOf(@field(M, "handle"));
        const info = @typeInfo(Handle);
        if (info != .@"fn") {
            @compileError("middleware handle must be a function declaration");
        }

        const params = info.@"fn".params;
        if (params.len != 2) {
            @compileError("middleware handle signature must be (self: *const Self, next: *const Next) !Response");
        }

        const p0 = params[0].type orelse @compileError("middleware handle contains an untyped parameter");
        const p1 = params[1].type orelse @compileError("middleware handle contains an untyped parameter");

        if (p0 != *const M) {
            @compileError("middleware handle first parameter must be self: *const Self");
        }

        if (p1 != *const Next) {
            @compileError("middleware handle second parameter must be next: *const Next");
        }

        const ret = info.@"fn".return_type orelse @compileError("middleware handle must return !Response");
        if (!isResponseErrorUnion(ret)) {
            @compileError("middleware handle must return !Response");
        }
    }

    /// Creates a factory function for the given middleware type M.
    /// The factory creates fresh instances of M for each request.
    /// Middleware must implement: init(ctx: *Context) !Self
    /// The middleware instance itself is always allocated with
    /// `ctx.request_allocator`.
    /// `init` receives Context so middleware can allocate and store additional
    /// internal data with either request or server lifetime as needed.
    pub fn makeFactory(comptime M: type) MiddlewareFactory {
        comptime validateMiddlewareType(M);
        comptime validateInitSignature(M);
        comptime validateOptionalDeinitSignature(M);

        return struct {
            fn factory(ctx: *Context) anyerror!Entry {
                const stored = try ctx.request_allocator.create(M);
                errdefer ctx.request_allocator.destroy(stored);

                stored.* = try @call(.auto, @field(M, "init"), .{ctx});

                return makeEntry(M, stored);
            }
        }.factory;
    }

    fn validateInitSignature(comptime M: type) void {
        if (!@hasDecl(M, "init")) {
            @compileError("middleware must define init(ctx: *Context) !Self");
        }

        const Init = @TypeOf(@field(M, "init"));
        const info = @typeInfo(Init);
        if (info != .@"fn") {
            @compileError("middleware init must be a function declaration");
        }

        const params = info.@"fn".params;
        if (params.len != 1) {
            @compileError("middleware init signature must be init(ctx: *Context) !Self");
        }

        const p0 = params[0].type orelse @compileError("middleware init contains an untyped parameter");
        if (p0 != *Context) {
            @compileError("middleware init first parameter must be ctx: *Context");
        }

        const ret = info.@"fn".return_type orelse @compileError("middleware init must return !Self");
        const ret_info = @typeInfo(ret);
        if (ret_info != .error_union) {
            @compileError("middleware init must return error union");
        }
        if (ret_info.error_union.payload != M) {
            @compileError("middleware init must return !Self (where Self is the middleware type)");
        }
    }

    fn validateOptionalDeinitSignature(comptime M: type) void {
        if (!@hasDecl(M, "deinit")) return;

        const Deinit = @TypeOf(@field(M, "deinit"));
        const info = @typeInfo(Deinit);
        if (info != .@"fn") {
            @compileError("middleware deinit must be a function declaration");
        }

        const params = info.@"fn".params;
        if (params.len != 2) {
            @compileError("middleware deinit signature must be deinit(self: *Self, allocator: std.mem.Allocator) void");
        }

        const p0 = params[0].type orelse @compileError("middleware deinit contains an untyped parameter");
        const p1 = params[1].type orelse @compileError("middleware deinit contains an untyped parameter");

        if (p0 != *M) {
            @compileError("middleware deinit first parameter must be self: *Self");
        }

        if (p1 != Allocator) {
            @compileError("middleware deinit second parameter must be allocator: std.mem.Allocator");
        }

        const ret = info.@"fn".return_type orelse @compileError("middleware deinit must return void");
        if (ret != void) {
            @compileError("middleware deinit must return void");
        }
    }

    fn makeEntry(comptime M: type, ptr: *M) Entry {
        comptime validateOptionalDeinitSignature(M);

        const Impl = struct {
            fn execute(raw_ptr: *anyopaque, next: *const Next) anyerror!Response {
                const self: *const M = @ptrCast(@alignCast(raw_ptr));
                return @call(.auto, @field(M, "handle"), .{ self, next });
            }

            fn destroy(raw_ptr: *anyopaque, allocator: Allocator) void {
                const self: *M = @ptrCast(@alignCast(raw_ptr));
                if (comptime @hasDecl(M, "deinit")) {
                    @call(.auto, @field(M, "deinit"), .{ self, allocator });
                }
                allocator.destroy(self);
            }
        };

        return .{
            .ptr = ptr,
            .execute = Impl.execute,
            .destroy = Impl.destroy,
        };
    }
};

test "Chain.deinit invokes middleware deinit callback" {
    const TrackingMiddleware = struct {
        const Self = @This();

        var deinit_count: usize = 0;

        pub fn handle(self: *const Self, next: *const Next) !Response {
            _ = self;
            return next.run();
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            _ = allocator;
            _ = self;
            deinit_count += 1;
        }
    };

    const mw = try std.testing.allocator.create(TrackingMiddleware);
    mw.* = .{};

    var chain = Chain.init(std.testing.allocator);
    try chain.entries.append(std.testing.allocator, Chain.makeEntry(TrackingMiddleware, mw));

    TrackingMiddleware.deinit_count = 0;
    chain.deinit();
    try std.testing.expectEqual(@as(usize, 1), TrackingMiddleware.deinit_count);
}

test "Chain.deinit destroys middleware without deinit method" {
    const PlainMiddleware = struct {
        const Self = @This();

        pub fn handle(self: *const Self, next: *const Next) !Response {
            _ = self;
            return next.run();
        }
    };

    const mw = try std.testing.allocator.create(PlainMiddleware);
    mw.* = .{};

    var chain = Chain.init(std.testing.allocator);
    try chain.entries.append(std.testing.allocator, Chain.makeEntry(PlainMiddleware, mw));

    // This would leak under std.testing.allocator if Chain.deinit didn't destroy entries.
    chain.deinit();
}
