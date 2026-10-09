const std = @import("std");
const Context = @import("../core/Context.zig");
const Response = @import("../core/Response.zig");
const Next = @import("root.zig").Next;

/// Built-in Panic / Error Recovery Middleware.
/// Intercepts unhandled errors returned from downstream handlers or middlewares,
/// logs the error details, and formats a structured 500 Internal Server Error response.
pub fn recovery(ctx: *Context, next: *Next) anyerror!Response {
    return next.exec(ctx) catch |err| {
        std.log.debug("Unhandled error intercepted by recovery middleware: {s}", .{@errorName(err)});
        return Response.text(ctx.req_arena, .internal_server_error, "Internal Server Error", null);
    };
}
