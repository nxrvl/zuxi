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

// --- TUI Application ---

const registry = @import("registry.zig");
const context = @import("context.zig");
const io_mod = @import("io.zig");
const list_mod = @import("../ui/components/list.zig");
const textinput_mod = @import("../ui/components/textinput.zig");
const preview_mod = @import("../ui/components/preview.zig");
const split_mod = @import("../ui/layout/split.zig");
const theme_mod = @import("../ui/themes/theme.zig");

/// Which panel is currently focused.
pub const ActivePanel = enum {
    command_list,
    input,
    preview,

    /// Cycle to the next panel.
    pub fn next(self: ActivePanel) ActivePanel {
        return switch (self) {
            .command_list => .input,
            .input => .preview,
            .preview => .command_list,
        };
    }
};

/// TUI application state machine.
/// Manages the interactive terminal interface with command list, input, and preview panels.
pub const TuiApp = struct {
    const MAX_ENTRIES = 64;
    const OUTPUT_BUF_SIZE = 16384;
    const MAX_OUTPUT_LINES = 512;
    const STATUS_BUF_SIZE = 256;

    // Core state
    active_panel: ActivePanel,
    running: bool,
    theme: theme_mod.Theme,
    allocator: std.mem.Allocator,
    reg: *const registry.Registry,

    // Components
    command_list: list_mod.List,
    text_input: textinput_mod.TextInput,
    preview_comp: preview_mod.Preview,
    layout: split_mod.SplitLayout,

    // Command entry mapping (index-parallel with list items)
    list_items: [MAX_ENTRIES]list_mod.List.ListItem,
    cmd_names: [MAX_ENTRIES][]const u8,
    cmd_subs: [MAX_ENTRIES]?[]const u8,
    entry_count: usize,

    // Output capture
    output_buf: [OUTPUT_BUF_SIZE]u8,
    output_len: usize,
    output_lines: [MAX_OUTPUT_LINES][]const u8,
    output_line_count: usize,

    // Status bar
    status_buf: [STATUS_BUF_SIZE]u8,
    status_len: usize,

    /// Initialize the TUI app from a command registry.
    pub fn init(allocator: std.mem.Allocator, reg: *const registry.Registry, term_cols: u16, term_rows: u16) TuiApp {
        var app: TuiApp = undefined;
        app.allocator = allocator;
        app.reg = reg;
        app.running = true;
        app.active_panel = .command_list;
        app.theme = theme_mod.dark_theme;
        app.output_len = 0;
        app.output_line_count = 0;

        // Build command entries from registry.
        app.entry_count = 0;
        const cmds = reg.list();
        for (cmds) |slot| {
            if (slot) |cmd| {
                if (cmd.subcommands.len == 0) {
                    if (app.entry_count < MAX_ENTRIES) {
                        app.list_items[app.entry_count] = .{
                            .label = cmd.name,
                            .description = cmd.description,
                            .category = registry.categoryName(cmd.category),
                        };
                        app.cmd_names[app.entry_count] = cmd.name;
                        app.cmd_subs[app.entry_count] = null;
                        app.entry_count += 1;
                    }
                } else {
                    for (cmd.subcommands) |sub| {
                        if (app.entry_count < MAX_ENTRIES) {
                            // Use subcommand name as label with command name as category info.
                            app.list_items[app.entry_count] = .{
                                .label = sub,
                                .description = cmd.description,
                                .category = cmd.name,
                            };
                            app.cmd_names[app.entry_count] = cmd.name;
                            app.cmd_subs[app.entry_count] = sub;
                            app.entry_count += 1;
                        }
                    }
                }
            }
        }

        app.command_list = list_mod.List.init(
            app.list_items[0..app.entry_count],
            " Commands ",
        );

        app.text_input = textinput_mod.TextInput.init(allocator, " Input ");
        app.preview_comp = preview_mod.Preview.init(" Output ");

        app.layout = split_mod.SplitLayout.init(term_cols, term_rows);
        app.applyLayout();
        app.setStatus("Tab:panel  F2:copy  F3:theme  Ctrl+C:quit");

        return app;
    }

    /// Release resources.
    pub fn deinit(self: *TuiApp) void {
        self.text_input.deinit();
    }

    /// Apply layout dimensions to all components.
    fn applyLayout(self: *TuiApp) void {
        const left = self.layout.leftRegion();
        const rt = self.layout.rightTopRegion();
        const rb = self.layout.rightBottomRegion();

        self.command_list.width = left.width;
        self.command_list.visible_rows = if (left.height > 2) left.height - 2 else 1;

        self.text_input.width = rt.width;
        self.text_input.visible_rows = if (rt.height > 2) rt.height - 2 else 1;

        self.preview_comp.width = rb.width;
        self.preview_comp.visible_rows = if (rb.height > 2) rb.height - 2 else 1;
    }

    /// Set status bar text.
    fn setStatus(self: *TuiApp, text: []const u8) void {
        const len = @min(text.len, STATUS_BUF_SIZE);
        @memcpy(self.status_buf[0..len], text[0..len]);
        self.status_len = len;
    }

    /// Process a key event. Updates state accordingly.
    pub fn handleKey(self: *TuiApp, key: Key) !void {
        // Global keys (handled regardless of active panel).
        switch (key) {
            .ctrl_c, .ctrl_q => {
                self.running = false;
                return;
            },
            .f3 => {
                self.theme = self.theme.toggle();
                return;
            },
            .f2 => {
                self.copyOutput();
                return;
            },
            .tab => {
                self.active_panel = self.active_panel.next();
                if (self.active_panel == .preview) {
                    self.executeSelectedCommand();
                }
                return;
            },
            else => {},
        }

        // Panel-specific keys.
        switch (self.active_panel) {
            .command_list => {
                if (key == .enter) {
                    self.active_panel = .input;
                    self.executeSelectedCommand();
                    return;
                }
                _ = self.command_list.handleKey(key);
            },
            .input => {
                _ = self.text_input.handleKey(key) catch {};
                self.executeSelectedCommand();
            },
            .preview => {
                _ = self.preview_comp.handleKey(key);
            },
        }
    }

    /// Execute the currently selected command with the current input text.
    pub fn executeSelectedCommand(self: *TuiApp) void {
        const idx = self.command_list.selected;
        if (idx >= self.entry_count) return;

        const cmd_name = self.cmd_names[idx];
        const sub = self.cmd_subs[idx];
        const cmd = self.reg.lookup(cmd_name) orelse return;

        // Get input text.
        const input_text = self.text_input.getContent() catch return;
        defer self.allocator.free(input_text);

        if (input_text.len == 0) {
            self.output_len = 0;
            self.output_line_count = 0;
            self.preview_comp.setLines(self.output_lines[0..0]);
            return;
        }

        // Create pipes for stdin/stdout redirection.
        const stdin_pipe = std.posix.pipe() catch return;
        const stdout_pipe = std.posix.pipe() catch {
            std.posix.close(stdin_pipe[0]);
            std.posix.close(stdin_pipe[1]);
            return;
        };

        // Write input to stdin pipe and close write end.
        const stdin_write = std.fs.File{ .handle = stdin_pipe[1] };
        stdin_write.writeAll(input_text) catch {};
        stdin_write.close();

        // Build context with pipe handles.
        const arg_list = [_][]const u8{input_text};
        const ctx = context.Context{
            .allocator = self.allocator,
            .stdin = std.fs.File{ .handle = stdin_pipe[0] },
            .stdout = std.fs.File{ .handle = stdout_pipe[1] },
            .stderr = std.fs.File{ .handle = stdout_pipe[1] },
            .flags = .{},
            .args = &arg_list,
        };

        // Execute the command.
        cmd.execute(ctx, sub) catch {
            // On error, show error message in preview.
            std.posix.close(stdout_pipe[1]);
            std.posix.close(stdin_pipe[0]);
            const msg = "Error executing command";
            @memcpy(self.output_buf[0..msg.len], msg);
            self.output_len = msg.len;
            self.output_lines[0] = self.output_buf[0..msg.len];
            self.output_line_count = 1;
            self.preview_comp.setLines(self.output_lines[0..1]);
            // Drain and close read end.
            const stdout_read = std.fs.File{ .handle = stdout_pipe[0] };
            stdout_read.close();
            return;
        };

        // Close pipe ends we're done with.
        std.posix.close(stdout_pipe[1]);
        std.posix.close(stdin_pipe[0]);

        // Read captured output.
        const stdout_read = std.fs.File{ .handle = stdout_pipe[0] };
        self.output_len = stdout_read.readAll(&self.output_buf) catch 0;
        stdout_read.close();

        // Split into lines for the preview component.
        self.splitOutputLines();
        self.preview_comp.setLines(self.output_lines[0..self.output_line_count]);
    }

    /// Split output_buf into lines stored in output_lines.
    fn splitOutputLines(self: *TuiApp) void {
        self.output_line_count = 0;
        if (self.output_len == 0) return;

        var start: usize = 0;
        for (self.output_buf[0..self.output_len], 0..) |c, i| {
            if (c == '\n') {
                if (self.output_line_count < MAX_OUTPUT_LINES) {
                    self.output_lines[self.output_line_count] = self.output_buf[start..i];
                    self.output_line_count += 1;
                }
                start = i + 1;
            }
        }
        if (start < self.output_len and self.output_line_count < MAX_OUTPUT_LINES) {
            self.output_lines[self.output_line_count] = self.output_buf[start..self.output_len];
            self.output_line_count += 1;
        }
    }

    /// Copy output to system clipboard (macOS: pbcopy).
    fn copyOutput(self: *TuiApp) void {
        if (self.output_len == 0) {
            self.setStatus("Nothing to copy");
            return;
        }
        // Try pbcopy on macOS, xclip on Linux.
        const argv = if (comptime builtin.os.tag == .macos)
            &[_][]const u8{"pbcopy"}
        else
            &[_][]const u8{ "xclip", "-selection", "clipboard" };

        var child = std.process.Child.init(argv, self.allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Close;
        child.stderr_behavior = .Close;
        child.spawn() catch {
            self.setStatus("Copy failed - clipboard tool not found");
            return;
        };
        if (child.stdin) |*stdin_stream| {
            stdin_stream.writeAll(self.output_buf[0..self.output_len]) catch {};
            stdin_stream.close();
            child.stdin = null;
        }
        _ = child.wait() catch {};
        self.setStatus("Copied to clipboard!");
    }

    /// Render the full TUI to a writer.
    pub fn render(self: *TuiApp, writer: anytype) !void {
        try Screen.clear(writer);
        const colors = self.theme.colors;

        // Status bar at top.
        try self.layout.renderStatusBar(writer, colors, self.status_buf[0..self.status_len]);

        // Left panel: command list.
        const left = self.layout.leftRegion();
        try self.command_list.render(writer, left.row, left.col, colors, self.active_panel == .command_list);

        // Right top: text input.
        const rt = self.layout.rightTopRegion();
        try self.text_input.render(writer, rt.row, rt.col, colors, self.active_panel == .input);

        // Right bottom: preview.
        const rb = self.layout.rightBottomRegion();
        try self.preview_comp.render(writer, rb.row, rb.col, colors, self.active_panel == .preview);

        // Show cursor only when input panel is active.
        if (self.active_panel == .input) {
            const cursor_row = rt.row + 1 + @as(u16, @intCast(self.text_input.cursor_row -| self.text_input.scroll_offset));
            const cursor_col = rt.col + 1 + @as(u16, @intCast(@min(self.text_input.cursor_col, if (self.text_input.width > 2) self.text_input.width - 2 else 0)));
            try Screen.moveTo(writer, cursor_row, cursor_col);
            try Screen.showCursor(writer);
        } else {
            try Screen.hideCursor(writer);
        }
    }

    /// Run the main TUI event loop (blocking).
    pub fn run(self: *TuiApp) !void {
        const stdout = std.fs.File.stdout();
        const stdin = std.fs.File.stdin();
        const writer = stdout.deprecatedWriter();

        const raw = try RawMode.enable();
        defer raw.disable();

        try Screen.enterAltScreen(writer);
        defer Screen.leaveAltScreen(writer) catch {};
        try Screen.hideCursor(writer);
        defer Screen.showCursor(writer) catch {};

        try self.render(writer);

        while (self.running) {
            if (try readKey(stdin)) |key| {
                try self.handleKey(key);
                try self.render(writer);
            }
        }
    }
};

// --- TuiApp Tests ---

fn dummyExec(_: context.Context, _: ?[]const u8) anyerror!void {}

test "ActivePanel.next cycles correctly" {
    try std.testing.expectEqual(ActivePanel.input, ActivePanel.command_list.next());
    try std.testing.expectEqual(ActivePanel.preview, ActivePanel.input.next());
    try std.testing.expectEqual(ActivePanel.command_list, ActivePanel.preview.next());
}

test "TuiApp init with empty registry" {
    var reg = registry.Registry{};
    var app = TuiApp.init(std.testing.allocator, &reg, 80, 24);
    defer app.deinit();

    try std.testing.expectEqual(ActivePanel.command_list, app.active_panel);
    try std.testing.expect(app.running);
    try std.testing.expectEqual(@as(usize, 0), app.entry_count);
    try std.testing.expectEqual(theme_mod.ThemeVariant.dark, app.theme.variant);
}

test "TuiApp init builds entries from registry" {
    var reg = registry.Registry{};
    const subs = [_][]const u8{ "encode", "decode" };
    try reg.register(.{
        .name = "jsonfmt",
        .description = "Format JSON",
        .category = .json,
        .subcommands = &.{},
        .execute = dummyExec,
    });
    try reg.register(.{
        .name = "base64",
        .description = "Base64 encode/decode",
        .category = .encoding,
        .subcommands = &subs,
        .execute = dummyExec,
    });

    var app = TuiApp.init(std.testing.allocator, &reg, 80, 24);
    defer app.deinit();

    // jsonfmt (no subs) = 1 entry, base64 (2 subs) = 2 entries => total 3
    try std.testing.expectEqual(@as(usize, 3), app.entry_count);
    try std.testing.expectEqualStrings("jsonfmt", app.cmd_names[0]);
    try std.testing.expect(app.cmd_subs[0] == null);
    try std.testing.expectEqualStrings("base64", app.cmd_names[1]);
    try std.testing.expectEqualStrings("encode", app.cmd_subs[1].?);
    try std.testing.expectEqualStrings("base64", app.cmd_names[2]);
    try std.testing.expectEqualStrings("decode", app.cmd_subs[2].?);
}

test "TuiApp handleKey Ctrl+C stops running" {
    var reg = registry.Registry{};
    var app = TuiApp.init(std.testing.allocator, &reg, 80, 24);
    defer app.deinit();

    try std.testing.expect(app.running);
    try app.handleKey(.ctrl_c);
    try std.testing.expect(!app.running);
}

test "TuiApp handleKey Ctrl+Q stops running" {
    var reg = registry.Registry{};
    var app = TuiApp.init(std.testing.allocator, &reg, 80, 24);
    defer app.deinit();

    try app.handleKey(.ctrl_q);
    try std.testing.expect(!app.running);
}

test "TuiApp handleKey F3 toggles theme" {
    var reg = registry.Registry{};
    var app = TuiApp.init(std.testing.allocator, &reg, 80, 24);
    defer app.deinit();

    try std.testing.expectEqual(theme_mod.ThemeVariant.dark, app.theme.variant);
    try app.handleKey(.f3);
    try std.testing.expectEqual(theme_mod.ThemeVariant.light, app.theme.variant);
    try app.handleKey(.f3);
    try std.testing.expectEqual(theme_mod.ThemeVariant.dark, app.theme.variant);
}

test "TuiApp handleKey Tab cycles panels" {
    var reg = registry.Registry{};
    var app = TuiApp.init(std.testing.allocator, &reg, 80, 24);
    defer app.deinit();

    try std.testing.expectEqual(ActivePanel.command_list, app.active_panel);
    try app.handleKey(.tab);
    try std.testing.expectEqual(ActivePanel.input, app.active_panel);
    try app.handleKey(.tab);
    try std.testing.expectEqual(ActivePanel.preview, app.active_panel);
    try app.handleKey(.tab);
    try std.testing.expectEqual(ActivePanel.command_list, app.active_panel);
}

test "TuiApp handleKey Enter on command list switches to input" {
    var reg = registry.Registry{};
    try reg.register(.{
        .name = "test",
        .description = "Test",
        .category = .dev,
        .subcommands = &.{},
        .execute = dummyExec,
    });
    var app = TuiApp.init(std.testing.allocator, &reg, 80, 24);
    defer app.deinit();

    try std.testing.expectEqual(ActivePanel.command_list, app.active_panel);
    try app.handleKey(.enter);
    try std.testing.expectEqual(ActivePanel.input, app.active_panel);
}

test "TuiApp handleKey arrow down in command list" {
    var reg = registry.Registry{};
    try reg.register(.{
        .name = "cmd_a",
        .description = "A",
        .category = .dev,
        .subcommands = &.{},
        .execute = dummyExec,
    });
    try reg.register(.{
        .name = "cmd_b",
        .description = "B",
        .category = .dev,
        .subcommands = &.{},
        .execute = dummyExec,
    });
    var app = TuiApp.init(std.testing.allocator, &reg, 80, 24);
    defer app.deinit();

    try std.testing.expectEqual(@as(usize, 0), app.command_list.selected);
    try app.handleKey(.arrow_down);
    try std.testing.expectEqual(@as(usize, 1), app.command_list.selected);
}

test "TuiApp splitOutputLines splits correctly" {
    var reg = registry.Registry{};
    var app = TuiApp.init(std.testing.allocator, &reg, 80, 24);
    defer app.deinit();

    const test_output = "line1\nline2\nline3";
    @memcpy(app.output_buf[0..test_output.len], test_output);
    app.output_len = test_output.len;
    app.splitOutputLines();

    try std.testing.expectEqual(@as(usize, 3), app.output_line_count);
    try std.testing.expectEqualStrings("line1", app.output_lines[0]);
    try std.testing.expectEqualStrings("line2", app.output_lines[1]);
    try std.testing.expectEqualStrings("line3", app.output_lines[2]);
}

test "TuiApp splitOutputLines handles trailing newline" {
    var reg = registry.Registry{};
    var app = TuiApp.init(std.testing.allocator, &reg, 80, 24);
    defer app.deinit();

    const test_output = "hello\n";
    @memcpy(app.output_buf[0..test_output.len], test_output);
    app.output_len = test_output.len;
    app.splitOutputLines();

    try std.testing.expectEqual(@as(usize, 1), app.output_line_count);
    try std.testing.expectEqualStrings("hello", app.output_lines[0]);
}

test "TuiApp splitOutputLines empty output" {
    var reg = registry.Registry{};
    var app = TuiApp.init(std.testing.allocator, &reg, 80, 24);
    defer app.deinit();

    app.output_len = 0;
    app.splitOutputLines();
    try std.testing.expectEqual(@as(usize, 0), app.output_line_count);
}

test "TuiApp render does not crash" {
    var reg = registry.Registry{};
    try reg.register(.{
        .name = "test",
        .description = "Test",
        .category = .dev,
        .subcommands = &.{},
        .execute = dummyExec,
    });
    var app = TuiApp.init(std.testing.allocator, &reg, 80, 24);
    defer app.deinit();

    var buf: [65536]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try app.render(fbs.writer());
    try std.testing.expect(fbs.getWritten().len > 0);
}

test "TuiApp input panel accepts characters" {
    var reg = registry.Registry{};
    var app = TuiApp.init(std.testing.allocator, &reg, 80, 24);
    defer app.deinit();

    app.active_panel = .input;
    try app.handleKey(.{ .char = 'H' });
    try app.handleKey(.{ .char = 'i' });
    const content = try app.text_input.getContent();
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("Hi", content);
}

test "TuiApp preview panel scrolls" {
    var reg = registry.Registry{};
    var app = TuiApp.init(std.testing.allocator, &reg, 80, 24);
    defer app.deinit();

    // Set some output lines.
    var lines_buf: [20][]const u8 = undefined;
    for (&lines_buf) |*line| {
        line.* = "text";
    }
    app.preview_comp.setLines(&lines_buf);
    app.preview_comp.visible_rows = 5;

    app.active_panel = .preview;
    try app.handleKey(.arrow_down);
    try std.testing.expectEqual(@as(usize, 1), app.preview_comp.scroll_offset);
}
