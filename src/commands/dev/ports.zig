const std = @import("std");
const builtin = @import("builtin");
const context = @import("../../core/context.zig");
const registry = @import("../../core/registry.zig");
const io = @import("../../core/io.zig");

/// Entry point for the ports command.
/// Lists listening network ports on the system.
pub fn execute(ctx: context.Context, subcommand: ?[]const u8) anyerror!void {
    _ = subcommand;

    // Optional port filter from positional arg
    var filter_port: ?u16 = null;
    if (ctx.args.len > 0) {
        filter_port = std.fmt.parseInt(u16, ctx.args[0], 10) catch {
            const writer = ctx.stderrWriter();
            try writer.print("ports: invalid port number '{s}'\n", .{ctx.args[0]});
            try writer.print("Usage: zuxi ports [port_number]\n", .{});
            return error.InvalidArgument;
        };
    }

    var list = std.ArrayList(u8){};
    defer list.deinit(ctx.allocator);
    const writer = list.writer(ctx.allocator);

    if (comptime builtin.os.tag == .macos) {
        try listPortsMacos(ctx, writer, filter_port);
    } else if (comptime builtin.os.tag == .linux) {
        try listPortsLinux(ctx, writer, filter_port);
    } else {
        const err_writer = ctx.stderrWriter();
        try err_writer.print("ports: unsupported platform\n", .{});
        return error.NotAvailable;
    }

    try io.writeOutput(ctx, list.items);
}

/// Port entry parsed from system output.
const PortEntry = struct {
    port: u16,
    pid: []const u8,
    name: []const u8,
    proto: []const u8,
};

fn listPortsMacos(ctx: context.Context, writer: anytype, filter_port: ?u16) !void {
    // Run lsof to get listening ports
    const result = std.process.Child.run(.{
        .allocator = ctx.allocator,
        .argv = &.{ "lsof", "-iTCP", "-sTCP:LISTEN", "-nP", "-F", "pcnT" },
    }) catch {
        const err_writer = ctx.stderrWriter();
        try err_writer.print("ports: failed to run lsof (are you root or is lsof installed?)\n", .{});
        return error.NotAvailable;
    };
    defer ctx.allocator.free(result.stdout);
    defer ctx.allocator.free(result.stderr);

    // Parse lsof -F output format:
    // p<pid>\n
    // c<command>\n
    // n<name (host:port)>\n
    // T<type info>\n
    var entries = std.ArrayList(PortEntry){};
    defer entries.deinit(ctx.allocator);

    var current_pid: []const u8 = "";
    var current_name: []const u8 = "";

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        switch (line[0]) {
            'p' => {
                current_pid = line[1..];
            },
            'c' => {
                current_name = line[1..];
            },
            'n' => {
                const addr = line[1..];
                // Extract port from address like "*:8080" or "127.0.0.1:3000"
                if (std.mem.lastIndexOf(u8, addr, ":")) |colon| {
                    const port_str = addr[colon + 1 ..];
                    const port = std.fmt.parseInt(u16, port_str, 10) catch continue;

                    if (filter_port) |fp| {
                        if (port != fp) continue;
                    }

                    try entries.append(ctx.allocator, .{
                        .port = port,
                        .pid = current_pid,
                        .name = current_name,
                        .proto = "TCP",
                    });
                }
            },
            else => {},
        }
    }

    try printEntries(writer, entries.items);
}

fn listPortsLinux(ctx: context.Context, writer: anytype, filter_port: ?u16) !void {
    // Try reading /proc/net/tcp
    const tcp_file = std.fs.openFileAbsolute("/proc/net/tcp", .{}) catch {
        // Fallback: try ss command
        try listPortsLinuxSs(ctx, writer, filter_port);
        return;
    };
    defer tcp_file.close();

    const data = try tcp_file.readToEndAlloc(ctx.allocator, io.max_input_size);
    defer ctx.allocator.free(data);

    var entries = std.ArrayList(PortEntry){};
    defer entries.deinit(ctx.allocator);

    var lines = std.mem.splitScalar(u8, data, '\n');
    // Skip header line
    _ = lines.next();

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;

        // Format: sl local_address rem_address st ...
        // local_address is hex_ip:hex_port
        var fields = std.mem.tokenizeScalar(u8, trimmed, ' ');
        _ = fields.next() orelse continue; // sl
        const local_addr = fields.next() orelse continue;

        // Skip to st field
        _ = fields.next() orelse continue; // rem_address
        const state = fields.next() orelse continue; // st

        // State 0A = LISTEN
        if (!std.mem.eql(u8, state, "0A")) continue;

        // Parse port from local_address (hex_ip:hex_port)
        if (std.mem.indexOf(u8, local_addr, ":")) |colon| {
            const hex_port = local_addr[colon + 1 ..];
            const port = std.fmt.parseInt(u16, hex_port, 16) catch continue;

            if (filter_port) |fp| {
                if (port != fp) continue;
            }

            try entries.append(ctx.allocator, .{
                .port = port,
                .pid = "-",
                .name = "-",
                .proto = "TCP",
            });
        }
    }

    try printEntries(writer, entries.items);
}

fn listPortsLinuxSs(ctx: context.Context, writer: anytype, filter_port: ?u16) !void {
    const result = std.process.Child.run(.{
        .allocator = ctx.allocator,
        .argv = &.{ "ss", "-tlnp" },
    }) catch {
        const err_writer = ctx.stderrWriter();
        try err_writer.print("ports: failed to read /proc/net/tcp or run ss\n", .{});
        return error.NotAvailable;
    };
    defer ctx.allocator.free(result.stdout);
    defer ctx.allocator.free(result.stderr);

    var entries = std.ArrayList(PortEntry){};
    defer entries.deinit(ctx.allocator);

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    // Skip header
    _ = lines.next();

    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        _ = fields.next() orelse continue; // State
        _ = fields.next() orelse continue; // Recv-Q
        _ = fields.next() orelse continue; // Send-Q
        const local = fields.next() orelse continue; // Local Address:Port

        if (std.mem.lastIndexOf(u8, local, ":")) |colon| {
            const port_str = local[colon + 1 ..];
            const port = std.fmt.parseInt(u16, port_str, 10) catch continue;

            if (filter_port) |fp| {
                if (port != fp) continue;
            }

            try entries.append(ctx.allocator, .{
                .port = port,
                .pid = "-",
                .name = "-",
                .proto = "TCP",
            });
        }
    }

    try printEntries(writer, entries.items);
}

fn printEntries(writer: anytype, entries: []const PortEntry) !void {
    if (entries.len == 0) {
        try writer.print("No listening ports found.\n", .{});
        return;
    }

    // Header
    try writer.print("{s:<8} {s:<8} {s:<6} {s}\n", .{ "PORT", "PID", "PROTO", "PROCESS" });
    try writer.print("{s:<8} {s:<8} {s:<6} {s}\n", .{ "----", "---", "-----", "-------" });

    // Deduplicate by port (lsof can report same port multiple times)
    var seen = std.AutoHashMap(u16, void).init(std.heap.page_allocator);
    defer seen.deinit();

    for (entries) |entry| {
        if (seen.contains(entry.port)) continue;
        seen.put(entry.port, {}) catch continue;

        try writer.print("{d:<8} {s:<8} {s:<6} {s}\n", .{
            entry.port,
            entry.pid,
            entry.proto,
            entry.name,
        });
    }
}

/// Command definition for registration.
pub const command = registry.Command{
    .name = "ports",
    .description = "List listening network ports",
    .category = .dev,
    .subcommands = &.{},
    .execute = execute,
};

// --- Tests ---

test "ports command struct fields" {
    try std.testing.expectEqualStrings("ports", command.name);
    try std.testing.expectEqual(registry.Category.dev, command.category);
    try std.testing.expectEqual(@as(usize, 0), command.subcommands.len);
}

test "ports invalid port number" {
    const allocator = std.testing.allocator;
    const tmp_out = "zuxi_test_ports_out.tmp";
    const tmp_err = "zuxi_test_ports_err.tmp";

    const out_file = try std.fs.cwd().createFile(tmp_out, .{});
    const err_file = try std.fs.cwd().createFile(tmp_err, .{});

    const args = [_][]const u8{"notanumber"};
    var ctx = context.Context.initDefault(allocator);
    ctx.args = &args;
    ctx.stdout = out_file;
    ctx.stderr = err_file;

    const result = execute(ctx, null);
    out_file.close();
    err_file.close();
    std.fs.cwd().deleteFile(tmp_out) catch {};
    std.fs.cwd().deleteFile(tmp_err) catch {};

    try std.testing.expectError(error.InvalidArgument, result);
}

test "ports printEntries empty" {
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();
    try printEntries(writer, &.{});
    const written = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, written, "No listening ports found") != null);
}

test "ports printEntries with entries" {
    var buf: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();
    const entries = [_]PortEntry{
        .{ .port = 8080, .pid = "1234", .name = "node", .proto = "TCP" },
        .{ .port = 3000, .pid = "5678", .name = "python", .proto = "TCP" },
    };
    try printEntries(writer, &entries);
    const written = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, written, "PORT") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "8080") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "3000") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "node") != null);
}

test "ports printEntries deduplicates" {
    var buf: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();
    const entries = [_]PortEntry{
        .{ .port = 8080, .pid = "1234", .name = "node", .proto = "TCP" },
        .{ .port = 8080, .pid = "1234", .name = "node", .proto = "TCP" },
    };
    try printEntries(writer, &entries);
    const written = stream.getWritten();
    // Count occurrences of "8080" - should be exactly 1 (not counting header)
    var count: usize = 0;
    var i: usize = 0;
    while (i < written.len) {
        if (i + 4 <= written.len and std.mem.eql(u8, written[i .. i + 4], "8080")) {
            count += 1;
            i += 4;
        } else {
            i += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}
