const std = @import("std");
const context = @import("context.zig");

/// Maximum size for reading all of stdin into memory (16 MB).
pub const max_input_size: usize = 16 * 1024 * 1024;

/// Check if a file handle is connected to a terminal (not a pipe/redirect).
pub fn isTty(file: std.fs.File) bool {
    return file.isTty();
}

/// Read all available data from a file handle into a dynamically allocated buffer.
/// Caller owns the returned memory and must free it with the same allocator.
pub fn readAll(file: std.fs.File, allocator: std.mem.Allocator) ![]u8 {
    return file.readToEndAlloc(allocator, max_input_size);
}

/// Read all data from a file handle, trimming trailing whitespace/newlines.
/// Returns a properly allocated buffer that the caller can free.
pub fn readAllTrimmed(file: std.fs.File, allocator: std.mem.Allocator) ![]u8 {
    const data = try readAll(file, allocator);
    const trimmed_len = std.mem.trimRight(u8, data, &std.ascii.whitespace).len;
    if (trimmed_len == data.len) {
        return data;
    }
    if (trimmed_len == 0) {
        allocator.free(data);
        return try allocator.alloc(u8, 0);
    }
    // Shrink the allocation to trimmed size.
    if (allocator.remap(data, trimmed_len)) |resized| {
        return resized;
    }
    // remap failed, copy to a new allocation.
    const result = try allocator.alloc(u8, trimmed_len);
    @memcpy(result, data[0..trimmed_len]);
    allocator.free(data);
    return result;
}

/// Write output to the appropriate destination based on context flags.
/// If --output is set, writes to that file; otherwise writes to ctx.stdout.
pub fn writeOutput(ctx: context.Context, data: []const u8) !void {
    if (ctx.flags.output_file) |path| {
        try writeToFile(path, data);
    } else {
        try ctx.stdout.writeAll(data);
    }
}

/// Write data to a file at the given path, creating or truncating it.
pub fn writeToFile(path: []const u8, data: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(data);
}

/// Get the input data for a command: either from the first positional arg,
/// or from ctx.stdin if it is piped. Returns null if neither is available.
/// When reading from stdin, caller owns the returned memory.
pub fn getInput(ctx: context.Context) !?InputData {
    if (ctx.args.len > 0) {
        return .{ .data = ctx.args[0], .allocated = false };
    }
    if (!isTty(ctx.stdin)) {
        const data = try readAllTrimmed(ctx.stdin, ctx.allocator);
        return .{ .data = data, .allocated = true };
    }
    return null;
}

/// Result from getInput - tracks whether data was dynamically allocated.
pub const InputData = struct {
    data: []const u8,
    allocated: bool,

    /// Free the data if it was dynamically allocated.
    pub fn deinit(self: InputData, allocator: std.mem.Allocator) void {
        if (self.allocated) {
            allocator.free(@constCast(self.data));
        }
    }
};

// --- Tests ---

test "isTty returns false for non-tty file" {
    // A regular file is not a TTY.
    const tmp_path = "zuxi_test_io_tty.tmp";
    const f = try std.fs.cwd().createFile(tmp_path, .{});
    defer f.close();
    defer std.fs.cwd().deleteFile(tmp_path) catch {};
    try std.testing.expect(!isTty(f));
}

test "writeToFile creates and writes file" {
    const tmp_path = "zuxi_test_io_output.tmp";
    const test_data = "hello from io test";
    try writeToFile(tmp_path, test_data);
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    const file = try std.fs.cwd().openFile(tmp_path, .{});
    defer file.close();
    var buf: [256]u8 = undefined;
    const n = try file.readAll(&buf);
    try std.testing.expectEqualStrings(test_data, buf[0..n]);
}

test "writeOutput to file via context" {
    const tmp_path = "zuxi_test_io_ctx_output.tmp";
    var ctx = context.Context.initDefault(std.testing.allocator);
    ctx.flags.output_file = tmp_path;

    const test_data = "context output test";
    try writeOutput(ctx, test_data);
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    const file = try std.fs.cwd().openFile(tmp_path, .{});
    defer file.close();
    var buf: [256]u8 = undefined;
    const n = try file.readAll(&buf);
    try std.testing.expectEqualStrings(test_data, buf[0..n]);
}

test "getInput returns first positional arg" {
    const arg_list = [_][]const u8{"test_input"};
    var ctx = context.Context.initDefault(std.testing.allocator);
    ctx.args = &arg_list;

    const result = try getInput(ctx);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("test_input", result.?.data);
    try std.testing.expect(!result.?.allocated);
}

test "getInput prefers args over stdin" {
    const arg_list = [_][]const u8{"from_arg"};
    var ctx = context.Context.initDefault(std.testing.allocator);
    ctx.args = &arg_list;

    const result = try getInput(ctx);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("from_arg", result.?.data);
}

test "readAll from file" {
    const tmp_path = "zuxi_test_io_readall.tmp";
    const test_data = "read all test data";
    try writeToFile(tmp_path, test_data);
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    const file = try std.fs.cwd().openFile(tmp_path, .{});
    defer file.close();
    const result = try readAll(file, std.testing.allocator);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings(test_data, result);
}

test "readAllTrimmed trims trailing whitespace" {
    const tmp_path = "zuxi_test_io_trim.tmp";
    const test_data = "trimmed data\n\n  \n";
    try writeToFile(tmp_path, test_data);
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    const file = try std.fs.cwd().openFile(tmp_path, .{});
    defer file.close();
    const result = try readAllTrimmed(file, std.testing.allocator);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("trimmed data", result);
}

test "readAllTrimmed with no trailing whitespace" {
    const tmp_path = "zuxi_test_io_notrim.tmp";
    const test_data = "no trailing ws";
    try writeToFile(tmp_path, test_data);
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    const file = try std.fs.cwd().openFile(tmp_path, .{});
    defer file.close();
    const result = try readAllTrimmed(file, std.testing.allocator);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("no trailing ws", result);
}

test "InputData deinit frees allocated data" {
    const data = try std.testing.allocator.alloc(u8, 5);
    @memcpy(data, "hello");
    const input = InputData{ .data = data, .allocated = true };
    input.deinit(std.testing.allocator);
    // If allocator leak detection doesn't fire, the test passes.
}

test "InputData deinit is noop for non-allocated data" {
    const input = InputData{ .data = "static", .allocated = false };
    input.deinit(std.testing.allocator);
    // Should not crash or try to free static memory.
}
