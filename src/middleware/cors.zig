const std = @import("std");
const Context = @import("../core/Context.zig");
const Response = @import("../core/Response.zig");
const Next = @import("root.zig").Next;
const Middleware = @import("root.zig").Middleware;

pub const CorsConfig = struct {
    allowed_origins: []const []const u8 = &[_][]const u8{"*"},
    allowed_methods: []const []const u8 = &[_][]const u8{ "GET", "POST", "PUT", "DELETE", "HEAD", "OPTIONS", "PATCH" },
    allowed_headers: []const []const u8 = &[_][]const u8{ "Content-Type", "Authorization", "X-Request-ID" },
    max_age_seconds: ?usize = 86400,
    allow_credentials: bool = false,
};

pub const Cors = struct {
    config: CorsConfig = .{},

    pub fn init(config: CorsConfig) Cors {
        return .{ .config = config };
    }

    pub fn middleware(self: *const Cors) Middleware {
        return Middleware.fromStruct(Cors, self);
    }

    pub fn exec(self: *const Cors, ctx: *Context, next: *Next) anyerror!Response {
        const method = ctx.raw_req.head.method;
        if (method == .OPTIONS) {
            var res = Response.empty;
            res.attributes = .{
                .status = .no_content,
                .content = &.{},
                .headers = .empty,
            };
            try self.applyHeaders(ctx, &res);
            return res;
        }

        var res = try next.exec(ctx);
        try self.applyHeaders(ctx, &res);
        return res;
    }

    fn applyHeaders(self: *const Cors, ctx: *Context, res: *Response) !void {
        const origin = getHeader(ctx.raw_req, "Origin");
        if (origin) |req_origin| {
            var allowed = false;
            for (self.config.allowed_origins) |o| {
                if (std.mem.eql(u8, o, "*") or std.mem.eql(u8, o, req_origin)) {
                    allowed = true;
                    try res.setHeader(ctx.req_arena, "Access-Control-Allow-Origin", o);
                    break;
                }
            }
            if (!allowed and self.config.allowed_origins.len > 0) {
                return;
            }
        } else if (self.config.allowed_origins.len > 0) {
            try res.setHeader(ctx.req_arena, "Access-Control-Allow-Origin", self.config.allowed_origins[0]);
        }

        if (self.config.allow_credentials) {
            try res.setHeader(ctx.req_arena, "Access-Control-Allow-Credentials", "true");
        }

        if (ctx.raw_req.head.method == .OPTIONS) {
            if (self.config.allowed_methods.len > 0) {
                const methods_str = try std.mem.join(ctx.req_arena, ", ", self.config.allowed_methods);
                try res.setHeader(ctx.req_arena, "Access-Control-Allow-Methods", methods_str);
            }
            if (self.config.allowed_headers.len > 0) {
                const headers_str = try std.mem.join(ctx.req_arena, ", ", self.config.allowed_headers);
                try res.setHeader(ctx.req_arena, "Access-Control-Allow-Headers", headers_str);
            }
            if (self.config.max_age_seconds) |max_age| {
                const max_age_buf = try ctx.req_arena.print("{d}", .{max_age});
                try res.setHeader(ctx.req_arena, "Access-Control-Max-Age", max_age_buf);
            }
        }
    }

    fn getHeader(req: *const std.http.Server.Request, name: []const u8) ?[]const u8 {
        var it = req.iterateHeaders();
        while (it.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        }
        return null;
    }
};

/// Default CORS middleware function using standard permissive configuration.
pub fn cors(ctx: *Context, next: *Next) anyerror!Response {
    const default_cors: Cors = .{};
    return default_cors.exec(ctx, next);
}
