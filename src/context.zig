const std = @import("std");

pub fn Context(comptime State: type) type {
    return struct {
        io: std.Io,
        allocator: std.mem.Allocator,
        state: ?*State,

        pub fn init(allocator: std.mem.Allocator, io: std.Io, state: ?*State) @This() {
            return .{
                .allocator = allocator,
                .io = io,
                .state = state,
            };
        }
    };
}
