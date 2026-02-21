const std = @import("std");
const builtin = @import("builtin");

/// Result of parsing a key from raw input bytes.
pub const KeyResult = struct {
    key: Key,
    len: usize,
};

/// Key represents a parsed keyboard input event.
pub const Key = union(enum) {
    /// Regular printable character.
    char: u8,
    /// Enter/Return key.
    enter,
    /// Backspace key.
    backspace,
    /// Delete key.
    delete,
    /// Tab key.
    tab,
    /// Escape key (standalone, not part of a sequence).
    escape,
    /// Arrow keys.
    arrow_up,
    arrow_down,
    arrow_left,
    arrow_right,
    /// Home / End.
    home,
    end,
    /// Page Up / Page Down.
    page_up,
    page_down,
    /// Function keys.
    f1,
    f2,
    f3,
    f4,
    f5,
    /// Ctrl+key combinations.
    ctrl_c,
    ctrl_d,
    ctrl_q,
    ctrl_l,
    ctrl_a,
    ctrl_e,
    ctrl_k,
    ctrl_u,
    /// Unknown or unhandled input.
    unknown,

    /// Check if this key is a printable character.
    pub fn isPrintable(self: Key) bool {
        return switch (self) {
            .char => |c| c >= 0x20 and c < 0x7F,
            else => false,
        };
    }
};

/// Terminal size in rows and columns.
pub const TermSize = struct {
    rows: u16,
    cols: u16,
};

/// Get the current terminal size.
/// Falls back to 80x24 if the terminal size cannot be determined.
pub fn getTerminalSize() TermSize {
    if (comptime builtin.os.tag == .macos or builtin.os.tag == .linux or
        builtin.os.tag == .freebsd or builtin.os.tag == .netbsd or
        builtin.os.tag == .openbsd)
    {
        const stdout_handle = std.fs.File.stdout().handle;
        var wsz: std.posix.winsize = undefined;
        const TIOCGWINSZ: u32 = switch (comptime builtin.os.tag) {
            .macos => 0x40087468,
            .linux => 0x5413,
            .freebsd => 0x40087468,
            else => 0x40087468,
        };
        const rc = std.c.ioctl(stdout_handle, @bitCast(TIOCGWINSZ), &wsz);
        if (rc == 0 and wsz.col > 0 and wsz.row > 0) {
            return .{ .rows = wsz.row, .cols = wsz.col };
        }
    }
    return .{ .rows = 24, .cols = 80 };
}

/// Parse a single key event from raw terminal input bytes.
/// Returns the parsed key and the number of bytes consumed.
pub fn parseKey(buf: []const u8) KeyResult {
    if (buf.len == 0) return .{ .key = .unknown, .len = 0 };

    const b = buf[0];

    // Ctrl+key combinations (0x01 - 0x1A).
    if (b <= 0x1A) {
        return switch (b) {
            0x01 => .{ .key = .ctrl_a, .len = 1 }, // Ctrl+A
            0x03 => .{ .key = .ctrl_c, .len = 1 }, // Ctrl+C
            0x04 => .{ .key = .ctrl_d, .len = 1 }, // Ctrl+D
            0x05 => .{ .key = .ctrl_e, .len = 1 }, // Ctrl+E
            0x09 => .{ .key = .tab, .len = 1 }, // Tab
            0x0A, 0x0D => .{ .key = .enter, .len = 1 }, // Enter/Return
            0x0B => .{ .key = .ctrl_k, .len = 1 }, // Ctrl+K
            0x0C => .{ .key = .ctrl_l, .len = 1 }, // Ctrl+L
            0x11 => .{ .key = .ctrl_q, .len = 1 }, // Ctrl+Q
            0x15 => .{ .key = .ctrl_u, .len = 1 }, // Ctrl+U
            else => .{ .key = .{ .char = b }, .len = 1 },
        };
    }

    // DEL / Backspace (0x7F).
    if (b == 0x7F) return .{ .key = .backspace, .len = 1 };

    // Escape sequences.
    if (b == 0x1B) {
        if (buf.len == 1) return .{ .key = .escape, .len = 1 };

        if (buf[1] == '[') {
            return parseCSI(buf);
        }
        if (buf[1] == 'O') {
            return parseSSS(buf);
        }
        // Unknown escape sequence - consume just the ESC.
        return .{ .key = .escape, .len = 1 };
    }

    // Regular printable character.
    return .{ .key = .{ .char = b }, .len = 1 };
}

/// Parse a CSI (Control Sequence Introducer) escape sequence: ESC [ ...
fn parseCSI(buf: []const u8) KeyResult {
    // Minimum CSI is ESC [ X (3 bytes).
    if (buf.len < 3) return .{ .key = .escape, .len = 1 };

    return switch (buf[2]) {
        'A' => .{ .key = .arrow_up, .len = 3 },
        'B' => .{ .key = .arrow_down, .len = 3 },
        'C' => .{ .key = .arrow_right, .len = 3 },
        'D' => .{ .key = .arrow_left, .len = 3 },
        'H' => .{ .key = .home, .len = 3 },
        'F' => .{ .key = .end, .len = 3 },
        '1' => parseExtendedCSI(buf),
        '2' => parseTildeCSI(buf, 2),
        '3' => parseTildeCSI(buf, 3),
        '5' => parseTildeCSI(buf, 5),
        '6' => parseTildeCSI(buf, 6),
        else => .{ .key = .unknown, .len = 3 },
    };
}

/// Parse extended CSI sequences like ESC [ 1 5 ~ (F5), ESC [ 1 1 ~ (F1), etc.
fn parseExtendedCSI(buf: []const u8) KeyResult {
    if (buf.len < 4) return .{ .key = .unknown, .len = 3 };

    // ESC [ 1 ~ = Home.
    if (buf[3] == '~') return .{ .key = .home, .len = 4 };

    if (buf.len < 5) return .{ .key = .unknown, .len = 4 };

    // ESC [ 1 X ~ sequences.
    if (buf[4] == '~') {
        return switch (buf[3]) {
            '1' => .{ .key = .f1, .len = 5 }, // ESC [ 1 1 ~
            '2' => .{ .key = .f2, .len = 5 }, // ESC [ 1 2 ~
            '3' => .{ .key = .f3, .len = 5 }, // ESC [ 1 3 ~
            '4' => .{ .key = .f4, .len = 5 }, // ESC [ 1 4 ~
            '5' => .{ .key = .f5, .len = 5 }, // ESC [ 1 5 ~
            else => .{ .key = .unknown, .len = 5 },
        };
    }

    return .{ .key = .unknown, .len = 4 };
}

/// Parse tilde-terminated CSI sequences: ESC [ N ~
fn parseTildeCSI(buf: []const u8, n: u8) KeyResult {
    if (buf.len < 4 or buf[3] != '~') return .{ .key = .unknown, .len = 3 };

    return switch (n) {
        2 => .{ .key = .unknown, .len = 4 }, // Insert
        3 => .{ .key = .delete, .len = 4 }, // Delete
        5 => .{ .key = .page_up, .len = 4 }, // Page Up
        6 => .{ .key = .page_down, .len = 4 }, // Page Down
        else => .{ .key = .unknown, .len = 4 },
    };
}

/// Parse SS3 (Single Shift 3) sequences: ESC O X
fn parseSSS(buf: []const u8) KeyResult {
    if (buf.len < 3) return .{ .key = .escape, .len = 1 };

    return switch (buf[2]) {
        'P' => .{ .key = .f1, .len = 3 }, // ESC O P
        'Q' => .{ .key = .f2, .len = 3 }, // ESC O Q
        'R' => .{ .key = .f3, .len = 3 }, // ESC O R
        'S' => .{ .key = .f4, .len = 3 }, // ESC O S
        'H' => .{ .key = .home, .len = 3 }, // ESC O H
        'F' => .{ .key = .end, .len = 3 }, // ESC O F
        else => .{ .key = .unknown, .len = 3 },
    };
}

/// Terminal raw mode state.
pub const RawMode = struct {
    original: std.posix.termios,
    handle: std.posix.fd_t,

    /// Enable raw mode on stdin. Returns state needed to restore original settings.
    pub fn enable() !RawMode {
        const handle = std.fs.File.stdin().handle;
        const original = try std.posix.tcgetattr(handle);

        var raw = original;
        // Input flags: disable break signal, CR-to-NL, parity checking, strip, flow control.
        raw.iflag.BRKINT = false;
        raw.iflag.ICRNL = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.IXON = false;
        // Output flags: disable post-processing.
        raw.oflag.OPOST = false;
        // Local flags: disable echo, canonical mode, extended input, signals.
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        raw.lflag.ISIG = false;
        // Control characters: read returns after 1 byte, with 100ms timeout.
        raw.cc[@intFromEnum(std.c.V.MIN)] = 0;
        raw.cc[@intFromEnum(std.c.V.TIME)] = 1;

        try std.posix.tcsetattr(handle, .FLUSH, raw);
        return .{ .original = original, .handle = handle };
    }

    /// Restore the original terminal settings.
    pub fn disable(self: RawMode) void {
        std.posix.tcsetattr(self.handle, .FLUSH, self.original) catch {};
    }
};

/// ANSI escape codes for screen manipulation.
pub const Screen = struct {
    /// Clear the entire screen.
    pub fn clear(writer: anytype) !void {
        try writer.writeAll("\x1b[2J");
    }

    /// Move cursor to position (1-based row and col).
    pub fn moveTo(writer: anytype, row: u16, col: u16) !void {
        var buf: [32]u8 = undefined;
        const result = std.fmt.bufPrint(&buf, "\x1b[{d};{d}H", .{ row, col }) catch return;
        try writer.writeAll(result);
    }

    /// Hide the cursor.
    pub fn hideCursor(writer: anytype) !void {
        try writer.writeAll("\x1b[?25l");
    }

    /// Show the cursor.
    pub fn showCursor(writer: anytype) !void {
        try writer.writeAll("\x1b[?25h");
    }

    /// Enter alternate screen buffer.
    pub fn enterAltScreen(writer: anytype) !void {
        try writer.writeAll("\x1b[?1049h");
    }

    /// Leave alternate screen buffer.
    pub fn leaveAltScreen(writer: anytype) !void {
        try writer.writeAll("\x1b[?1049l");
    }

    /// Clear from cursor to end of line.
    pub fn clearToEol(writer: anytype) !void {
        try writer.writeAll("\x1b[K");
    }

    /// Enable mouse tracking (basic).
    pub fn enableMouse(writer: anytype) !void {
        try writer.writeAll("\x1b[?1000h");
    }

    /// Disable mouse tracking.
    pub fn disableMouse(writer: anytype) !void {
        try writer.writeAll("\x1b[?1000l");
    }
};

/// Read a key from stdin (non-blocking, returns null if no input available).
pub fn readKey(stdin: std.fs.File) !?Key {
    var buf: [16]u8 = undefined;
    const n = stdin.read(&buf) catch |err| switch (err) {
        error.WouldBlock => return null,
        else => return err,
    };
    if (n == 0) return null;
    const result = parseKey(buf[0..n]);
    return result.key;
}

// --- Tests ---

test "parseKey: regular characters" {
    const result = parseKey("a");
    try std.testing.expectEqual(Key{ .char = 'a' }, result.key);
    try std.testing.expectEqual(@as(usize, 1), result.len);
}

test "parseKey: space" {
    const result = parseKey(" ");
    try std.testing.expectEqual(Key{ .char = ' ' }, result.key);
}

test "parseKey: enter (CR)" {
    const result = parseKey("\r");
    try std.testing.expectEqual(Key.enter, result.key);
    try std.testing.expectEqual(@as(usize, 1), result.len);
}

test "parseKey: enter (LF)" {
    const result = parseKey("\n");
    try std.testing.expectEqual(Key.enter, result.key);
}

test "parseKey: tab" {
    const result = parseKey("\t");
    try std.testing.expectEqual(Key.tab, result.key);
}

test "parseKey: backspace (DEL)" {
    const result = parseKey("\x7F");
    try std.testing.expectEqual(Key.backspace, result.key);
}

test "parseKey: ctrl+c" {
    const result = parseKey("\x03");
    try std.testing.expectEqual(Key.ctrl_c, result.key);
}

test "parseKey: ctrl+d" {
    const result = parseKey("\x04");
    try std.testing.expectEqual(Key.ctrl_d, result.key);
}

test "parseKey: ctrl+q" {
    const result = parseKey("\x11");
    try std.testing.expectEqual(Key.ctrl_q, result.key);
}

test "parseKey: ctrl+a" {
    const result = parseKey("\x01");
    try std.testing.expectEqual(Key.ctrl_a, result.key);
}

test "parseKey: ctrl+e" {
    const result = parseKey("\x05");
    try std.testing.expectEqual(Key.ctrl_e, result.key);
}

test "parseKey: ctrl+k" {
    const result = parseKey("\x0B");
    try std.testing.expectEqual(Key.ctrl_k, result.key);
}

test "parseKey: ctrl+l" {
    const result = parseKey("\x0C");
    try std.testing.expectEqual(Key.ctrl_l, result.key);
}

test "parseKey: ctrl+u" {
    const result = parseKey("\x15");
    try std.testing.expectEqual(Key.ctrl_u, result.key);
}

test "parseKey: escape standalone" {
    const result = parseKey("\x1b");
    try std.testing.expectEqual(Key.escape, result.key);
    try std.testing.expectEqual(@as(usize, 1), result.len);
}

test "parseKey: arrow up" {
    const result = parseKey("\x1b[A");
    try std.testing.expectEqual(Key.arrow_up, result.key);
    try std.testing.expectEqual(@as(usize, 3), result.len);
}

test "parseKey: arrow down" {
    const result = parseKey("\x1b[B");
    try std.testing.expectEqual(Key.arrow_down, result.key);
}

test "parseKey: arrow right" {
    const result = parseKey("\x1b[C");
    try std.testing.expectEqual(Key.arrow_right, result.key);
}

test "parseKey: arrow left" {
    const result = parseKey("\x1b[D");
    try std.testing.expectEqual(Key.arrow_left, result.key);
}

test "parseKey: home (CSI H)" {
    const result = parseKey("\x1b[H");
    try std.testing.expectEqual(Key.home, result.key);
}

test "parseKey: end (CSI F)" {
    const result = parseKey("\x1b[F");
    try std.testing.expectEqual(Key.end, result.key);
}

test "parseKey: home (SS3 H)" {
    const result = parseKey("\x1bOH");
    try std.testing.expectEqual(Key.home, result.key);
}

test "parseKey: end (SS3 F)" {
    const result = parseKey("\x1bOF");
    try std.testing.expectEqual(Key.end, result.key);
}

test "parseKey: delete" {
    const result = parseKey("\x1b[3~");
    try std.testing.expectEqual(Key.delete, result.key);
    try std.testing.expectEqual(@as(usize, 4), result.len);
}

test "parseKey: page up" {
    const result = parseKey("\x1b[5~");
    try std.testing.expectEqual(Key.page_up, result.key);
}

test "parseKey: page down" {
    const result = parseKey("\x1b[6~");
    try std.testing.expectEqual(Key.page_down, result.key);
}

test "parseKey: F1 (SS3)" {
    const result = parseKey("\x1bOP");
    try std.testing.expectEqual(Key.f1, result.key);
}

test "parseKey: F2 (SS3)" {
    const result = parseKey("\x1bOQ");
    try std.testing.expectEqual(Key.f2, result.key);
}

test "parseKey: F3 (SS3)" {
    const result = parseKey("\x1bOR");
    try std.testing.expectEqual(Key.f3, result.key);
}

test "parseKey: F4 (SS3)" {
    const result = parseKey("\x1bOS");
    try std.testing.expectEqual(Key.f4, result.key);
}

test "parseKey: F3 (CSI)" {
    const result = parseKey("\x1b[13~");
    try std.testing.expectEqual(Key.f3, result.key);
    try std.testing.expectEqual(@as(usize, 5), result.len);
}

test "parseKey: F5 (CSI)" {
    const result = parseKey("\x1b[15~");
    try std.testing.expectEqual(Key.f5, result.key);
    try std.testing.expectEqual(@as(usize, 5), result.len);
}

test "parseKey: empty buffer" {
    const result = parseKey("");
    try std.testing.expectEqual(Key.unknown, result.key);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "Key.isPrintable" {
    try std.testing.expect((Key{ .char = 'a' }).isPrintable());
    try std.testing.expect((Key{ .char = 'Z' }).isPrintable());
    try std.testing.expect((Key{ .char = ' ' }).isPrintable());
    try std.testing.expect((Key{ .char = '~' }).isPrintable());
    try std.testing.expect(!(Key{ .char = 0x01 }).isPrintable());
    try std.testing.expect(!(Key{ .char = 0x7F }).isPrintable());
    const enter_key: Key = .enter;
    try std.testing.expect(!enter_key.isPrintable());
    const arrow_key: Key = .arrow_up;
    try std.testing.expect(!arrow_key.isPrintable());
}

test "getTerminalSize returns non-zero values" {
    const size = getTerminalSize();
    try std.testing.expect(size.rows > 0);
    try std.testing.expect(size.cols > 0);
}

test "Screen.clear writes escape sequence" {
    var buf: [32]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try Screen.clear(fbs.writer());
    try std.testing.expectEqualStrings("\x1b[2J", fbs.getWritten());
}

test "Screen.moveTo writes correct position" {
    var buf: [32]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try Screen.moveTo(fbs.writer(), 5, 10);
    try std.testing.expectEqualStrings("\x1b[5;10H", fbs.getWritten());
}

test "Screen.hideCursor and showCursor" {
    var buf: [32]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try Screen.hideCursor(fbs.writer());
    try std.testing.expectEqualStrings("\x1b[?25l", fbs.getWritten());
    fbs.reset();
    try Screen.showCursor(fbs.writer());
    try std.testing.expectEqualStrings("\x1b[?25h", fbs.getWritten());
}

test "Screen.enterAltScreen and leaveAltScreen" {
    var buf: [32]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try Screen.enterAltScreen(fbs.writer());
    try std.testing.expectEqualStrings("\x1b[?1049h", fbs.getWritten());
    fbs.reset();
    try Screen.leaveAltScreen(fbs.writer());
    try std.testing.expectEqualStrings("\x1b[?1049l", fbs.getWritten());
}

test "Screen.clearToEol writes escape sequence" {
    var buf: [16]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try Screen.clearToEol(fbs.writer());
    try std.testing.expectEqualStrings("\x1b[K", fbs.getWritten());
}
