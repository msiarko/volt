# Volt

A modern, type-safe web library for Zig with automatic parameter injection and WebSocket support.

## Features

- ✨ **Designed for usability**: Clear abstractions and automatic parameter handling
- 🔒 **Type Safe**: Compile-time parameter validation and injection
- 🌐 **WebSocket Support**: Seamless WebSocket upgrade handling
- 📦 **JSON Extraction**: Automatic JSON deserialization from request bodies
- 🛣️ **Router**: Flexible routing with HTTP method support
- ⚡ **Async**: Built-in asynchronous request handling
- 🧠 **Memory Safe**: Request-scoped and server-scoped allocators for safer memory handling

## Installation

Add volt as a dependency in your `build.zig.zon`:

Use `zig fetch --save "git+https://github.com/msiarko/volt#v0.0.1"` to download the library directly into your project.

> **Note**: Volt requires a **nightly version of Zig** (0.16.0-dev or later). Stable releases are not currently supported.

Then add it to your `build.zig`:

```zig
const volt = b.dependency("volt", .{});
exe.root_module.addImport("volt", volt.module("volt"));
```

## Quick Start

Here's a simple "Hello World" server:

```zig
const std = @import("std");
const volt = @import("volt");

const StatelessServer = volt.Server(void);

pub fn main(init: std.process.Init) !void {
    var server: StatelessServer = .init(init.gpa, init.io, {});
    defer server.deinit();

    try server.router.get("/", &indexHandler);

    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 8080);
    try server.listen(address, .{});
}

fn indexHandler(ctx: volt.Context) !volt.Response {
    return .text(ctx.request_allocator, .ok, "Hello from Volt HTTP example!", null);
}
```

## Routing

Volt provides a clean routing API with support for all HTTP methods:

```zig
try server.router.get("/users", &getUsers);
try server.router.post("/users", &createUser);
try server.router.put("/users", &updateUser);
try server.router.delete("/users", &deleteUser);
try server.router.patch("/users", &patchUser);
```

## Automatic Parameter Injection

Volt automatically extracts parameters from HTTP requests using compile-time reflection:

### JSON Body Parsing

```zig
const CreateUserRequest = struct {
    name: []const u8,
    email: []const u8,
    age: u32,
};

fn createUser(
    ctx: volt.Context,
    state: *AppState,
    user_data: volt.Json(CreateUserRequest)
) !volt.Response {
    const user = try user_data.value;
    defer user_data.deinit(ctx.request_allocator);

    // Process user creation...
    return volt.Response.json(ctx.request_allocator, .created, "{\"id\": 123}", null);
}
```

### WebSocket Upgrades

```zig
fn websocketHandler(
    ctx: volt.Context,
    state: *AppState,
    ws: volt.WebSocket
) !volt.Response {
    try ws.onUpgrade(handleConnection, .{ctx, state});
    return ws.intoResponse();
}

fn handleConnection(ctx: volt.Context, state: *AppState, socket: *std.http.Server.WebSocket) !void {
    const message = try socket.readMessage();
    try socket.writeMessage("Hello from server!", .text);
}
```

## Response Types

Volt provides convenient response creation methods:

```zig
// JSON responses
return volt.Response.json(ctx.request_allocator, .ok, "{\"status\": \"success\"}", null);

// Plain text responses
return volt.Response.text(ctx.request_allocator, .ok, "Hello, World!", null);

// Error responses
return volt.Response.internal_server_error(ctx.request_allocator, "Something went wrong", null);
```

## Application State

Use the generic `Server(State)` to maintain application-wide state:

```zig
const AppState = struct {
    database: Database,
    cache: std.StringHashMap([]const u8),
    mutex: std.Io.Mutex,

    pub fn init(allocator: std.mem.Allocator) !AppState {
        return .{
            .database = try Database.init(allocator),
            .cache = std.StringHashMap([]const u8).init(allocator),
            .mutex = .init,
        };
    }
};

const Server = volt.Server(AppState);

// Access state in handlers
fn myHandler(ctx: volt.Context, state: *AppState) !volt.Response {
    try state.mutex.lock(ctx.io);
    defer state.mutex.unlock(ctx.io);

    // Use state.database, state.cache, etc.
    return volt.Response.ok();
}
```

## Examples

### HTTP Server Example

```zig
const std = @import("std");
const volt = @import("volt");

const AppState = struct {};

const Server = volt.Server(AppState);

pub fn main(init: std.process.Init) !void {
    const state: AppState = .{};
    var server = try Server.init(allocator, io, state);
    defer server.deinit();

    try server.router.get("/", &indexHandler);
    try server.router.post("/echo", &echoHandler);

    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 8080);
    try server.listen(address, .{});
}

fn indexHandler(ctx: volt.Context, state: *AppState) !volt.Response {
    _ = state;
    // Any unhandled error will be handled by library as Internal Server Error response
    // with the name of the error in the response body
    // If you want to send a specific response, handle error with the catch block
    return .text(ctx.request_allocator, .ok, "Hello from Volt!", null);
}

fn echoHandler(ctx: volt.Context, state: *AppState, body: volt.Json(EchoRequest)) !volt.Response {
    _ = state;
    // try on json's value here is required, since Json(T).value is 'anyerror!*T'.
    // This gives you the control of how to handle the request in case of parsing error
    // Value is allocated using ctx.request_allocator and auromatically freed after request is finished
    const request = try body.value;
    defer body.deinit(ctx.request_allocator);
    return .text(ctx.request_allocator, .ok, request.message, null);
}

const EchoRequest = struct {
    message: []const u8,
};
```

### WebSocket Server Example

```zig
const std = @import("std");
const volt = @import("volt");

const AppState = struct {};

const Server = volt.Server(AppState);

pub fn main(init: std.process.Init) !void {
    const state: AppState = .{};
    var server = try Server.init(allocator, io, state);
    defer server.deinit();

    try server.router.get("/ws", &webSocketHandler);

    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 8080);
    try server.listen(address, .{});
}

fn webSocketHandler(ctx: volt.Context, state: *AppState, ws: volt.WebSocket) !volt.Response {
    try ws.onUpgrade(handleConnection, .{ ctx, state });
    return ws.intoResponse();
}

fn handleConnection(ctx: volt.Context, state: *AppState, socket: *std.http.Server.WebSocket) !void {
    _ = ctx;
    _ = state;
    while (true) {
        const msg = try socket.readSmallMessage();
        switch (msg.opcode) {
            .text => {
                try socket.writeMessage(msg.data, .text);
            },
            .connection_close => break,
            else => continue,
        }
    }
}
```

## Memory Management

Volt uses a two-tier memory management system:

    // Use ctx.request_allocator for temporary parsing, string manipulation, and response construction.
- **Server Allocator** (`ctx.server_allocator`): Long-lived allocations. Use for data that persists beyond the current request.

```zig
fn myHandler(ctx: volt.Context, state: *AppState) !volt.Response {
    // Use request_allocator for temporary work
    const temp_buffer = try ctx.request_allocator.alloc(u8, 1024);

    // Use server_allocator for persistent data
    const persistent_data = try ctx.server_allocator.dupe(u8, some_data);

    return volt.Response.ok();
}
```

## Architecture

Volt is built around several key components:

- **Server**: Generic HTTP server with async request handling
- **Router**: Type-safe routing with automatic parameter injection
- **Context**: Request execution context with I/O and memory resources
- **Extractors**: Automatic parameter extraction (JSON, WebSocket)
- **Response**: Unified response type for HTTP and WebSocket responses

## Status & Roadmap

**Current Version**: 0.0.1 (Early Development)

**Requirements**: Nightly Zig only (0.16.0-dev or later). Stable Zig releases are not supported.

This is an early-stage library. While the core routing and WebSocket functionality is stable, expect breaking changes as the API matures.

### Planned Features

- **Additional Extractors**:
  - Query parameter extraction
  - Header extraction
  - Route parameter extraction
  - Form data extraction

- **SSL/TLS Support**: Secure HTTPS connections

- **Middleware System**: Request/response middleware pipeline for cross-cutting concerns

- **Enhanced Error Handling**: More comprehensive error types and better error messages

- **Performance Optimizations**: Profiling and optimization based on real-world usage patterns

Contributions and feedback are welcome as we develop these features!

## Contributing

Contributions are welcome! Please feel free to submit issues and pull requests.

## License

This project is licensed under the MIT License - see the LICENSE file for details.
