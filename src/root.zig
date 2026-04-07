const http = @import("http");
const extract_mod = @import("extract");

pub const extract = struct {
    pub const Json = extract_mod.Json;
    pub const Query = extract_mod.Query;
    pub const TypedQuery = extract_mod.TypedQuery;
    pub const WebSocket = extract_mod.WebSocket;
    pub const WebSocketError = extract_mod.WebSocketError;
};

pub const Server = http.Server;
pub const Context = http.Context;
pub const Response = http.Response;

pub fn webSocketResponse(ws: extract_mod.WebSocket) Response {
    return .{ .web_socket = ws };
}
