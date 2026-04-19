const std = @import("std");
const Allocator = std.mem.Allocator;
const AllocatorError = std.mem.Allocator.Error;

fn decodeHexNibble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => 10 + (c - 'a'),
        'A'...'F' => 10 + (c - 'A'),
        else => null,
    };
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

pub fn queryComponentNeedsDecoding(component: []const u8) bool {
    for (component) |c| {
        if (c == '%' or c == '+') return true;
    }
    return false;
}

pub const DecodingError = AllocatorError || error{InvalidPercentEncoding};

pub fn queryComponentEqualsAsciiIgnoreCaseDecoded(component: []const u8, expected: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;

    while (i < component.len) {
        const decoded = blk: {
            const c = component[i];
            if (c == '+') {
                i += 1;
                break :blk ' ';
            }

            if (c == '%') {
                if (i + 2 >= component.len) return false;
                const hi = decodeHexNibble(component[i + 1]) orelse return false;
                const lo = decodeHexNibble(component[i + 2]) orelse return false;
                i += 3;
                break :blk (hi << 4) | lo;
            }

            i += 1;
            break :blk c;
        };

        if (j >= expected.len) return false;
        if (std.ascii.toLower(decoded) != std.ascii.toLower(expected[j])) return false;
        j += 1;
    }

    return j == expected.len;
}

pub fn decodeQueryComponentAssumeNeeded(allocator: Allocator, component: []const u8) DecodingError![]const u8 {
    const out = try allocator.alloc(u8, component.len);
    errdefer allocator.free(out);

    var i: usize = 0;
    var out_i: usize = 0;
    while (i < component.len) {
        const c = component[i];
        if (c == '+') {
            out[out_i] = ' ';
            out_i += 1;
            i += 1;
            continue;
        }

        if (c == '%') {
            if (i + 2 >= component.len) return DecodingError.InvalidPercentEncoding;
            const hi = decodeHexNibble(component[i + 1]) orelse return DecodingError.InvalidPercentEncoding;
            const lo = decodeHexNibble(component[i + 2]) orelse return DecodingError.InvalidPercentEncoding;
            out[out_i] = (hi << 4) | lo;
            out_i += 1;
            i += 3;
            continue;
        }

        out[out_i] = c;
        out_i += 1;
        i += 1;
    }

    return allocator.realloc(out, out_i);
}

pub fn decodeQueryComponent(allocator: Allocator, component: []const u8) DecodingError![]const u8 {
    if (!queryComponentNeedsDecoding(component)) return component;
    return decodeQueryComponentAssumeNeeded(allocator, component);
}

pub fn parse(comptime T: type, val: []const u8) !T {
    const i = @typeInfo(T);
    return switch (i) {
        .float => try std.fmt.parseFloat(T, val),
        .int => try std.fmt.parseInt(T, val, 10),
        .@"enum" => std.meta.stringToEnum(T, val) orelse return error.InvalidEnumValue,
        else => val,
    };
}

pub const TestExtractor = struct {
    const Self = @This();

    pub const ID: []const u8 = "TEST_EXTRACTOR";

    value: ?[]const u8,

    pub fn init() Self {
        return .{ .value = null };
    }
};

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

test "queryIterator returns null for trailing question mark" {
    try testing.expectEqual(null, queryIterator("/users?"));
}

test "queryComponentNeedsDecoding detects markers" {
    try testing.expect(queryComponentNeedsDecoding("a+b"));
    try testing.expect(queryComponentNeedsDecoding("a%20b"));
    try testing.expect(!queryComponentNeedsDecoding("abc"));
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

test "decodeQueryComponent fails on non-hex percent escape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.InvalidPercentEncoding, decodeQueryComponent(arena.allocator(), "bad%G0"));
}

test "decodeQueryComponent returns allocation-sized slice" {
    const decoded = try decodeQueryComponent(testing.allocator, "a%20b");
    defer testing.allocator.free(decoded);

    try testing.expectEqualStrings("a b", decoded);
}

test "decodeQueryComponent returns borrowed slice when decoding is not needed" {
    const source = "plain";
    const decoded = try decodeQueryComponent(testing.allocator, source);
    try testing.expectEqual(@intFromPtr(source.ptr), @intFromPtr(decoded.ptr));
    try testing.expectEqual(source.len, decoded.len);
}

test "queryComponentEqualsAsciiIgnoreCaseDecoded matches encoded key" {
    try testing.expect(queryComponentEqualsAsciiIgnoreCaseDecoded("first%20name", "first name"));
    try testing.expect(queryComponentEqualsAsciiIgnoreCaseDecoded("X-REQUEST-ID", "x-request-id"));
    try testing.expect(!queryComponentEqualsAsciiIgnoreCaseDecoded("first%2", "first "));
}

test "queryComponentEqualsAsciiIgnoreCaseDecoded fails when decoded key is longer than expected" {
    try testing.expect(!queryComponentEqualsAsciiIgnoreCaseDecoded("abc", "ab"));
}
