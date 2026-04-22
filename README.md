<p align="center">
  <img src="docs/assets/icon.png" alt="Volt logo" width="180" style="border-radius: 10%;" />
</p>

A web library for Zig.

> **Disclaimer**: Volt is **not** designed to be the fastest or most efficient HTTP library. It is built on top of Zig's standard `std.http` module and prioritizes **developer ergonomics over raw performance**. The primary goal is to enable **quick prototyping of REST APIs** with a flexible, type-safe interface. **Do not use Volt in production** — it is intended for development and prototyping purposes only.

## Features

- **Designed for usability**: Clear abstractions and automatic parameter handling
- **Type Safe**: Compile-time parameter validation and injection
- **WebSocket Support**: Seamless WebSocket upgrade handling
- **Request Data Extraction**: Built-in extract support for request data and protocol upgrades
- **Router**: Flexible routing with HTTP method support
- **Async**: Built-in asynchronous request handling
- **Memory Safe**: Request-scoped allocator in handlers, with explicit app-state allocation strategy

## Installation

Add volt as a dependency in your `build.zig.zon`:

Use `zig fetch --save "git+https://github.com/msiarko/volt"` to download the library directly into your project.

> **Note**: Volt requires Zig v0.16.0+.

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

const Server = volt.Server;
const Router = volt.Router(void);

pub fn main(init: std.process.Init) !void {
    var server = try Server.init(init.io, .{});
    var router: Router = .init(init.gpa, {});
    defer router.deinit(init.gpa);

    try router.get(init.gpa, "/", &indexHandler);

    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 8080);
    try server.listen(void, init.gpa, address, &router);
}

fn indexHandler(ctx: volt.Context) !volt.Response {
    return .text(ctx.req_arena, .ok, "Hello from Volt HTTP example!", null);
}
```

For `volt.Router(void)`, handlers should omit the state parameter entirely.

## Routing

Volt provides a clean routing API with support for all HTTP methods:

```zig
try router.get(allocator, "/users", &getUsers);
try router.post(allocator, "/users", &createUser);
try router.put(allocator, "/users", &updateUser);
try router.delete(allocator, "/users", &deleteUser);
try router.patch(allocator, "/users", &patchUser);
```

### Route Matching Rules

Volt matches routes using the following precedence rules:

- Exact routes are checked before parametric routes.
- Parametric routes use `:name` segments, for example `/users/:id`.
- Among parametric routes, patterns with more literal segments are matched first.
- Duplicate parameter names in a single route pattern are rejected during registration.
- If an exact path matches but does not support the requested method, Volt continues scanning matching parametric routes for a method match.

Examples:

- `/users/me` is preferred over `/users/:id` for the request `/users/me`.
- `/users/:id` is preferred over `/:entity/:id` for the request `/users/42`.

## Automatic Parameter Injection

Volt automatically extracts parameters from HTTP requests using compile-time reflection:

## Supported Extract Types

All extractors can be used in two ways:

- Automatic injection as handler parameters.
- Manual extraction inside handler bodies with `init(ctx)`.

- **extract.Json(T)**: JSON extractor exposing `result: JsonError!T`.
- **extract.Query("name")**: Query extractor exposing `result: QueryError!?[]const u8`.
- **extract.TypedQuery(T)**: Typed-query extractor exposing `result: QueryError!?*T`.
- **extract.Header("name")**: Extracts a single HTTP header by name as `value: ?[]const u8`.
- **extract.RouteParam("name")**: Extracts a named path segment from parametric routes (e.g., `/users/:id`) as `value: ?[]const u8`.
- **extract.Form(T)**: Form extractor exposing `result: FormError!T`.
- **extract.WebSocket**: Handles WebSocket upgrade requests and connection handoff via `result: WebSocketError!std.http.Server.WebSocket`.

### Manual Extraction With init(ctx)

```zig
fn createUserManual(ctx: volt.Context, state: AppState) !volt.Response {
    _ = state;

    const user = try volt.extract.Json(CreateUserRequest).init(ctx);

    return volt.Response.text(ctx.req_arena, .ok, user.name, null);
}
```

Extraction behavior and lifetime:

- `extract.Json(T)` validates request-body compatibility, requires `Content-Type: application/json`, requires non-zero `Content-Length`, and parses into `T`.
- `extract.Query("name")` matches query keys case-insensitively (decoded key comparison) and single-pass decodes values (`+` to space, `%XX` escapes).
- `extract.Query("name")` returns:
    - `error` for invalid percent-encoding or allocator failure,
    - `null` when the query/key/value is absent or empty,
    - decoded bytes otherwise.
- `extract.TypedQuery(T)` requires `T` to be a struct where every field is `?[]const u8`.
- `extract.TypedQuery(T)` returns `null` only when no query string exists; otherwise returns `*T` with unmatched fields set to `null`.
- `extract.Header` is case-insensitive by header name and returns `null` when the header is absent.
- `extract.RouteParam` returns encoded path-segment values as-is and rejects malformed percent escapes.

### JSON Body Parsing

```zig
const CreateUserRequest = struct {
    name: []const u8,
    email: []const u8,
    age: u32,
};

fn createUser(
    ctx: volt.Context,
    state: AppState,
    user_data: volt.extract.Json(CreateUserRequest)
) !volt.Response {
    _ = state;

    const user = user_data.result catch |err| {
        return volt.Response.text(ctx.req_arena, .bad_request, @errorName(err), null);
    };

    // Process user creation...
    return volt.Response.json(ctx.req_arena, .created, "{\"id\": 123}", null);
}
```

### WebSocket Upgrades

```zig
fn websocketHandler(
    ctx: volt.Context,
    state: AppState,
    ws: volt.extract.WebSocket
) !volt.Response {
    try ws.onConnected(handleConnection, .{ctx, state});
    return volt.Response.empty;
}

fn handleConnection(ctx: volt.Context, state: AppState, socket: *std.http.Server.WebSocket) !void {
    const message = try socket.readMessage();
    try socket.writeMessage("Hello from server!", .text);
}
```

### Query Parameter Extraction

Behavior notes:

- Query values are URL-decoded (`%XX` and `+` as space). Decoding is single-pass only; double-encoded inputs are decoded once.
- Handler extractor field:
    - `result`: `QueryError!?[]const u8`

```zig
fn findUser(
    ctx: volt.Context,
    state: AppState,
    user_id: volt.extract.Query("id")
) !volt.Response {
    _ = state;

    const id = user_id.result catch |err| {
        return volt.Response.text(ctx.req_arena, .bad_request, @errorName(err), null);
    } orelse return volt.Response.text(
        ctx.req_arena,
        .bad_request,
        "Missing query parameter: id",
        null,
    );

    return volt.Response.text(ctx.req_arena, .ok, id, null);
}
```

### HTTP Header Extraction

```zig
fn secureHandler(
    ctx: volt.Context,
    state: AppState,
    auth: volt.extract.Header("Authorization")
) !volt.Response {
    _ = state;

    const token = auth.value orelse {
        return volt.Response.text(ctx.req_arena, .unauthorized, "Missing Authorization header", null);
    };

    return volt.Response.text(ctx.req_arena, .ok, token, null);
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
try router.get(allocator, "/users/:id", &getUserById);
try router.get(allocator, "/teams/:team_id/users/:user_id", &getTeamUser);

fn getUserById(
    ctx: volt.Context,
    state: AppState,
    user_id: volt.extract.RouteParam("id")
) !volt.Response {
    _ = state;

    const id = user_id.value orelse {
        return volt.Response.text(ctx.req_arena, .bad_request, "Missing route parameter: id", null);
    };

    return volt.Response.text(ctx.req_arena, .ok, id, null);
}

fn getTeamUser(
    ctx: volt.Context,
    state: AppState,
    team_id: volt.extract.RouteParam("team_id"),
    user_id: volt.extract.RouteParam("user_id")
) !volt.Response {
    _ = state;

    const team = team_id.value orelse {
        return volt.Response.text(ctx.req_arena, .bad_request, "Missing route parameter: team_id", null);
    };

    const user = user_id.value orelse {
        return volt.Response.text(ctx.req_arena, .bad_request, "Missing route parameter: user_id", null);
    };

    return volt.Response.text(
        ctx.req_arena,
        .ok,
        try std.fmt.allocPrint(ctx.req_arena, "team={s}, user={s}", .{ team, user }),
        null,
    );
}
```

### Typed Query Extraction

Behavior notes:

- TypedQuery matches query parameter names directly to struct field names (encoded names are not matched).
- TypedQuery applies single-pass URL decoding to matched values (`%XX` and `+` as space).
- Handler extractor field:
    - `result`: `QueryError!?*T`

```zig
const UserFilters = struct {
    name: ?[]const u8,
    role: ?[]const u8,
    active: ?[]const u8,
};

fn listUsers(
    ctx: volt.Context,
    state: AppState,
    filters_query: volt.extract.TypedQuery(UserFilters)
) !volt.Response {
    _ = state;

    const filters = filters_query.result catch |err| {
        return volt.Response.text(ctx.req_arena, .bad_request, @errorName(err), null);
    } orelse return volt.Response.text(ctx.req_arena, .ok, "No filters provided", null);

    if (filters.name) |name| {
        return volt.Response.text(ctx.req_arena, .ok, name, null);
    }

    return volt.Response.text(ctx.req_arena, .ok, "No filters provided", null);
}
```

## Response Types

Volt provides convenient response creation methods:

```zig
// JSON responses
return volt.Response.json(ctx.req_arena, .ok, "{\"status\": \"success\"}", null);

// Plain text responses
return volt.Response.text(ctx.req_arena, .ok, "Hello, World!", null);

// Error responses
return volt.Response.internal_server_error(ctx.req_arena, "Something went wrong", null);

// No-op response for handlers that already wrote to the socket
// (for example after a successful WebSocket upgrade)
return volt.Response.empty;
```

## Application State

Use `Router(State)` to provide application state to handlers. For shared mutable
state, you can pass a pointer type (for example `*AppState`) as the router state parameter.

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

const Server = volt.Server;
const AppRouter = volt.Router(*AppState);

// Access state in handlers
fn myHandler(ctx: volt.Context, state: *AppState) !volt.Response {
    try state.mutex.lock(ctx.io);
    defer state.mutex.unlock(ctx.io);

    // Use state.database, state.cache, etc.
    return volt.Response.text(ctx.req_arena, .ok, "Success", null);
}
```

## Examples

### HTTP Server Example

```zig
const std = @import("std");
const volt = @import("volt");

const AppState = struct {};

const Server = volt.Server;
const AppRouter = volt.Router(*AppState);

pub fn main(init: std.process.Init) !void {
    var state: AppState = .{};
    var server = try Server.init(init.io, .{});
    var router: AppRouter = .init(init.gpa, &state);
    defer router.deinit(init.gpa);

    try router.get(init.gpa, "/", &indexHandler);
    try router.post(init.gpa, "/echo", &echoHandler);

    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 8080);
    try server.listen(*AppState, init.gpa, address, &router);
}

fn indexHandler(ctx: volt.Context, state: *AppState) !volt.Response {
    _ = state;
    return .text(ctx.req_arena, .ok, "Hello from Volt!", null);
}

fn echoHandler(ctx: volt.Context, state: *AppState, body: volt.extract.Json(EchoRequest)) !volt.Response {
    _ = state;

    const request = body.result catch |err| {
        return .text(ctx.req_arena, .bad_request, @errorName(err), null);
    };

    return .text(ctx.req_arena, .ok, request.message, null);
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

const Server = volt.Server;
const AppRouter = volt.Router(*AppState);

pub fn main(init: std.process.Init) !void {
    var state: AppState = .{};
    var server = try Server.init(init.io, .{});
    var router: AppRouter = .init(init.gpa, &state);
    defer router.deinit(init.gpa);

    try router.get(init.gpa, "/ws", &webSocketHandler);

    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 8080);
    try server.listen(*AppState, init.gpa, address, &router);
}

fn webSocketHandler(ctx: volt.Context, state: *AppState, ws: volt.extract.WebSocket) !volt.Response {
    try ws.onConnected(handleConnection, .{ ctx, state });
    return volt.Response.empty;
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

Volt handlers should allocate with the request allocator only:

- **Request Allocator** (`ctx.req_arena`): Temporary allocations for parsing, string manipulation, and response construction. Automatically freed after the request completes.

For long-lived allocations used by application state updates, include an allocator in the state struct itself. This keeps ownership explicit and allows manual deinitialization when the server stops.

```zig
const AppState = struct {
    allocator: std.mem.Allocator,
    cache: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) AppState {
        return .{
            .allocator = allocator,
            .cache = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *AppState) void {
        self.cache.deinit();
    }
};

fn myHandler(ctx: volt.Context, state: AppState) !volt.Response {
    // Use req_arena for temporary work
    const temp_buffer = try ctx.req_arena.alloc(u8, 1024);
    _ = temp_buffer;

    // Use state allocator for persistent data
    const persistent_data = try state.allocator.dupe(u8, "persistent-value");
    try state.cache.put("key", persistent_data);

    return volt.Response.text(ctx.req_arena, .ok, "Success", null);
}
```

## Architecture

Volt is built around several key components:

- **Server**: HTTP runtime for accepting and scheduling connections
- **Router**: Type-safe routing, request handling, and parameter injection
- **Context**: Request execution context with I/O and memory resources
- **Extract**: Automatic parameter extraction (JSON, WebSocket, Query, TypedQuery, Header, RouteParam, Form)
- **Response**: HTTP response type with helper constructors and `Response.empty` for already-handled flows

## Status & Roadmap

**Current Version**: 0.0.7 (Early Development)

This is an early-stage library. While the core routing and WebSocket functionality is stable, expect breaking changes as the API matures.

### Planned Features

- **Feature Flags**: Build-time feature flags in `build.zig` to include only selected features and reduce final binary size when unused features are disabled.

- **SSL/TLS Support**: Secure HTTPS connections

- **Enhanced Error Handling**: More comprehensive error types and better error messages

- **Performance Optimizations**: Profiling and optimization based on real-world usage patterns

Contributions and feedback are welcome as we develop these features!

## Contributing

Contributions are welcome! Please feel free to submit issues and pull requests.

## License

This project is licensed under the MIT License - see the LICENSE file for details.
