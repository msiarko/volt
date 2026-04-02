pub const ConsoleLogger = @import("console_logger.zig").ConsoleLogger;

test {
    const testing = @import("std").testing;
    _ = testing.refAllDecls(ConsoleLogger);
}
