const std = @import("std");
pub const json = @import("json.zig");
pub const web_socket = @import("web_socket.zig");

test "json" {
    _ = std.testing.refAllDecls(json);
}

test "web_socket" {
    _ = std.testing.refAllDecls(web_socket);
}
