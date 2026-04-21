//! Public entrypoint for the Volt web library.
//!
//! Design intent:
//! - Keep control with application code.
//! - Make extraction and allocation choices explicit.
//! - Offer both automatic parameter injection and manual extraction from Context.
//! - Let applications drop down to `ctx.raw_req` for lower-level protocol control
//!   when automatic extraction is not the right fit.
//!
//! Error behavior (important):
//! - If a handler returns an unhandled error, Volt responds with
//!   HTTP 500 and the error name as the plain-text response body.
//! - This is the only intentionally implicit runtime behavior, documented so
//!   applications can decide whether to keep it or map errors explicitly.

const std = @import("std");

const json = @import("extractors/json.zig");
const query = @import("extractors/query.zig");
const typed_query = @import("extractors/typed_query.zig");
const header = @import("extractors/header.zig");
const route_param = @import("extractors/route_param.zig");
const form = @import("extractors/form.zig");
const router = @import("router.zig");
const response = @import("response.zig");

pub const Server = @import("Server.zig");
pub const Context = @import("Context.zig");

pub const extract = struct {
    pub const Json = json.Json;
    pub const Query = query.Query;
    pub const TypedQuery = typed_query.TypedQuery;
    pub const WebSocket = @import("extractors/WebSocket.zig");
    pub const Header = header.Header;
    pub const RouteParam = route_param.RouteParam;
    pub const Form = form.Form;
};

pub const Router = router.Router;
pub const Response = response.Response;

test {
    const testing = std.testing;
    _ = testing.refAllDecls(json);
    _ = testing.refAllDecls(query);
    _ = testing.refAllDecls(typed_query);
    _ = testing.refAllDecls(header);
    _ = testing.refAllDecls(route_param);
    _ = testing.refAllDecls(form);
    _ = testing.refAllDecls(router);
    _ = testing.refAllDecls(response);
    _ = testing.refAllDecls(Server);
}
