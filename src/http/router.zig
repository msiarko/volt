//! HTTP Router implementation with automatic parameter injection.
//!
//! This module provides a type-safe HTTP router that automatically extracts
//! parameters from HTTP requests and injects them into handler functions.
//! It supports JSON deserialization, WebSocket upgrades, and custom extract support.

const std = @import("std");
const Request = std.http.Server.Request;
const Response = @import("response.zig").Response;
const Context = @import("context.zig").Context;
const extract = @import("extract");

/// Creates a generic HTTP router type parameterized by application state.
///
/// The State type parameter allows handlers to access shared application state.
/// The router automatically resolves handler parameters from the request using
/// compile-time reflection and built-in extract support.
///
/// Example:
/// ```zig
/// const MyState = struct { db: Database };
/// const MyRouter = Router(MyState);
///
/// fn myHandler(ctx: Context, state: *MyState, data: Json(MyStruct)) !Response {
///     // Parameters automatically extracted from request
///     _ = data; // JSON body deserialized to MyStruct
///     return Response.ok();
/// }
/// ```
pub fn Router(comptime State: type) type {
    return struct {
        const Self = @This();

        /// Memory allocator for route storage
        allocator: std.mem.Allocator,
        /// Map of route paths to their handlers
        routes: std.StringHashMap(RouteEntry),

        /// Virtual table for type-erased handler execution
        const VTable = struct {
            execute: *const fn (*const anyopaque, Context, *State, req: *Request) anyerror!Response,
        };

        /// Type-erased handler wrapper that provides dynamic dispatch
        const Handler = struct {
            /// Pointer to the handler function
            ptr: *const anyopaque,
            /// Virtual table for execution
            vtable: VTable,

            /// Creates a new Handler instance from a function pointer.
            ///
            /// Parameters:
            /// - `HandlerFunction`: The function pointer type
            /// - `h`: Pointer to the handler function
            ///
            /// Returns: Initialized Handler with vtable
            pub fn init(comptime HandlerFunction: type, h: *const anyopaque) @This() {
                const impl = struct {
                    fn exec(ptr: *const anyopaque, ctx: Context, state: *State, req: *Request) !Response {
                        const values = .{ ctx, state };
                        const params = extract.resolveParams(
                            HandlerFunction,
                            @TypeOf(values),
                            ctx.request_allocator,
                            values,
                            req,
                        );
                        const fun: HandlerFunction = @ptrCast(@alignCast(ptr));
                        return @call(.auto, fun, params);
                    }
                };

                return .{
                    .ptr = h,
                    .vtable = .{
                        .execute = impl.exec,
                    },
                };
            }

            /// Executes the handler with the given context, state, and request.
            ///
            /// Parameters:
            /// - `ctx`: Request context containing I/O and allocators
            /// - `state`: Reference to shared application state
            /// - `req`: HTTP request to process
            ///
            /// Returns: HTTP response from the handler
            pub fn execute(self: *const Handler, ctx: Context, state: *State, req: *Request) !Response {
                return self.vtable.execute(self.ptr, ctx, state, req);
            }
        };

        /// Route entry containing handlers for different HTTP methods
        const RouteEntry = struct {
            /// Map of HTTP methods to their handlers
            handlers: std.AutoHashMap(std.http.Method, Handler),
        };

        /// Initializes a new router instance.
        ///
        /// Parameters:
        /// - `allocator`: Memory allocator for route storage
        ///
        /// Returns: Initialized router ready to register routes
        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator, .routes = .init(allocator) };
        }

        /// Cleans up router resources.
        ///
        /// This method should be called when the router is no longer needed
        /// to free all allocated route handlers and mappings.
        pub fn deinit(self: *Self) void {
            var it = self.routes.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.handlers.deinit();
            }

            self.routes.deinit();
        }

        /// Registers a GET route handler.
        ///
        /// Parameters:
        /// - `path`: Route path (e.g., "/users", "/api/v1/data")
        /// - `handler`: Function that handles GET requests to this path
        ///
        /// The handler function signature should be:
        /// `fn(ctx: Context, state: *State, ...) !Response`
        pub fn get(self: *Self, path: []const u8, handler: anytype) !void {
            try self.addRoute(.GET, path, makeHandler(handler));
        }

        /// Registers a POST route handler.
        ///
        /// Parameters:
        /// - `path`: Route path
        /// - `handler`: Function that handles POST requests to this path
        pub fn post(self: *Self, path: []const u8, handler: anytype) !void {
            try self.addRoute(.POST, path, makeHandler(handler));
        }

        /// Registers a PUT route handler.
        ///
        /// Parameters:
        /// - `path`: Route path
        /// - `handler`: Function that handles PUT requests to this path
        pub fn put(self: *Self, path: []const u8, handler: anytype) !void {
            try self.addRoute(.PUT, path, makeHandler(handler));
        }

        /// Registers a DELETE route handler.
        ///
        /// Parameters:
        /// - `path`: Route path
        /// - `handler`: Function that handles DELETE requests to this path
        pub fn delete(self: *Self, path: []const u8, handler: anytype) !void {
            try self.addRoute(.DELETE, path, makeHandler(handler));
        }

        /// Registers a PATCH route handler.
        ///
        /// Parameters:
        /// - `path`: Route path
        /// - `handler`: Function that handles PATCH requests to this path
        pub fn patch(self: *Self, path: []const u8, handler: anytype) !void {
            try self.addRoute(.PATCH, path, makeHandler(handler));
        }

        fn addRoute(self: *Self, method: std.http.Method, path: []const u8, handler: Handler) !void {
            var res = try self.routes.getOrPut(path);
            if (!res.found_existing) {
                res.value_ptr.* = .{
                    .handlers = .init(self.allocator),
                };
            }

            try res.value_ptr.handlers.put(method, handler);
        }

        fn makeHandler(handler: anytype) Handler {
            const FuncPtr = @TypeOf(handler);
            const func_ptr_info = @typeInfo(FuncPtr);
            if (func_ptr_info != .pointer or !func_ptr_info.pointer.is_const) {
                @compileError("handler must be a const pointer type");
            }

            const func_type_info = @typeInfo(func_ptr_info.pointer.child);
            if (func_type_info != .@"fn") {
                @compileError("handler must be a const pointer type to a function");
            }

            const RetType = func_type_info.@"fn".return_type.?;
            const ret_type_info = @typeInfo(RetType);
            if (ret_type_info != .error_union or ret_type_info.error_union.payload != Response) {
                @compileError("handler must return !Response");
            }

            return .init(FuncPtr, @ptrCast(handler));
        }
    };
}
