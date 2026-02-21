const std = @import("std");

/// Unified error set for all Zuxi commands and core modules.
pub const ZuxiError = error{
    /// Input data is malformed or invalid for the operation.
    InvalidInput,
    /// I/O operation failed (read/write/pipe).
    IoError,
    /// Data format is wrong (bad JSON, bad base64, etc.).
    FormatError,
    /// An argument or flag has an invalid value.
    InvalidArgument,
    /// A required argument or flag is missing.
    MissingArgument,
    /// The requested command or subcommand was not found.
    CommandNotFound,
    /// Operation timed out.
    Timeout,
    /// Output buffer is too small.
    BufferTooSmall,
    /// Feature not available in current build mode.
    NotAvailable,
};

/// Format a ZuxiError into a human-readable message.
pub fn errorMessage(err: ZuxiError) []const u8 {
    return switch (err) {
        error.InvalidInput => "invalid input",
        error.IoError => "I/O error",
        error.FormatError => "format error",
        error.InvalidArgument => "invalid argument",
        error.MissingArgument => "missing required argument",
        error.CommandNotFound => "command not found",
        error.Timeout => "operation timed out",
        error.BufferTooSmall => "output buffer too small",
        error.NotAvailable => "feature not available in this build",
    };
}

/// Print a formatted error message to the given writer.
pub fn printError(writer: anytype, err: ZuxiError, detail: ?[]const u8) !void {
    if (detail) |d| {
        try writer.print("zuxi: {s}: {s}\n", .{ errorMessage(err), d });
    } else {
        try writer.print("zuxi: {s}\n", .{errorMessage(err)});
    }
}

// --- Tests ---

test "errorMessage returns non-empty strings for all errors" {
    const errors = [_]ZuxiError{
        error.InvalidInput,
        error.IoError,
        error.FormatError,
        error.InvalidArgument,
        error.MissingArgument,
        error.CommandNotFound,
        error.Timeout,
        error.BufferTooSmall,
        error.NotAvailable,
    };
    for (errors) |err| {
        const msg = errorMessage(err);
        try std.testing.expect(msg.len > 0);
    }
}

test "printError without detail" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try printError(fbs.writer(), error.InvalidInput, null);
    const output = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "invalid input") != null);
    try std.testing.expect(std.mem.startsWith(u8, output, "zuxi:"));
}

test "printError with detail" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try printError(fbs.writer(), error.FormatError, "expected valid JSON");
    const output = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "format error") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "expected valid JSON") != null);
}

test "each error has a unique message" {
    const messages = [_][]const u8{
        errorMessage(error.InvalidInput),
        errorMessage(error.IoError),
        errorMessage(error.FormatError),
        errorMessage(error.InvalidArgument),
        errorMessage(error.MissingArgument),
        errorMessage(error.CommandNotFound),
        errorMessage(error.Timeout),
        errorMessage(error.BufferTooSmall),
        errorMessage(error.NotAvailable),
    };
    // Check that no two messages are the same
    for (messages, 0..) |msg_a, i| {
        for (messages[i + 1 ..]) |msg_b| {
            try std.testing.expect(!std.mem.eql(u8, msg_a, msg_b));
        }
    }
}
