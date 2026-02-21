const std = @import("std");
const context = @import("../../core/context.zig");
const registry = @import("../../core/registry.zig");
const io = @import("../../core/io.zig");
const color = @import("../../core/color.zig");

/// Parsed HTTP request parameters extracted from positional args.
pub const HttpArgs = struct {
    url: []const u8,
    headers: []const std.http.Header,
    body: ?[]const u8,
    json_mode: bool,
};

/// Parse HTTP-specific arguments from positional args.
/// Extracts URL, --header/-H pairs, --body/-d value, and --json/-j flag.
pub fn parseHttpArgs(args: []const []const u8, header_buf: []std.http.Header) !HttpArgs {
    var url: ?[]const u8 = null;
    var body: ?[]const u8 = null;
    var json_mode: bool = false;
    var header_count: usize = 0;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--header") or std.mem.eql(u8, arg, "-H")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            const header_str = args[i];
            // Parse "Name: Value" format.
            if (std.mem.indexOf(u8, header_str, ": ")) |sep| {
                if (header_count >= header_buf.len) return error.BufferTooSmall;
                header_buf[header_count] = .{
                    .name = header_str[0..sep],
                    .value = header_str[sep + 2 ..],
                };
                header_count += 1;
            } else {
                return error.InvalidArgument;
            }
        } else if (std.mem.eql(u8, arg, "--body") or std.mem.eql(u8, arg, "-d")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            body = args[i];
        } else if (std.mem.eql(u8, arg, "--json") or std.mem.eql(u8, arg, "-j")) {
            json_mode = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (url == null) {
                url = arg;
            }
        }
    }

    return .{
        .url = url orelse return error.MissingArgument,
        .headers = header_buf[0..header_count],
        .body = body,
        .json_mode = json_mode,
    };
}

/// Check if a content-type header indicates JSON.
pub fn isJsonContentType(content_type: ?[]const u8) bool {
    const ct = content_type orelse return false;
    if (std.ascii.indexOfIgnoreCase(ct, "application/json") != null) return true;
    if (std.ascii.indexOfIgnoreCase(ct, "+json") != null) return true;
    return false;
}

/// Try to pretty-print data as JSON. Returns the formatted string or error.
pub fn prettyPrintJson(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();

    return std.json.Stringify.valueAlloc(allocator, parsed.value, .{
        .whitespace = .indent_2,
    }) catch return error.OutOfMemory;
}

/// Parse the HTTP method from a subcommand string (case-insensitive).
pub fn parseMethod(subcommand: ?[]const u8) !std.http.Method {
    const sub = subcommand orelse return .GET;
    if (std.ascii.eqlIgnoreCase(sub, "get")) return .GET;
    if (std.ascii.eqlIgnoreCase(sub, "post")) return .POST;
    if (std.ascii.eqlIgnoreCase(sub, "put")) return .PUT;
    if (std.ascii.eqlIgnoreCase(sub, "delete")) return .DELETE;
    if (std.ascii.eqlIgnoreCase(sub, "patch")) return .PATCH;
    if (std.ascii.eqlIgnoreCase(sub, "head")) return .HEAD;
    return error.InvalidArgument;
}

/// Entry point for the http command.
pub fn execute(ctx: context.Context, subcommand: ?[]const u8) anyerror!void {
    const method = parseMethod(subcommand) catch {
        const writer = ctx.stderrWriter();
        try writer.print("http: unknown method '{s}'\n", .{subcommand.?});
        try writer.print("Available methods: get, post, put, delete, patch, head\n", .{});
        return error.InvalidArgument;
    };

    var header_buf: [32]std.http.Header = undefined;
    const http_args = parseHttpArgs(ctx.args, &header_buf) catch |err| {
        const writer = ctx.stderrWriter();
        switch (err) {
            error.MissingArgument => {
                try writer.print("http: URL required\n", .{});
                try writer.print("Usage: zuxi http [get|post] <url> [--header \"Name: Value\"] [--body data] [--json]\n", .{});
            },
            error.InvalidArgument => try writer.print("http: invalid header format. Use 'Name: Value'\n", .{}),
            else => try writer.print("http: error parsing arguments\n", .{}),
        }
        return err;
    };

    // Build request headers.
    var request_headers: std.http.Client.Request.Headers = .{};
    if (http_args.json_mode) {
        request_headers.content_type = .{ .override = "application/json" };
    }

    // Create HTTP client.
    var client = std.http.Client{ .allocator = ctx.allocator };
    defer client.deinit();

    const uri = std.Uri.parse(http_args.url) catch {
        const writer = ctx.stderrWriter();
        try writer.print("http: invalid URL '{s}'\n", .{http_args.url});
        return error.InvalidInput;
    };

    // Create request.
    var req = client.request(method, uri, .{
        .extra_headers = http_args.headers,
        .headers = request_headers,
        .redirect_behavior = @enumFromInt(@as(u16, 3)),
    }) catch {
        const writer = ctx.stderrWriter();
        try writer.print("http: connection failed to {s}\n", .{http_args.url});
        return error.IoError;
    };
    defer req.deinit();

    // Send request body.
    if (http_args.body) |body_data| {
        const body_buf = try ctx.allocator.alloc(u8, body_data.len);
        defer ctx.allocator.free(body_buf);
        @memcpy(body_buf, body_data);
        req.sendBodyComplete(body_buf) catch {
            const writer = ctx.stderrWriter();
            try writer.print("http: failed to send request body\n", .{});
            return error.IoError;
        };
    } else if (method.requestHasBody()) {
        // POST/PUT/PATCH without explicit body: send empty body.
        req.transfer_encoding = .{ .content_length = 0 };
        var empty_buf: [1]u8 = .{0};
        var bw = req.sendBodyUnflushed(&empty_buf) catch {
            const writer = ctx.stderrWriter();
            try writer.print("http: failed to send request\n", .{});
            return error.IoError;
        };
        bw.end() catch return error.IoError;
        req.connection.?.flush() catch return error.IoError;
    } else {
        req.sendBodiless() catch {
            const writer = ctx.stderrWriter();
            try writer.print("http: failed to send request\n", .{});
            return error.IoError;
        };
    }

    // Receive response head.
    var redirect_buf: [8192]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch {
        const writer = ctx.stderrWriter();
        try writer.print("http: failed to receive response\n", .{});
        return error.IoError;
    };

    const stdout = ctx.stdoutWriter();
    const status_code = @intFromEnum(response.head.status);
    const use_stdout_color = !ctx.flags.no_color and io.isTty(ctx.stdout);

    // Print status line with color based on status code range.
    if (use_stdout_color) {
        const status_color = if (status_code >= 200 and status_code < 300)
            color.green
        else if (status_code >= 300 and status_code < 400)
            color.yellow
        else
            color.red;
        try stdout.writeAll(status_color);
    }
    try stdout.print("HTTP {d} {s}", .{ status_code, response.head.reason });
    if (use_stdout_color) {
        try stdout.writeAll(color.reset);
    }
    try stdout.writeByte('\n');

    // Print response headers with colored names.
    var header_iter = response.head.iterateHeaders();
    while (header_iter.next()) |header| {
        if (use_stdout_color) {
            try color.colorize(stdout, header.name, color.cyan, false);
            try stdout.print(": {s}\n", .{header.value});
        } else {
            try stdout.print("{s}: {s}\n", .{ header.name, header.value });
        }
    }
    try stdout.print("\n", .{});

    // Save content type before reading body (reader invalidates head strings).
    const is_json_response = http_args.json_mode or isJsonContentType(response.head.content_type);

    // Read response body.
    var transfer_buf: [8192]u8 = undefined;
    const body_reader = response.reader(&transfer_buf);
    const response_body = body_reader.allocRemaining(ctx.allocator, @enumFromInt(io.max_input_size)) catch {
        const warn_writer = ctx.stderrWriter();
        warn_writer.print("http: warning: failed to read response body\n", .{}) catch {};
        return;
    };
    defer ctx.allocator.free(response_body);

    if (response_body.len == 0) return;

    // Pretty-print JSON if applicable.
    if (is_json_response) {
        if (prettyPrintJson(ctx.allocator, response_body)) |formatted| {
            defer ctx.allocator.free(formatted);
            if (color.shouldColor(ctx)) {
                try color.writeColoredJson(stdout, formatted, false);
                try stdout.writeByte('\n');
            } else {
                // Build complete output in one write to avoid file truncation with --output.
                const out = try ctx.allocator.alloc(u8, formatted.len + 1);
                defer ctx.allocator.free(out);
                @memcpy(out[0..formatted.len], formatted);
                out[formatted.len] = '\n';
                try io.writeOutput(ctx, out);
            }
            return;
        } else |_| {
            // Not valid JSON; fall through to raw output.
        }
    }

    // Build complete output in one write to avoid file truncation with --output.
    const needs_newline = response_body.len > 0 and response_body[response_body.len - 1] != '\n';
    if (needs_newline) {
        const out = try ctx.allocator.alloc(u8, response_body.len + 1);
        defer ctx.allocator.free(out);
        @memcpy(out[0..response_body.len], response_body);
        out[response_body.len] = '\n';
        try io.writeOutput(ctx, out);
    } else {
        try io.writeOutput(ctx, response_body);
    }
}

/// Command definition for registration.
pub const command = registry.Command{
    .name = "http",
    .description = "HTTP client (GET, POST, PUT, DELETE)",
    .category = .dev,
    .subcommands = &.{ "get", "post", "put", "delete", "patch", "head" },
    .execute = execute,
};

// --- Tests ---

test "parseHttpArgs extracts URL" {
    const args = [_][]const u8{"https://example.com"};
    var hbuf: [8]std.http.Header = undefined;
    const result = try parseHttpArgs(&args, &hbuf);
    try std.testing.expectEqualStrings("https://example.com", result.url);
    try std.testing.expect(result.body == null);
    try std.testing.expect(!result.json_mode);
    try std.testing.expectEqual(@as(usize, 0), result.headers.len);
}

test "parseHttpArgs with headers" {
    const args = [_][]const u8{ "https://api.example.com", "--header", "Authorization: Bearer token123", "-H", "Accept: application/json" };
    var hbuf: [8]std.http.Header = undefined;
    const result = try parseHttpArgs(&args, &hbuf);
    try std.testing.expectEqualStrings("https://api.example.com", result.url);
    try std.testing.expectEqual(@as(usize, 2), result.headers.len);
    try std.testing.expectEqualStrings("Authorization", result.headers[0].name);
    try std.testing.expectEqualStrings("Bearer token123", result.headers[0].value);
    try std.testing.expectEqualStrings("Accept", result.headers[1].name);
    try std.testing.expectEqualStrings("application/json", result.headers[1].value);
}

test "parseHttpArgs with body" {
    const args = [_][]const u8{ "https://api.example.com", "--body", "{\"key\":\"value\"}" };
    var hbuf: [8]std.http.Header = undefined;
    const result = try parseHttpArgs(&args, &hbuf);
    try std.testing.expectEqualStrings("https://api.example.com", result.url);
    try std.testing.expectEqualStrings("{\"key\":\"value\"}", result.body.?);
}

test "parseHttpArgs with short body flag" {
    const args = [_][]const u8{ "https://api.example.com", "-d", "data" };
    var hbuf: [8]std.http.Header = undefined;
    const result = try parseHttpArgs(&args, &hbuf);
    try std.testing.expectEqualStrings("data", result.body.?);
}

test "parseHttpArgs with json flag" {
    const args = [_][]const u8{ "https://api.example.com", "--json" };
    var hbuf: [8]std.http.Header = undefined;
    const result = try parseHttpArgs(&args, &hbuf);
    try std.testing.expect(result.json_mode);
}

test "parseHttpArgs with short json flag" {
    const args = [_][]const u8{ "https://api.example.com", "-j" };
    var hbuf: [8]std.http.Header = undefined;
    const result = try parseHttpArgs(&args, &hbuf);
    try std.testing.expect(result.json_mode);
}

test "parseHttpArgs all options combined" {
    const args = [_][]const u8{ "https://api.example.com/data", "-H", "Content-Type: application/json", "--body", "{\"a\":1}", "--json" };
    var hbuf: [8]std.http.Header = undefined;
    const result = try parseHttpArgs(&args, &hbuf);
    try std.testing.expectEqualStrings("https://api.example.com/data", result.url);
    try std.testing.expectEqual(@as(usize, 1), result.headers.len);
    try std.testing.expectEqualStrings("{\"a\":1}", result.body.?);
    try std.testing.expect(result.json_mode);
}

test "parseHttpArgs missing URL" {
    const args = [_][]const u8{ "--json", "--header", "X-Key: val" };
    var hbuf: [8]std.http.Header = undefined;
    const result = parseHttpArgs(&args, &hbuf);
    try std.testing.expectError(error.MissingArgument, result);
}

test "parseHttpArgs empty args" {
    const args = [_][]const u8{};
    var hbuf: [8]std.http.Header = undefined;
    const result = parseHttpArgs(&args, &hbuf);
    try std.testing.expectError(error.MissingArgument, result);
}

test "parseHttpArgs header missing value" {
    const args = [_][]const u8{ "https://example.com", "--header" };
    var hbuf: [8]std.http.Header = undefined;
    const result = parseHttpArgs(&args, &hbuf);
    try std.testing.expectError(error.MissingArgument, result);
}

test "parseHttpArgs body missing value" {
    const args = [_][]const u8{ "https://example.com", "--body" };
    var hbuf: [8]std.http.Header = undefined;
    const result = parseHttpArgs(&args, &hbuf);
    try std.testing.expectError(error.MissingArgument, result);
}

test "parseHttpArgs invalid header format" {
    const args = [_][]const u8{ "https://example.com", "--header", "NoColonSpace" };
    var hbuf: [8]std.http.Header = undefined;
    const result = parseHttpArgs(&args, &hbuf);
    try std.testing.expectError(error.InvalidArgument, result);
}

test "isJsonContentType detects JSON" {
    try std.testing.expect(isJsonContentType("application/json"));
    try std.testing.expect(isJsonContentType("application/json; charset=utf-8"));
    try std.testing.expect(isJsonContentType("application/vnd.api+json"));
    try std.testing.expect(!isJsonContentType("text/html"));
    try std.testing.expect(!isJsonContentType("text/plain"));
    try std.testing.expect(!isJsonContentType(null));
}

test "prettyPrintJson formats valid JSON" {
    const allocator = std.testing.allocator;
    const result = try prettyPrintJson(allocator, "{\"a\":1,\"b\":2}");
    defer allocator.free(result);
    // Should contain indentation.
    try std.testing.expect(std.mem.indexOf(u8, result, "  ") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"a\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"b\"") != null);
}

test "prettyPrintJson rejects invalid JSON" {
    const allocator = std.testing.allocator;
    const result = prettyPrintJson(allocator, "not json");
    try std.testing.expectError(error.SyntaxError, result);
}

test "parseMethod returns correct methods" {
    try std.testing.expectEqual(std.http.Method.GET, try parseMethod(null));
    try std.testing.expectEqual(std.http.Method.GET, try parseMethod("get"));
    try std.testing.expectEqual(std.http.Method.POST, try parseMethod("post"));
    try std.testing.expectEqual(std.http.Method.PUT, try parseMethod("put"));
    try std.testing.expectEqual(std.http.Method.DELETE, try parseMethod("delete"));
    try std.testing.expectEqual(std.http.Method.PATCH, try parseMethod("patch"));
    try std.testing.expectEqual(std.http.Method.HEAD, try parseMethod("head"));
}

test "parseMethod accepts uppercase methods" {
    try std.testing.expectEqual(std.http.Method.GET, try parseMethod("GET"));
    try std.testing.expectEqual(std.http.Method.POST, try parseMethod("POST"));
    try std.testing.expectEqual(std.http.Method.PUT, try parseMethod("Put"));
    try std.testing.expectEqual(std.http.Method.DELETE, try parseMethod("DELETE"));
}

test "parseMethod rejects unknown method" {
    const result = parseMethod("foobar");
    try std.testing.expectError(error.InvalidArgument, result);
}

test "prettyPrintJson output has no ANSI codes" {
    // prettyPrintJson returns plain JSON without ANSI codes; color is applied separately.
    const allocator = std.testing.allocator;
    const result = try prettyPrintJson(allocator, "{\"status\":\"ok\",\"code\":200}");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\x1b[") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"status\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "200") != null);
}

test "http command struct fields" {
    try std.testing.expectEqualStrings("http", command.name);
    try std.testing.expectEqual(registry.Category.dev, command.category);
    try std.testing.expectEqual(@as(usize, 6), command.subcommands.len);
}

test "cli passes unknown flags as positional args after command" {
    // This tests the cli.zig change that allows command-specific flags.
    const cli = @import("../../core/cli.zig");
    const args = [_][]const u8{ "http", "get", "https://example.com", "--header", "X-Key: val", "--json" };
    var pbuf: [16][]const u8 = undefined;
    const result = try cli.parseArgs(&args, &pbuf);
    switch (result) {
        .command => |inv| {
            try std.testing.expectEqualStrings("http", inv.command_name);
            try std.testing.expectEqualStrings("get", inv.subcommand.?);
            // URL + --header + "X-Key: val" + --json = 4 positional args.
            try std.testing.expectEqual(@as(usize, 4), inv.positional_args.len);
            try std.testing.expectEqualStrings("https://example.com", inv.positional_args[0]);
            try std.testing.expectEqualStrings("--header", inv.positional_args[1]);
            try std.testing.expectEqualStrings("X-Key: val", inv.positional_args[2]);
            try std.testing.expectEqualStrings("--json", inv.positional_args[3]);
        },
        else => return error.InvalidInput,
    }
}
