const std = @import("std");

pub fn isMemberOfErrorSet(comptime T: type, err: anyerror) bool {
    const info = @typeInfo(T);
    if (info != .error_set) @compileError("T should be an error set");

    const error_set = info.error_set orelse return false;
    inline for (error_set) |err_field| {
        if (err == @field(T, err_field.name)) return true;
    }

    return false;
}

test "isMemberOfErrorSet returns true for member" {
    const AppError = error{ NotFound, InvalidPayload };
    try std.testing.expect(isMemberOfErrorSet(AppError, error.NotFound));
}

test "isMemberOfErrorSet returns false for non-member" {
    const AppError = error{ NotFound, InvalidPayload };
    try std.testing.expect(!isMemberOfErrorSet(AppError, error.OutOfMemory));
}

test "isMemberOfErrorSet works with another error set" {
    const NetworkError = error{ Timeout, ConnectionReset };
    try std.testing.expect(isMemberOfErrorSet(NetworkError, error.Timeout));
    try std.testing.expect(!isMemberOfErrorSet(NetworkError, error.NotFound));
}
