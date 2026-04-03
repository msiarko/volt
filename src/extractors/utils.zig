const std = @import("std");
const StructField = std.builtin.Type.StructField;

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

const testing = std.testing;

test "matches returns true for matching type" {
    const result = comptime matches(struct { key: []const u8 = "WS_EXTRACTOR" }, "WS_EXTRACTOR");

    try testing.expect(result);
}

test "matches returns false for non-matching type" {
    const result = comptime matches(struct { key: []const u8 = "OTHER" }, "WS_EXTRACTOR");

    try testing.expect(!result);
}
