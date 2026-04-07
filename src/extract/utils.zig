//! Utility functions for extractor type identification.
//!
//! This module provides compile-time utilities for identifying extractor types
//! through structural reflection. Extract types use a "key" field with a default
//! value to identify themselves, allowing the router to automatically detect
//! and handle different parameter types.

const std = @import("std");
const StructField = std.builtin.Type.StructField;

/// Checks if a type is a specific extractor by examining its structure.
///
/// This function performs compile-time reflection to determine if the given
/// type has a field named "key" with a default value that matches the provided
/// extractor key. This pattern allows extract types to be identified automatically
/// by the router's parameter injection system.
///
/// Parameters:
/// - `T`: The type to check for extractor identification
/// - `extractor_key`: The key value that identifies the extractor type
///
/// Returns: true if T has a "key" field with the matching default value
///
/// Example usage:
/// ```zig
/// const MyExtractor = struct {
///     key: []const u8 = "MY_EXTRACTOR",
///     // ... other fields
/// };
///
/// // Check if a type is the MyExtractor
/// const isMyExtractor = comptime matches(MyExtractor, "MY_EXTRACTOR"); // true
///
/// const OtherType = struct { name: []const u8 };
/// const isOther = comptime matches(OtherType, "MY_EXTRACTOR"); // false
/// ```
///
/// This is used internally by extract types like WebSocket and JSON to enable
/// automatic parameter detection in route handlers.
pub fn matches(comptime T: type, comptime extractor_key: []const u8) bool {
    const t = @typeInfo(T);
    for (t.@"struct".fields) |field| {
        if (std.mem.eql(u8, field.name, "key")) {
            if (StructField.defaultValue(field)) |k| {
                return std.mem.eql(u8, k, extractor_key);
            }
        }
    }

    return false;
}

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

test "matches returns true for matching type" {
    const result = comptime matches(struct { key: []const u8 = "WS_EXTRACTOR" }, "WS_EXTRACTOR");

    try testing.expect(result);
}

test "matches returns false for non-matching type" {
    const result = comptime matches(struct { key: []const u8 = "OTHER" }, "WS_EXTRACTOR");

    try testing.expect(!result);
}

test "matches returns false when key has no default value" {
    const result = comptime matches(struct { key: []const u8 }, "WS_EXTRACTOR");

    try testing.expect(!result);
}

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
