const std = @import("std");
const Context = @import("../core/Context.zig");
const Response = @import("../core/Response.zig");
const Next = @import("root.zig").Next;

var request_counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(1);

/// Built-in Request ID Middleware.
/// Generates a unique monotonic request identifier, attaches it to `ctx.request_id`,
/// and sets the `X-Request-ID` HTTP header on the response.
pub fn requestId(ctx: *Context, next: *Next) anyerror!Response {
    const count = request_counter.fetchAdd(1, .monotonic);
    const req_id = try ctx.req_arena.print("req-{d}", .{count});

    ctx.request_id = req_id;

    var res = try next.exec(ctx);
    try res.setHeader(ctx.req_arena, "X-Request-ID", req_id);
    return res;
}
