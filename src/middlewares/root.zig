//! HTTP middleware collection for the Volt web library.
//!
//! Middlewares provide request/response hooks for logging, authentication,
//! compression, and other cross-cutting concerns.

pub const ConsoleLogger = @import("console_logger.zig").ConsoleLogger;

test {
    const testing = @import("std").testing;
    _ = testing.refAllDecls(ConsoleLogger);
}
