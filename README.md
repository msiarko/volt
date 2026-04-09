<p align="center">
  <img src="docs/assets/icon.png" alt="Volt logo" width="180" style="border-radius: 10%;" />
</p>

A modern, type-safe web library for Zig with automatic parameter injection and WebSocket support.

## Features

- ✨ **Designed for usability**: Clear abstractions and automatic parameter handling
- 🔒 **Type Safe**: Compile-time parameter validation and injection
- 🌐 **WebSocket Support**: Seamless WebSocket upgrade handling
- 🧰 **Request Data Extraction**: Built-in extract support for request data and protocol upgrades
- 🛣️ **Router**: Flexible routing with HTTP method support
- 🧩 **Middleware System**: Per-request middleware chain with explicit short-circuiting
- ⚡ **Async**: Built-in asynchronous request handling
- 🧠 **Memory Safe**: Request-scoped and server-scoped allocators for safer memory handling

## Installation

Add volt as a dependency in your `build.zig.zon`:

Use `zig fetch --save "git+https://github.com/msiarko/volt#{branch or tag}"` to download the library directly into your project.

> **Note**: Volt requires a **nightly version of Zig** (0.16.0-dev or later). Stable releases are not currently supported.

Then add it to your `build.zig`:

```zig
const volt = b.dependency("volt", .{});
exe.root_module.addImport("volt", volt.module("volt"));
```

## Configuration

Volt currently exposes one build option:

- `shutdown_timeout_seconds` (`u32`, default `5`): Graceful shutdown timeout for waiting on active HTTP connection tasks before force-canceling them.

Pass options through the dependency config in your `build.zig`:

```zig
const volt = b.dependency("volt", .{
    .target = target,
    .optimize = optimize,
    .shutdown_timeout_seconds = 10,
});

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

### Route Matching Rules

Volt matches routes using the following precedence rules:

- Exact routes are checked before parametric routes.
- Parametric routes use `:name` segments, for example `/users/:id`.
- Among parametric routes, patterns with more literal segments are matched first.
- Duplicate parameter names in a single route pattern are rejected during registration.
- If a path matches but the HTTP method does not, Volt returns **405 Method Not Allowed**.

Examples:

- `/users/me` is preferred over `/users/:id` for the request `/users/me`.
- `/users/:id` is preferred over `/:entity/:id` for the request `/users/42`.

## Middleware

Volt supports request middleware chains with compile-time signature validation and per-request isolation.

Register middleware on the router by passing the middleware type:

```zig
try server.router.use(LoggerMiddleware); // Pass type, not instance
```

Each request creates a fresh middleware instance. Middleware is initialized with `Context` to allow explicit allocator choice and access to request-scoped resources:
- `ctx.request_allocator` — request-scoped lifetime (freed at request boundary)  
- `ctx.server_allocator` — server-wide lifetime (freed at server shutdown)
- `ctx.io` — I/O interface for async operations

Middleware contract:

- `init(ctx: *Context) !Self` — Initialize with allocator choice and store references if needed
- `handle(self: *const Self, next: *const volt.middleware.Next) !volt.Response` — Handle request

Use `next.run()` to continue the chain. Returning a `Response` without calling
`next.run()` short-circuits request processing.

For a complete real-world middleware definition, see
[`src/middlewares/console_logger.zig`](src/middlewares/console_logger.zig).

```zig
const LoggerMiddleware = struct {
    request_allocator: std.mem.Allocator,

    pub fn init(ctx: *volt.Context) !@This() {
        // Store what you need for handle() - in this case, the allocator
        return .{ .request_allocator = ctx.request_allocator };
    }

    pub fn handle(
        self: *const @This(),
        next: *const volt.middleware.Next,
    ) !volt.Response {
        std.log.info("middleware called", .{});

        var res = try next.run();

        // Optional response adaptation can happen here.
        _ = self;
        return res;
    }
};
```

## Automatic Parameter Injection

Volt automatically extracts parameters from HTTP requests using compile-time reflection:

## Supported Extract Types

- **extract.Json(T)**: Parses request body JSON into typed structs.
- **extract.Query("name")**: Extracts a single query parameter by key.
- **extract.TypedQuery(T)**: Maps query parameters into a typed filter struct (`?[]const u8` fields).
- **extract.Header("name")**: Extracts a single HTTP header by name.
- **extract.RouteParam("name")**: Extracts a named path segment from parametric routes (e.g., `/users/:id`).
- **extract.WebSocket**: Handles WebSocket upgrade requests and connection handoff.

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
    user_data: volt.extract.Json(CreateUserRequest)
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
    ws: volt.extract.WebSocket
) !volt.Response {
    try ws.onConnected(handleConnection, .{ctx, state});
    return volt.webSocketResponse(ws);
}

fn handleConnection(ctx: volt.Context, state: *AppState, socket: *std.http.Server.WebSocket) !void {
    const message = try socket.readMessage();
    try socket.writeMessage("Hello from server!", .text);
}
```

### Query Parameter Extraction

Behavior notes:

- Query components are URL-decoded once (`%XX` and `+` as space).
- Decoding is single-pass only; double-encoded inputs are not fully decoded.

```zig
fn findUser(
    ctx: volt.Context,
    state: *AppState,
    user_id: volt.extract.Query("id")
) !volt.Response {
    _ = state;

    if (user_id.value) |id| {
        return volt.Response.text(ctx.request_allocator, .ok, id, null);
    }

    return volt.Response.text(ctx.request_allocator, .bad_request, "Missing query parameter: id", null);
}
```

### HTTP Header Extraction

```zig
fn secureHandler(
    ctx: volt.Context,
    state: *AppState,
    auth: volt.extract.Header("Authorization")
) !volt.Response {
    _ = state;

    const token = auth.value orelse {
        return volt.Response.text(ctx.request_allocator, .unauthorized, "Missing Authorization header", null);
    };

    return volt.Response.text(ctx.request_allocator, .ok, token, null);
}
```

### Route Parameter Extraction

Route parameters are matched from parametric route patterns such as `/users/:id`.
The router is responsible for selecting the matching handler, and `RouteParam`
resolves the requested value from the matched route pattern and request target.

Behavior notes:

- Route parameter names come from `:name` segments in the registered route pattern.
- Multiple route parameters are supported in a single route.
- Exact routes are checked before parametric routes.
- Among parametric routes, more literal segments take precedence over more generic patterns.
- Duplicate parameter names in the same route pattern are rejected at registration time.
- Captured segments are validated as URI-encoded path segments (raw whitespace/control chars and malformed `%` escapes are rejected).
- RouteParam keeps valid encoded values as-is (for example `hello%20world`), so handlers can choose if/when to decode.

```zig
try server.router.get("/users/:id", &getUserById);
try server.router.get("/teams/:team_id/users/:user_id", &getTeamUser);

fn getUserById(
    ctx: volt.Context,
    state: *AppState,
    user_id: volt.extract.RouteParam("id")
) !volt.Response {
    _ = state;

    const id = user_id.value orelse {
        return volt.Response.text(ctx.request_allocator, .bad_request, "Missing route parameter: id", null);
    };

    return volt.Response.text(ctx.request_allocator, .ok, id, null);
}

fn getTeamUser(
    ctx: volt.Context,
    state: *AppState,
    team_id: volt.extract.RouteParam("team_id"),
    user_id: volt.extract.RouteParam("user_id")
) !volt.Response {
    _ = state;

    const team = team_id.value orelse {
        return volt.Response.text(ctx.request_allocator, .bad_request, "Missing route parameter: team_id", null);
    };

    const user = user_id.value orelse {
        return volt.Response.text(ctx.request_allocator, .bad_request, "Missing route parameter: user_id", null);
    };

    return volt.Response.text(
        ctx.request_allocator,
        .ok,
        try std.fmt.allocPrint(ctx.request_allocator, "team={s}, user={s}", .{ team, user }),
        null,
    );
}
```

### Typed Query Extraction

```zig
const UserFilters = struct {
    name: ?[]const u8,
    role: ?[]const u8,
    active: ?[]const u8,
};

fn listUsers(
    ctx: volt.Context,
    state: *AppState,
    filters_query: volt.extract.TypedQuery(UserFilters)
) !volt.Response {
    _ = state;

    var filters = filters_query;
    defer filters.deinit(ctx.request_allocator);

    if (try filters.value) |f| {
        if (f.name) |name| {
            return volt.Response.text(ctx.request_allocator, .ok, name, null);
        }
    }

    return volt.Response.text(ctx.request_allocator, .ok, "No filters provided", null);
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
    return volt.Response.text(ctx.request_allocator, .ok, "Success", null);
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
    return .text(ctx.request_allocator, .ok, "Hello from Volt!", null);
}

fn echoHandler(ctx: volt.Context, state: *AppState, body: volt.extract.Json(EchoRequest)) !volt.Response {
    _ = state;
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

fn webSocketHandler(ctx: volt.Context, state: *AppState, ws: volt.extract.WebSocket) !volt.Response {
    try ws.onConnected(handleConnection, .{ ctx, state });
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

- **Request Allocator** (`ctx.request_allocator`): Temporary allocations for parsing, string manipulation, and response construction. Automatically freed after the request completes.
- **Server Allocator** (`ctx.server_allocator`): Long-lived allocations for data that persists beyond the current request.

```zig
fn myHandler(ctx: volt.Context, state: *AppState) !volt.Response {
    // Use request_allocator for temporary work
    const temp_buffer = try ctx.request_allocator.alloc(u8, 1024);

    // Use server_allocator for persistent data
    const persistent_data = try ctx.server_allocator.dupe(u8, some_data);

    return volt.Response.text(ctx.request_allocator, .ok, "Success", null);
}
```

## Architecture

Volt is built around several key components:

- **Server**: Generic HTTP server with async request handling
- **Router**: Type-safe routing with automatic parameter injection
- **Middleware**: Per-request middleware pipeline for cross-cutting concerns
- **Context**: Request execution context with I/O and memory resources
- **Extract**: Automatic parameter extraction (JSON, WebSocket, Query, TypedQuery, Header, RouteParam)
- **Response**: Unified response type for HTTP and WebSocket responses

## Status & Roadmap

**Current Version**: 0.0.5 (Early Development)

**Requirements**: Nightly Zig only (0.16.0-dev or later). Stable Zig releases are not supported.

This is an early-stage library. While the core routing and WebSocket functionality is stable, expect breaking changes as the API matures.

### Planned Features

- **Additional Extract Types**:
  - Form data extraction

- **Feature Flags**: Build-time feature flags in `build.zig` to include only selected features and reduce final binary size when unused features are disabled.

- **SSL/TLS Support**: Secure HTTPS connections

- **Enhanced Error Handling**: More comprehensive error types and better error messages

- **Performance Optimizations**: Profiling and optimization based on real-world usage patterns

Contributions and feedback are welcome as we develop these features!

## Contributing

Contributions are welcome! Please feel free to submit issues and pull requests.

## License

This project is licensed under the MIT License - see the LICENSE file for details.
