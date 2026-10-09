const std = @import("std");
const Context = @import("../core/Context.zig");
const Response = @import("../core/Response.zig");
const Next = @import("root.zig").Next;

/// Built-in Logger Middleware.
/// Logs HTTP request method, path, and response status code using std.log.
pub fn logger(ctx: *Context, next: *Next) anyerror!Response {
    const method = ctx.raw_req.head.method;
    const target = ctx.raw_req.head.target;

    const res = next.exec(ctx) catch |err| {
        std.log.err("{s} {s} 500 error={s}", .{ @tagName(method), target, @errorName(err) });
        return err;
    };

    const status_code: u16 = if (res.attributes) |attr| @backingInt(attr.status) else 200;
    std.log.info("{s} {s} {d}", .{ @tagName(method), target, status_code });
    return res;
}
