//! Utility functions for extractor type identification.
//!
//! This module provides helper utilities shared by extractors.

const std = @import("std");

pub const QueryEntry = struct {
    key: []const u8,
    value: ?[]const u8,
};

pub const QueryIterator = struct {
    parts: std.mem.SplitIterator(u8, .scalar),

    pub fn next(self: *QueryIterator) ?QueryEntry {
        while (self.parts.next()) |part| {
            var key_value = std.mem.splitScalar(u8, part, '=');
            const key = key_value.next() orelse continue;
            const raw_value = key_value.next() orelse return .{ .key = key, .value = null };
            const value = if (raw_value.len == 0) null else raw_value;
            return .{ .key = key, .value = value };
        }

        return null;
    }
};

pub fn queryIterator(target: []const u8) ?QueryIterator {
    var start_idx = std.mem.findScalar(u8, target, '?') orelse return null;
    if (start_idx == target.len - 1) {
        return null;
    }

    start_idx += 1;
    return .{ .parts = std.mem.splitScalar(u8, target[start_idx..], '&') };
}

const testing = std.testing;

test "queryIterator yields key value pairs" {
    var it = queryIterator("/users?name=zig&role=admin") orelse unreachable;

    const first = it.next() orelse unreachable;
    try testing.expectEqualStrings("name", first.key);
    try testing.expectEqualStrings("zig", first.value.?);

    const second = it.next() orelse unreachable;
    try testing.expectEqualStrings("role", second.key);
    try testing.expectEqualStrings("admin", second.value.?);

    try testing.expectEqual(null, it.next());
}

test "queryIterator returns null for missing query string" {
    try testing.expectEqual(null, queryIterator("/users"));
}
