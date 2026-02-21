const std = @import("std");
const context = @import("../../core/context.zig");
const registry = @import("../../core/registry.zig");
const io = @import("../../core/io.zig");

/// Parsed serve arguments.
const ServeArgs = struct {
    port: u16,
    dir: []const u8,
};

/// Parse serve-specific arguments from positional args.
/// Supports: --port <num>, --dir <path>, or just a port number as positional arg.
fn parseServeArgs(args: []const []const u8) ServeArgs {
    var port: u16 = 8080;
    var dir: []const u8 = ".";

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--port") or std.mem.eql(u8, arg, "-p")) {
            i += 1;
            if (i < args.len) {
                port = std.fmt.parseInt(u16, args[i], 10) catch 8080;
            }
        } else if (std.mem.eql(u8, arg, "--dir") or std.mem.eql(u8, arg, "-d")) {
            i += 1;
            if (i < args.len) {
                dir = args[i];
            }
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            // Plain number = port.
            port = std.fmt.parseInt(u16, arg, 10) catch port;
        }
    }

    return .{ .port = port, .dir = dir };
}

/// Get MIME type from file extension.
fn getMimeType(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    if (ext.len == 0) return "application/octet-stream";

    if (std.mem.eql(u8, ext, ".html") or std.mem.eql(u8, ext, ".htm")) return "text/html; charset=utf-8";
    if (std.mem.eql(u8, ext, ".css")) return "text/css; charset=utf-8";
    if (std.mem.eql(u8, ext, ".js")) return "application/javascript; charset=utf-8";
    if (std.mem.eql(u8, ext, ".json")) return "application/json; charset=utf-8";
    if (std.mem.eql(u8, ext, ".xml")) return "application/xml; charset=utf-8";
    if (std.mem.eql(u8, ext, ".txt")) return "text/plain; charset=utf-8";
    if (std.mem.eql(u8, ext, ".md")) return "text/markdown; charset=utf-8";
    if (std.mem.eql(u8, ext, ".csv")) return "text/csv; charset=utf-8";
    if (std.mem.eql(u8, ext, ".png")) return "image/png";
    if (std.mem.eql(u8, ext, ".jpg") or std.mem.eql(u8, ext, ".jpeg")) return "image/jpeg";
    if (std.mem.eql(u8, ext, ".gif")) return "image/gif";
    if (std.mem.eql(u8, ext, ".svg")) return "image/svg+xml";
    if (std.mem.eql(u8, ext, ".ico")) return "image/x-icon";
    if (std.mem.eql(u8, ext, ".woff")) return "font/woff";
    if (std.mem.eql(u8, ext, ".woff2")) return "font/woff2";
    if (std.mem.eql(u8, ext, ".pdf")) return "application/pdf";
    if (std.mem.eql(u8, ext, ".zip")) return "application/zip";
    if (std.mem.eql(u8, ext, ".wasm")) return "application/wasm";
    if (std.mem.eql(u8, ext, ".yaml") or std.mem.eql(u8, ext, ".yml")) return "text/yaml; charset=utf-8";
    if (std.mem.eql(u8, ext, ".toml")) return "text/toml; charset=utf-8";
    return "application/octet-stream";
}

/// Sanitize a URL path to prevent directory traversal.
/// Returns the clean relative path or null if the path is invalid.
fn sanitizePath(url_path: []const u8) ?[]const u8 {
    // Must start with /
    if (url_path.len == 0 or url_path[0] != '/') return null;

    const path = url_path[1..]; // Strip leading /

    // Check for directory traversal.
    if (std.mem.indexOf(u8, path, "..") != null) return null;

    if (path.len == 0) return "index.html";
    return path;
}

/// Extract the request path from an HTTP request line.
/// E.g., "GET /path HTTP/1.1" -> "/path"
fn extractRequestPath(request_line: []const u8) ?[]const u8 {
    // Find first space (after method).
    const method_end = std.mem.indexOf(u8, request_line, " ") orelse return null;
    const rest = request_line[method_end + 1 ..];

    // Find second space (before protocol).
    const path_end = std.mem.indexOf(u8, rest, " ") orelse rest.len;
    const path = rest[0..path_end];

    // Strip query string.
    const query_start = std.mem.indexOf(u8, path, "?") orelse path.len;
    return path[0..query_start];
}

/// Entry point for the serve command.
pub fn execute(ctx: context.Context, _: ?[]const u8) anyerror!void {
    const args = parseServeArgs(ctx.args);

    const stderr = ctx.stderrWriter();
    try stderr.print("Serving files from '{s}' on http://localhost:{d}\n", .{ args.dir, args.port });
    try stderr.print("Press Ctrl+C to stop.\n", .{});

    // Resolve directory.
    var dir = std.fs.cwd().openDir(args.dir, .{}) catch {
        try stderr.print("serve: cannot open directory '{s}'\n", .{args.dir});
        return error.InvalidInput;
    };
    defer dir.close();

    // Start TCP server.
    const address = std.net.Address.parseIp("127.0.0.1", args.port) catch {
        try stderr.print("serve: invalid port {d}\n", .{args.port});
        return error.InvalidInput;
    };

    var server = address.listen(.{ .reuse_address = true }) catch {
        try stderr.print("serve: failed to bind to port {d}\n", .{args.port});
        return error.IoError;
    };
    defer server.deinit();

    // Accept loop.
    while (true) {
        const conn = server.accept() catch {
            try stderr.print("serve: accept error\n", .{});
            continue;
        };
        defer conn.stream.close();

        handleConnection(conn.stream, dir, stderr, ctx.allocator) catch {
            // Log error and continue serving.
        };
    }
}

/// Handle a single HTTP connection.
fn handleConnection(stream: std.net.Stream, dir: std.fs.Dir, stderr: anytype, allocator: std.mem.Allocator) !void {
    // Read request (just the first line).
    var buf: [4096]u8 = undefined;
    const n = stream.read(&buf) catch return;
    if (n == 0) return;

    const request = buf[0..n];

    // Extract first line.
    const line_end = std.mem.indexOf(u8, request, "\r\n") orelse std.mem.indexOf(u8, request, "\n") orelse n;
    const request_line = request[0..line_end];

    // Parse path.
    const url_path = extractRequestPath(request_line) orelse {
        try sendResponse(stream, "400 Bad Request", "text/plain", "Bad Request\n");
        return;
    };

    const clean_path = sanitizePath(url_path) orelse {
        try sendResponse(stream, "403 Forbidden", "text/plain", "Forbidden\n");
        return;
    };

    // Try to open file.
    const file = dir.openFile(clean_path, .{}) catch {
        try stderr.print("  404 {s}\n", .{url_path});
        try sendResponse(stream, "404 Not Found", "text/plain", "Not Found\n");
        return;
    };
    defer file.close();

    // Read file contents.
    const content = file.readToEndAlloc(allocator, 64 * 1024 * 1024) catch {
        try sendResponse(stream, "500 Internal Server Error", "text/plain", "Internal Server Error\n");
        return;
    };
    defer allocator.free(content);

    const mime_type = getMimeType(clean_path);

    try stderr.print("  200 {s} ({d} bytes)\n", .{ url_path, content.len });
    try sendResponse(stream, "200 OK", mime_type, content);
}

/// Send an HTTP response.
fn sendResponse(stream: std.net.Stream, status: []const u8, content_type: []const u8, body: []const u8) !void {
    var header_buf: [512]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ status, content_type, body.len }) catch return;
    _ = stream.write(header) catch return;
    _ = stream.write(body) catch return;
}

/// Command definition for registration.
pub const command = registry.Command{
    .name = "serve",
    .description = "Simple static HTTP file server",
    .category = .dev,
    .subcommands = &.{},
    .execute = execute,
};

// --- Tests ---
// Note: We test utility functions, not the actual server (which is long-running).

test "parseServeArgs default values" {
    const args = parseServeArgs(&.{});
    try std.testing.expectEqual(@as(u16, 8080), args.port);
    try std.testing.expectEqualStrings(".", args.dir);
}

test "parseServeArgs with port flag" {
    const a = [_][]const u8{ "--port", "3000" };
    const args = parseServeArgs(&a);
    try std.testing.expectEqual(@as(u16, 3000), args.port);
}

test "parseServeArgs with dir flag" {
    const a = [_][]const u8{ "--dir", "/tmp" };
    const args = parseServeArgs(&a);
    try std.testing.expectEqualStrings("/tmp", args.dir);
}

test "parseServeArgs with positional port" {
    const a = [_][]const u8{"9090"};
    const args = parseServeArgs(&a);
    try std.testing.expectEqual(@as(u16, 9090), args.port);
}

test "parseServeArgs with short flags" {
    const a = [_][]const u8{ "-p", "4000", "-d", "./public" };
    const args = parseServeArgs(&a);
    try std.testing.expectEqual(@as(u16, 4000), args.port);
    try std.testing.expectEqualStrings("./public", args.dir);
}

test "getMimeType html" {
    try std.testing.expectEqualStrings("text/html; charset=utf-8", getMimeType("index.html"));
    try std.testing.expectEqualStrings("text/html; charset=utf-8", getMimeType("page.htm"));
}

test "getMimeType css" {
    try std.testing.expectEqualStrings("text/css; charset=utf-8", getMimeType("style.css"));
}

test "getMimeType js" {
    try std.testing.expectEqualStrings("application/javascript; charset=utf-8", getMimeType("app.js"));
}

test "getMimeType json" {
    try std.testing.expectEqualStrings("application/json; charset=utf-8", getMimeType("data.json"));
}

test "getMimeType image types" {
    try std.testing.expectEqualStrings("image/png", getMimeType("logo.png"));
    try std.testing.expectEqualStrings("image/jpeg", getMimeType("photo.jpg"));
    try std.testing.expectEqualStrings("image/gif", getMimeType("anim.gif"));
    try std.testing.expectEqualStrings("image/svg+xml", getMimeType("icon.svg"));
}

test "getMimeType unknown extension" {
    try std.testing.expectEqualStrings("application/octet-stream", getMimeType("file.xyz"));
    try std.testing.expectEqualStrings("application/octet-stream", getMimeType("noext"));
}

test "sanitizePath normal paths" {
    try std.testing.expectEqualStrings("index.html", sanitizePath("/").?);
    try std.testing.expectEqualStrings("file.txt", sanitizePath("/file.txt").?);
    try std.testing.expectEqualStrings("dir/file.html", sanitizePath("/dir/file.html").?);
}

test "sanitizePath rejects traversal" {
    try std.testing.expect(sanitizePath("/../etc/passwd") == null);
    try std.testing.expect(sanitizePath("/..") == null);
    try std.testing.expect(sanitizePath("/foo/../bar") == null);
}

test "sanitizePath rejects invalid" {
    try std.testing.expect(sanitizePath("") == null);
    try std.testing.expect(sanitizePath("no-slash") == null);
}

test "extractRequestPath GET" {
    try std.testing.expectEqualStrings("/", extractRequestPath("GET / HTTP/1.1").?);
    try std.testing.expectEqualStrings("/index.html", extractRequestPath("GET /index.html HTTP/1.1").?);
    try std.testing.expectEqualStrings("/path/to/file", extractRequestPath("GET /path/to/file HTTP/1.1").?);
}

test "extractRequestPath strips query string" {
    try std.testing.expectEqualStrings("/search", extractRequestPath("GET /search?q=test HTTP/1.1").?);
}

test "extractRequestPath invalid" {
    try std.testing.expect(extractRequestPath("INVALID") == null);
}

test "serve command struct fields" {
    try std.testing.expectEqualStrings("serve", command.name);
    try std.testing.expectEqual(registry.Category.dev, command.category);
    try std.testing.expectEqual(@as(usize, 0), command.subcommands.len);
}
