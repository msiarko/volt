const std = @import("std");
const Allocator = std.mem.Allocator;
const AllocatorError = std.mem.Allocator.Error;

pub const QueryEntry = struct {
    key: []const u8,
    value: ?[]const u8,
};

pub const QueryIterator = struct {
    parts: std.mem.SplitIterator(u8, .scalar),

    pub fn next(self: *QueryIterator) ?QueryEntry {
        return while (self.parts.next()) |part| {
            var key_value = std.mem.splitScalar(u8, part, '=');
            const key = key_value.next() orelse continue;
            const raw_value = key_value.next() orelse break .{ .key = key, .value = null };
            const value = if (raw_value.len == 0) null else raw_value;
            break .{ .key = key, .value = value };
        } else null;
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

fn hasEncodedCharacters(component: []const u8) bool {
    if (std.mem.findScalar(u8, component, '%')) |idx| {
        if (idx + 2 > component.len - 1) {
            return false;
        }

        const hex1 = component[idx + 1];
        const hex2 = component[idx + 2];
        return std.ascii.isHex(hex1) and std.ascii.isHex(hex2);
    }

    return false;
}

pub fn decodeUrl(arena: Allocator, component: []const u8) AllocatorError![]const u8 {
    if (!hasEncodedCharacters(component)) return component;
    const decoded = try arena.alloc(u8, component.len);
    @memcpy(decoded, component);
    return std.Uri.percentDecodeInPlace(decoded);
}

pub const StringToEnumError = error{InvalidEnumValue};
pub const ParseError = StringToEnumError || std.fmt.ParseIntError || std.fmt.ParseFloatError;

pub fn parse(comptime T: type, val: []const u8) ParseError!T {
    const i = @typeInfo(T);
    return switch (i) {
        .float => try std.fmt.parseFloat(T, val),
        .int => try std.fmt.parseInt(T, val, 10),
        .@"enum" => std.meta.stringToEnum(T, val) orelse return StringToEnumError.InvalidEnumValue,
        .@"struct" => return error.Unimplemented, // TODO: support nested structs in form data
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

test "hasEncodedCharacters detects markers" {
    try testing.expect(!hasEncodedCharacters("abc"));
    try testing.expect(hasEncodedCharacters("a%20b"));
}

test "decodeUrl fails on malformed percent escape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try testing.expectEqualStrings("bad%2", try decodeUrl(arena.allocator(), "bad%2"));
}

test "decodeUrl returns source slice on non-hex percent escape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "bad%G0";
    const decoded = try decodeUrl(arena.allocator(), source);

    try testing.expectEqual(@intFromPtr(source.ptr), @intFromPtr(decoded.ptr));
    try testing.expectEqualStrings("bad%G0", decoded);
}

test "decodeUrl returns allocation-sized slice" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "a%20b";
    const decoded = try decodeUrl(arena.allocator(), source);

    try testing.expect(@intFromPtr(decoded.ptr) != @intFromPtr(source.ptr));
    try testing.expectEqualStrings("a b", decoded);
}

test "decodeUrl returns borrowed slice when decoding is not needed" {
    const source = "plain";
    const decoded = try decodeUrl(testing.allocator, source);
    try testing.expectEqual(@intFromPtr(source.ptr), @intFromPtr(decoded.ptr));
    try testing.expectEqual(source.len, decoded.len);
}
