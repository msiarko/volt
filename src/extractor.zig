const Context = @import("core").Context;

const method_name = "init";

pub fn isExtractor(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (@hasDecl(T, method_name)) {
        const info = @typeInfo(@TypeOf(@field(T, method_name)));
        if (info != .@"fn") return false;
        const init = info.@"fn";
        const Ret = init.return_type orelse return false;
        const ret_info = @typeInfo(Ret);
        return info == .@"fn" and
            init.param_types.len == 1 and
            init.param_types[0] == Context and
            ret_info.error_union.payload == T;
    }

    return false;
}

test "extractor returns true for a struct with a fromContext method and returns Extractor type" {
    const std = @import("std");

    const TestExtractor = struct {
        pub fn init(ctx: Context) !@This() {
            _ = ctx;
            return .{};
        }
    };

    try std.testing.expect(isExtractor(TestExtractor));
}

test "extractor returns false for a struct without a fromContext method" {
    const std = @import("std");

    const NonExtractor = struct {
        pub fn someOtherMethod() void {}
    };

    try std.testing.expect(!isExtractor(NonExtractor));
}

test "extractor returns false if fromContext return type that is not an extractor itself" {
    const std = @import("std");

    const NonExtractor = struct {
        pub fn fromContext(ctx: Context) !u8 {
            _ = ctx;
            return 5;
        }
    };

    try std.testing.expect(!isExtractor(NonExtractor));
}
