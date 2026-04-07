//! Utility helpers for HTTP internals.

const std = @import("std");

/// Checks whether an error value belongs to the provided error set type.
///
/// Parameters:
/// - `T`: Error set type to check membership against
/// - `err`: Error value to verify
///
/// Returns: `true` when `err` is a member of `T`, otherwise `false`
///
/// This function validates at compile time that `T` is an error set.
pub fn isMemberOfErrorSet(comptime T: type, err: anyerror) bool {
    const info = @typeInfo(T);
    if (info != .error_set) @compileError("T should be an error set");

    const error_set = info.error_set orelse false;
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
