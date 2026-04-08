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

pub fn queryComponentNeedsDecoding(component: []const u8) bool {
    for (component) |c| {
        if (c == '%' or c == '+') return true;
    }
    return false;
}

fn decodeHexNibble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => 10 + (c - 'a'),
        'A'...'F' => 10 + (c - 'A'),
        else => null,
    };
}

pub fn decodeQueryComponent(allocator: std.mem.Allocator, component: []const u8) ![]const u8 {
    if (!queryComponentNeedsDecoding(component)) return component;

    const out = try allocator.alloc(u8, component.len);
    var out_i: usize = 0;
    var i: usize = 0;
    while (i < component.len) {
        const c = component[i];
        if (c == '+') {
            out[out_i] = ' ';
            out_i += 1;
            i += 1;
            continue;
        }

        if (c == '%') {
            if (i + 2 >= component.len) return error.InvalidPercentEncoding;

            const hi = decodeHexNibble(component[i + 1]) orelse return error.InvalidPercentEncoding;
            const lo = decodeHexNibble(component[i + 2]) orelse return error.InvalidPercentEncoding;
            out[out_i] = (hi << 4) | lo;
            out_i += 1;
            i += 3;
            continue;
        }

        out[out_i] = c;
        out_i += 1;
        i += 1;
    }

    return out[0..out_i];
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

test "decodeQueryComponent decodes percent escapes and plus" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const decoded = try decodeQueryComponent(arena.allocator(), "first+name%3Dzig%20lang");
    try testing.expectEqualStrings("first name=zig lang", decoded);
}

test "decodeQueryComponent fails on malformed percent escape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.InvalidPercentEncoding, decodeQueryComponent(arena.allocator(), "bad%2"));
}
