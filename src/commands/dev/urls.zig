const std = @import("std");
const context = @import("../../core/context.zig");
const registry = @import("../../core/registry.zig");
const io = @import("../../core/io.zig");

/// Entry point for the urls command.
/// Extracts URLs from input text.
pub fn execute(ctx: context.Context, subcommand: ?[]const u8) anyerror!void {
    const mode: enum { default, strict } = if (subcommand) |sub| blk: {
        if (std.mem.eql(u8, sub, "strict")) break :blk .strict;
        const writer = ctx.stderrWriter();
        try writer.print("urls: unknown subcommand '{s}'\n", .{sub});
        try writer.print("Available subcommands: strict\n", .{});
        return error.InvalidArgument;
    } else .default;

    const input = try io.getInput(ctx) orelse {
        const writer = ctx.stderrWriter();
        try writer.print("urls: no input provided\n", .{});
        try writer.print("Usage: zuxi urls [strict] <text>\n", .{});
        try writer.print("       echo 'text with URLs' | zuxi urls\n", .{});
        return error.MissingArgument;
    };
    defer input.deinit(ctx.allocator);

    if (input.data.len == 0) {
        return;
    }

    var list = std.ArrayList(u8){};
    defer list.deinit(ctx.allocator);

    var found: usize = 0;
    var i: usize = 0;
    while (i < input.data.len) {
        if (matchUrlAt(input.data, i)) |url_end| {
            const url = input.data[i..url_end];
            if (mode == .strict) {
                if (validateUrlStructure(url)) {
                    try list.appendSlice(ctx.allocator, url);
                    try list.append(ctx.allocator, '\n');
                    found += 1;
                }
            } else {
                try list.appendSlice(ctx.allocator, url);
                try list.append(ctx.allocator, '\n');
                found += 1;
            }
            i = url_end;
        } else {
            i += 1;
        }
    }

    if (found > 0) {
        try io.writeOutput(ctx, list.items);
    }
}

/// Try to match a URL starting at position `start` in `data`.
/// Returns the end index (exclusive) of the URL, or null if no URL starts here.
fn matchUrlAt(data: []const u8, start: usize) ?usize {
    // Check for http:// or https://
    if (start + 8 > data.len) return null;

    const has_https = std.mem.startsWith(u8, data[start..], "https://");
    const has_http = std.mem.startsWith(u8, data[start..], "http://");

    if (!has_https and !has_http) return null;

    const scheme_end = if (has_https) start + 8 else start + 7;

    // Must have at least one character after the scheme
    if (scheme_end >= data.len) return null;

    // The character right after :// must be a valid host start character
    if (!isUrlHostChar(data[scheme_end])) return null;

    // Scan forward to find the end of the URL
    var end = scheme_end;
    var paren_depth: i32 = 0;
    while (end < data.len) {
        const c = data[end];
        if (c == '(') {
            paren_depth += 1;
            end += 1;
        } else if (c == ')') {
            if (paren_depth > 0) {
                paren_depth -= 1;
                end += 1;
            } else {
                break;
            }
        } else if (isUrlChar(c)) {
            end += 1;
        } else {
            break;
        }
    }

    // Strip trailing punctuation that's likely not part of the URL
    while (end > scheme_end and isTrailingPunctuation(data[end - 1])) {
        end -= 1;
    }

    if (end <= scheme_end) return null;

    return end;
}

/// Characters valid in a URL host (domain name start).
fn isUrlHostChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '['; // IPv6
}

/// Characters that can appear in a URL.
fn isUrlChar(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9' => true,
        '-', '.', '_', '~', ':', '/', '?', '#', '[', ']', '@' => true,
        '!', '$', '&', '\'', '*', '+', ',', ';', '=' => true,
        '%' => true, // percent-encoded
        else => false,
    };
}

/// Trailing punctuation that should be stripped from URLs.
fn isTrailingPunctuation(c: u8) bool {
    return c == '.' or c == ',' or c == ';' or c == ':' or c == '!' or c == '?';
}

/// Validate URL structure more strictly:
/// - Must have a valid host (at least one dot in domain, or localhost, or IP)
/// - Must not have empty host
fn validateUrlStructure(url: []const u8) bool {
    // Find the scheme end
    const scheme_end = if (std.mem.startsWith(u8, url, "https://"))
        @as(usize, 8)
    else if (std.mem.startsWith(u8, url, "http://"))
        @as(usize, 7)
    else
        return false;

    if (scheme_end >= url.len) return false;

    // Extract host (up to first /, ?, #, or end)
    var host_end = scheme_end;
    while (host_end < url.len) {
        if (url[host_end] == '/' or url[host_end] == '?' or url[host_end] == '#') break;
        host_end += 1;
    }

    const host_with_port = url[scheme_end..host_end];
    if (host_with_port.len == 0) return false;

    // Strip port if present
    var host = host_with_port;
    if (std.mem.lastIndexOf(u8, host_with_port, ":")) |colon_pos| {
        // Check if everything after the colon is digits (port number)
        const after_colon = host_with_port[colon_pos + 1 ..];
        var all_digits = true;
        for (after_colon) |c| {
            if (!std.ascii.isDigit(c)) {
                all_digits = false;
                break;
            }
        }
        if (all_digits and after_colon.len > 0) {
            host = host_with_port[0..colon_pos];
        }
    }

    if (host.len == 0) return false;

    // Accept localhost
    if (std.mem.eql(u8, host, "localhost")) return true;

    // Accept IPv4-like (all digits and dots)
    if (looksLikeIpv4(host)) return true;

    // Accept IPv6 (starts with [)
    if (host[0] == '[') return true;

    // Domain must have at least one dot
    if (std.mem.indexOf(u8, host, ".") == null) return false;

    // TLD must be at least 2 characters
    if (std.mem.lastIndexOf(u8, host, ".")) |dot_pos| {
        const tld = host[dot_pos + 1 ..];
        if (tld.len < 2) return false;
    }

    return true;
}

fn looksLikeIpv4(host: []const u8) bool {
    var dot_count: usize = 0;
    for (host) |c| {
        if (c == '.') {
            dot_count += 1;
        } else if (!std.ascii.isDigit(c)) {
            return false;
        }
    }
    return dot_count == 3;
}

/// Command definition for registration.
pub const command = registry.Command{
    .name = "urls",
    .description = "Extract URLs from text",
    .category = .dev,
    .subcommands = &.{"strict"},
    .execute = execute,
};

// --- Tests ---

fn execWithInput(input: []const u8, subcommand: ?[]const u8) ![]u8 {
    const allocator = std.testing.allocator;
    const tmp_out = "zuxi_test_urls_out.tmp";

    const out_file = try std.fs.cwd().createFile(tmp_out, .{});

    const args = [_][]const u8{input};
    var ctx = context.Context.initDefault(allocator);
    ctx.args = &args;
    ctx.stdout = out_file;

    execute(ctx, subcommand) catch |err| {
        out_file.close();
        std.fs.cwd().deleteFile(tmp_out) catch {};
        return err;
    };
    out_file.close();

    const file = try std.fs.cwd().openFile(tmp_out, .{});
    defer file.close();
    defer std.fs.cwd().deleteFile(tmp_out) catch {};
    return try file.readToEndAlloc(allocator, io.max_input_size);
}

test "urls extracts simple http URL" {
    const output = try execWithInput("visit http://example.com today", null);
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("http://example.com", trimmed);
}

test "urls extracts https URL" {
    const output = try execWithInput("go to https://example.com/path", null);
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("https://example.com/path", trimmed);
}

test "urls extracts multiple URLs" {
    const output = try execWithInput("see http://a.com and https://b.org/x", null);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "http://a.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "https://b.org/x") != null);
}

test "urls extracts URL with query string" {
    const output = try execWithInput("link: https://example.com/search?q=test&page=1", null);
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("https://example.com/search?q=test&page=1", trimmed);
}

test "urls extracts URL with fragment" {
    const output = try execWithInput("see https://example.com/docs#section", null);
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("https://example.com/docs#section", trimmed);
}

test "urls strips trailing punctuation" {
    const output = try execWithInput("visit http://example.com.", null);
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("http://example.com", trimmed);
}

test "urls no URLs found returns empty" {
    const output = try execWithInput("no urls here", null);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqual(@as(usize, 0), output.len);
}

test "urls strict mode validates structure" {
    const output = try execWithInput("good: https://example.com bad: http://notadomain", "strict");
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("https://example.com", trimmed);
}

test "urls strict mode accepts localhost" {
    const output = try execWithInput("http://localhost:8080/api", "strict");
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("http://localhost:8080/api", trimmed);
}

test "urls strict mode accepts IP addresses" {
    const output = try execWithInput("http://192.168.1.1/path", "strict");
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("http://192.168.1.1/path", trimmed);
}

test "urls strict mode rejects short TLD" {
    const output = try execWithInput("http://example.x", "strict");
    defer std.testing.allocator.free(output);
    try std.testing.expectEqual(@as(usize, 0), output.len);
}

test "urls handles URL with port" {
    const output = try execWithInput("http://example.com:8080/path", null);
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("http://example.com:8080/path", trimmed);
}

test "urls empty input" {
    const output = try execWithInput("", null);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqual(@as(usize, 0), output.len);
}

test "urls unknown subcommand" {
    const result = execWithInput("test", "invalid");
    try std.testing.expectError(error.InvalidArgument, result);
}

test "urls command struct fields" {
    try std.testing.expectEqualStrings("urls", command.name);
    try std.testing.expectEqual(registry.Category.dev, command.category);
    try std.testing.expectEqual(@as(usize, 1), command.subcommands.len);
}

test "validateUrlStructure valid domains" {
    try std.testing.expect(validateUrlStructure("https://example.com"));
    try std.testing.expect(validateUrlStructure("http://sub.example.com/path"));
    try std.testing.expect(validateUrlStructure("https://localhost/api"));
    try std.testing.expect(validateUrlStructure("http://192.168.1.1"));
    try std.testing.expect(validateUrlStructure("http://example.com:3000"));
}

test "validateUrlStructure invalid domains" {
    try std.testing.expect(!validateUrlStructure("http://nodot"));
    try std.testing.expect(!validateUrlStructure("http://example.x"));
    try std.testing.expect(!validateUrlStructure("ftp://example.com"));
}

test "matchUrlAt basic" {
    const data = "visit http://example.com today";
    const end = matchUrlAt(data, 6);
    try std.testing.expect(end != null);
    try std.testing.expectEqualStrings("http://example.com", data[6..end.?]);
}

test "matchUrlAt no match" {
    const data = "no url here";
    try std.testing.expect(matchUrlAt(data, 0) == null);
}

test "urls handles parentheses in URLs" {
    const output = try execWithInput("see https://en.wikipedia.org/wiki/Zig_(programming_language) here", null);
    defer std.testing.allocator.free(output);
    const trimmed = std.mem.trimRight(u8, output, &std.ascii.whitespace);
    try std.testing.expectEqualStrings("https://en.wikipedia.org/wiki/Zig_(programming_language)", trimmed);
}
