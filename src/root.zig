//! Public entrypoint for the Volt web library.
//!
//! Design intent:
//! - Keep control with application code.
//! - Make extraction and allocation choices explicit.
//! - Offer both automatic parameter injection and manual extraction from Context.
//! - Let applications drop down to `ctx.request` for lower-level protocol control
//!   when automatic extraction is not the right fit.
//!
//! Error behavior (important):
//! - If a handler or middleware returns an unhandled error, Volt responds with
//!   HTTP 500 and the error name as the plain-text response body.
//! - This is the only intentionally implicit runtime behavior, documented so
//!   applications can decide whether to keep it or map errors explicitly.

const std = @import("std");
const http = @import("http/root.zig");
const http_middleware = @import("http/middleware.zig");
const extract_mod = @import("extract/root.zig");
const middlewares_mod = @import("middlewares/root.zig");

pub const extract = struct {
    pub const Json = extract_mod.Json;
    pub const Query = extract_mod.Query;
    pub const TypedQuery = extract_mod.TypedQuery;
    pub const WebSocket = extract_mod.WebSocket;
    pub const WebSocketError = extract_mod.WebSocketError;
    pub const Header = extract_mod.Header;
    pub const RouteParam = extract_mod.RouteParam;
};

pub const middleware = struct {
    pub const Next = http_middleware.Next;
    pub const ConsoleLogger = middlewares_mod.ConsoleLogger;
};

pub const Server = http.Server;
pub const Context = http.Context;
pub const Response = http.Response;

test {
    const testing = @import("std").testing;
    _ = testing.refAllDecls(http);
    _ = testing.refAllDecls(extract_mod);
    _ = testing.refAllDecls(middlewares_mod);
}
