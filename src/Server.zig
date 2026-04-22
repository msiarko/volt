const std = @import("std");
const Allocator = std.mem.Allocator;
const Router = @import("router.zig").Router;
const IpAddress = std.Io.net.IpAddress;
const ListenOptions = std.Io.net.IpAddress.ListenOptions;

/// Configuration options for the HTTP server, such as timeouts and limits.
pub const ServerOptions = struct {
    shutdown_timeout_seconds: u64 = 2,
};

const Self = @This();

const ShutdownWait = union(enum) {
    tasks_done: std.Io.Cancelable!void,
    timeout: std.Io.Cancelable!void,
};

io: std.Io,
options: ServerOptions,

/// Initializes a new HTTP server instance.
///
/// Parameters:
/// - `io`: I/O interface for network operations
/// - `options`: Server runtime options
///
/// Returns: A new Server instance ready to listen for connections
pub fn init(io: std.Io, options: ServerOptions) !Self {
    return .{
        .io = io,
        .options = options,
    };
}

/// Starts listening for HTTP connections on the specified address.
///
/// This method runs an event loop that accepts incoming connections
/// and processes them asynchronously. Each connection is handled in
/// a separate async task.
///
/// Parameters:
/// - `allocator`: Allocator used for per-request arena allocation
/// - `address`: Network address to bind to (IP and port)
/// - `router`: Registered route table used to resolve handlers
///
/// The server will continue running until interrupted or an error occurs.
pub fn listen(
    self: *Self,
    comptime State: type,
    allocator: Allocator,
    address: IpAddress,
    router: *const Router(State),
) !void {
    var server = try IpAddress.listen(
        &address,
        self.io,
        .{},
    );
    defer server.deinit(self.io);

    var tasks: std.Io.Group = .init;
    errdefer tasks.cancel(self.io);

    var buffer: [32]u8 = undefined;
    var fixed_writer = std.Io.Writer.fixed(&buffer);
    try address.format(&fixed_writer);
    try fixed_writer.flush();

    std.log.info("Server is listening on http://{s}", .{buffer[0..fixed_writer.end]});
    try self.acceptConnections(State, allocator, router, &server, &tasks);
    const graceful_shutdown_timeout: std.Io.Clock.Duration = .{
        .raw = std.Io.Duration.fromSeconds(@intCast(self.options.shutdown_timeout_seconds)),
        .clock = .real,
    };
    try self.gracefulShutdown(&tasks, graceful_shutdown_timeout);
}

fn acceptConnections(
    self: *Self,
    comptime State: type,
    allocator: Allocator,
    router: *const Router(State),
    server: *std.Io.net.Server,
    tasks: *std.Io.Group,
) !void {
    while (true) {
        const conn = server.accept(self.io) catch |err| switch (err) {
            error.Canceled => return,
            else => return err,
        };

        tasks.async(self.io, Router(State).handle, .{ router, self.io, allocator, conn });
    }
}

fn gracefulShutdown(self: *Self, tasks: *std.Io.Group, timeout: std.Io.Clock.Duration) !void {
    defer tasks.cancel(self.io);

    var select_buffer: [2]ShutdownWait = undefined;
    var select = std.Io.Select(ShutdownWait).init(self.io, &select_buffer);
    defer select.cancelDiscard();

    select.async(.tasks_done, awaitTasks, .{ tasks, self.io });
    select.async(.timeout, sleepFor, .{ timeout, self.io });

    const result = try select.await();
    switch (result) {
        .tasks_done => |await_result| try await_result,
        .timeout => |timeout_result| {
            std.log.warn(
                "Graceful shutdown timeout reached after {}ms; canceling remaining connection tasks",
                .{timeout.raw.toMilliseconds()},
            );
            try timeout_result;
        },
    }
}

fn awaitTasks(tasks: *std.Io.Group, io: std.Io) std.Io.Cancelable!void {
    try tasks.await(io);
}

fn sleepFor(duration: std.Io.Clock.Duration, io: std.Io) std.Io.Cancelable!void {
    try duration.sleep(io);
}
