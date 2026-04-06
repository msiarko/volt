//! Request execution context for the Volt web library.
//!
//! The Context provides handlers with access to I/O operations and memory
//! allocators needed for processing HTTP requests. It separates persistent
//! allocations from request-scoped allocations using different allocators.

const std = @import("std");

/// Execution context passed to all HTTP request handlers.
///
/// The Context provides the essential resources needed for request processing:
/// - I/O interface for network operations
/// - General-purpose allocator for persistent data
/// - Arena allocator for request-scoped temporary allocations
///
/// This separation allows for efficient memory management where temporary
/// request data can be freed at the end of each request while persistent
/// data remains allocated.
///
/// Example usage in a handler:
/// ```zig
/// fn myHandler(ctx: Context, state: *MyState) !Response {
///     // Use ctx.request_allocator for temporary JSON parsing
///     const parsed = try std.json.parseFromSlice(MyStruct, ctx.request_allocator, body, .{});
///
///     // Use ctx.server_allocator for data that needs to persist beyond the request
///     const persistent_data = try ctx.server_allocator.dupe(u8, some_data);
///
///     // Use ctx.io for any I/O operations if needed
///     _ = ctx.io; // Usually handled by extractors/library
///
///     return Response.json(ctx.request_allocator, .ok, "success", null);
/// }
/// ```
pub const Context = struct {
    /// I/O interface for network operations and async I/O.
    /// This is typically used internally by the library but
    /// can be accessed by handlers that need direct I/O control.
    io: std.Io,

    /// An allocator for persistent allocations.
    /// Use this for data that needs to live beyond the current request,
    /// such as cached data, database connections, or shared state.
    ///
    /// Memory allocated with server_allocator should be manually freed when no
    /// longer needed, or it will persist for the lifetime of the server.
    server_allocator: std.mem.Allocator,

    /// Arena allocator for request-scoped temporary allocations.
    /// All memory allocated with the arena is automatically freed
    /// at the end of the request, making it ideal for temporary
    /// parsing, string manipulation, and other ephemeral data.
    ///
    /// This is the preferred allocator for most handler operations
    /// as it provides automatic cleanup and reduces memory management overhead.
    request_allocator: std.mem.Allocator,

    /// Creates a new Context instance.
    ///
    /// Parameters:
    /// - `io`: I/O interface for network operations
    /// - `persistence`: General-purpose allocator for persistent allocations
    /// - `arena`: Request-scoped allocator for temporary allocations
    ///
    /// Returns: Initialized Context ready for use in handlers
    ///
    /// Note: The parameter names use 'persistence' to clarify the allocator's role,
    /// and the Context fields are named for their intended lifetime.
    pub fn init(io: std.Io, persistence: std.mem.Allocator, arena: std.mem.Allocator) @This() {
        return .{
            .request_allocator = arena,
            .server_allocator = persistence,
            .io = io,
        };
    }
};
