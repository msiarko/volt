const std = @import("std");

pub const Context = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,

    pub fn init(io: std.Io, persistence: std.mem.Allocator, arena: std.mem.Allocator) @This() {
        return .{
            .arena = arena,
            .gpa = persistence,
            .io = io,
        };
    }
};
