const std = @import("std");

/// A TOML value: string, integer, float, boolean, datetime, array, or table.
pub const Value = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
    datetime: []const u8,
    array: []const Value,
    table: []const TableEntry,
};

pub const TableEntry = struct {
    key: []const u8,
    value: Value,
};

pub const ParseResult = struct {
    value: Value,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *ParseResult) void {
        self.arena.deinit();
    }
};

const ParseContext = struct {
    source: []const u8,
    pos: usize,
    allocator: std.mem.Allocator,
};

/// Parse a TOML document from text.
pub fn parse(allocator: std.mem.Allocator, source: []const u8) !ParseResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const aa = arena.allocator();

    var ctx = ParseContext{
        .source = source,
        .pos = 0,
        .allocator = aa,
    };

    // All entries go into a flat list. Each entry is tagged with which section it belongs to.
    // section_index == -1 means root level.
    var all_entries = std.ArrayList(SectionEntry){};
    var sections = std.ArrayList(SectionHeader){};
    var current_section: i32 = -1;

    // Parse all lines.
    while (ctx.pos < ctx.source.len) {
        skipWhitespaceAndNewlines(&ctx);
        if (ctx.pos >= ctx.source.len) break;

        const c = ctx.source[ctx.pos];

        // Skip comments.
        if (c == '#') {
            skipToEndOfLine(&ctx);
            continue;
        }

        // Table header: [name] or [[name]].
        if (c == '[') {
            const is_array_of_tables = ctx.pos + 1 < ctx.source.len and ctx.source[ctx.pos + 1] == '[';
            if (is_array_of_tables) {
                ctx.pos += 2; // Skip [[
            } else {
                ctx.pos += 1; // Skip [
            }

            skipSpaces(&ctx);
            const key_start = ctx.pos;
            if (is_array_of_tables) {
                while (ctx.pos < ctx.source.len and !(ctx.source[ctx.pos] == ']' and ctx.pos + 1 < ctx.source.len and ctx.source[ctx.pos + 1] == ']')) {
                    ctx.pos += 1;
                }
            } else {
                while (ctx.pos < ctx.source.len and ctx.source[ctx.pos] != ']') {
                    ctx.pos += 1;
                }
            }
            const table_key = std.mem.trim(u8, ctx.source[key_start..ctx.pos], " \t");

            if (is_array_of_tables) {
                if (ctx.pos + 1 < ctx.source.len) ctx.pos += 2; // Skip ]]
            } else {
                if (ctx.pos < ctx.source.len) ctx.pos += 1; // Skip ]
            }
            skipToEndOfLine(&ctx);

            try sections.append(aa, .{
                .key = try aa.dupe(u8, table_key),
                .is_array = is_array_of_tables,
            });
            current_section = @intCast(sections.items.len - 1);
            continue;
        }

        // Skip blank lines and whitespace-only content.
        if (c == '\n' or c == '\r') {
            ctx.pos += 1;
            continue;
        }

        // Key-value pair.
        const entry = try parseKeyValue(&ctx);
        try all_entries.append(aa, .{
            .section = current_section,
            .entry = entry,
        });
    }

    // Now assemble the nested table structure.
    var root = std.ArrayList(TableEntry){};

    // Add root-level entries.
    for (all_entries.items) |se| {
        if (se.section == -1) {
            try root.append(aa, se.entry);
        }
    }

    // Process table sections.
    for (sections.items, 0..) |section, sec_idx| {
        // Collect entries for this section.
        var sec_entries = std.ArrayList(TableEntry){};
        for (all_entries.items) |se| {
            if (se.section == @as(i32, @intCast(sec_idx))) {
                try sec_entries.append(aa, se.entry);
            }
        }
        const section_value = Value{ .table = try sec_entries.toOwnedSlice(aa) };
        try insertNestedKey(aa, &root, section.key, section_value, section.is_array);
    }

    const result_table = try root.toOwnedSlice(aa);
    return .{ .value = .{ .table = result_table }, .arena = arena };
}

const SectionEntry = struct {
    section: i32, // -1 = root, >= 0 = index into sections list
    entry: TableEntry,
};

const SectionHeader = struct {
    key: []const u8,
    is_array: bool,
};

/// Insert a value at a dotted key path into the table, creating intermediate tables as needed.
fn insertNestedKey(
    allocator: std.mem.Allocator,
    root: *std.ArrayList(TableEntry),
    key_path: []const u8,
    value: Value,
    is_array: bool,
) !void {
    // Split key_path by '.' (respecting quoted keys).
    var parts = std.ArrayList([]const u8){};
    var start: usize = 0;
    var i: usize = 0;
    while (i < key_path.len) {
        if (key_path[i] == '"') {
            i += 1;
            while (i < key_path.len and key_path[i] != '"') : (i += 1) {}
            if (i < key_path.len) i += 1;
            continue;
        }
        if (key_path[i] == '.') {
            const part = std.mem.trim(u8, key_path[start..i], " \t");
            try parts.append(allocator, stripQuotes(part));
            start = i + 1;
        }
        i += 1;
    }
    const last_part = std.mem.trim(u8, key_path[start..], " \t");
    try parts.append(allocator, stripQuotes(last_part));

    if (parts.items.len == 0) return;

    try insertNestedKeyParts(allocator, root, parts.items, value, is_array);
}

/// Insert a value into a nested table structure given pre-split key parts.
/// parts[0..len-1] are intermediate table keys, parts[len-1] is the leaf key.
fn insertNestedKeyParts(
    allocator: std.mem.Allocator,
    root: *std.ArrayList(TableEntry),
    parts: []const []const u8,
    value: Value,
    is_array: bool,
) !void {
    if (parts.len == 0) return;

    if (parts.len == 1) {
        // Simple key - add directly.
        if (is_array) {
            // Find existing array entry or create new one.
            for (root.items) |*entry| {
                if (std.mem.eql(u8, entry.key, parts[0])) {
                    if (entry.value == .array) {
                        // Append to existing array.
                        var arr = std.ArrayList(Value){};
                        for (entry.value.array) |item| {
                            try arr.append(allocator, item);
                        }
                        try arr.append(allocator, value);
                        entry.value = .{ .array = try arr.toOwnedSlice(allocator) };
                        return;
                    }
                }
            }
            // Create new array with this as first element.
            var arr = std.ArrayList(Value){};
            try arr.append(allocator, value);
            try root.append(allocator, .{
                .key = try allocator.dupe(u8, parts[0]),
                .value = .{ .array = try arr.toOwnedSlice(allocator) },
            });
        } else {
            try root.append(allocator, .{
                .key = try allocator.dupe(u8, parts[0]),
                .value = value,
            });
        }
        return;
    }

    // Multi-part key: find or create intermediate tables, then insert value at the leaf.
    const part = parts[0];
    for (root.items) |*entry| {
        if (std.mem.eql(u8, entry.key, part)) {
            if (entry.value == .table) {
                // Descend into existing table with remaining parts via recursion.
                var sub_list = std.ArrayList(TableEntry){};
                for (entry.value.table) |sub_entry| {
                    try sub_list.append(allocator, sub_entry);
                }
                try insertNestedKeyParts(allocator, &sub_list, parts[1..], value, is_array);
                entry.value = .{ .table = try sub_list.toOwnedSlice(allocator) };
                return;
            } else if (entry.value == .array) {
                // For arrays of tables, descend into the last element via recursion.
                if (entry.value.array.len > 0) {
                    const last_elem = entry.value.array[entry.value.array.len - 1];
                    if (last_elem == .table) {
                        var sub_list = std.ArrayList(TableEntry){};
                        for (last_elem.table) |sub_entry| {
                            try sub_list.append(allocator, sub_entry);
                        }
                        try insertNestedKeyParts(allocator, &sub_list, parts[1..], value, is_array);
                        // Rebuild array with updated last element.
                        var new_arr = std.ArrayList(Value){};
                        for (entry.value.array[0 .. entry.value.array.len - 1]) |item| {
                            try new_arr.append(allocator, item);
                        }
                        try new_arr.append(allocator, .{ .table = try sub_list.toOwnedSlice(allocator) });
                        entry.value = .{ .array = try new_arr.toOwnedSlice(allocator) };
                        return;
                    }
                }
            }
            break;
        }
    }

    // Not found: create the full remaining path at once, building nested tables from inside out.
    const remaining_key = parts[parts.len - 1];
    var inner_entries = std.ArrayList(TableEntry){};

    if (is_array) {
        var arr = std.ArrayList(Value){};
        try arr.append(allocator, value);
        try inner_entries.append(allocator, .{
            .key = try allocator.dupe(u8, remaining_key),
            .value = .{ .array = try arr.toOwnedSlice(allocator) },
        });
    } else {
        try inner_entries.append(allocator, .{
            .key = try allocator.dupe(u8, remaining_key),
            .value = value,
        });
    }

    // Build nested tables from inside out for remaining intermediate parts.
    var current_value = Value{ .table = try inner_entries.toOwnedSlice(allocator) };
    if (parts.len >= 3) {
        var j: usize = parts.len - 2;
        while (j > 0) : (j -= 1) {
            var wrapper = std.ArrayList(TableEntry){};
            try wrapper.append(allocator, .{
                .key = try allocator.dupe(u8, parts[j]),
                .value = current_value,
            });
            current_value = .{ .table = try wrapper.toOwnedSlice(allocator) };
        }
    }

    try root.append(allocator, .{
        .key = try allocator.dupe(u8, part),
        .value = current_value,
    });
}

fn stripQuotes(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') return s[1 .. s.len - 1];
    if (s.len >= 2 and s[0] == '\'' and s[s.len - 1] == '\'') return s[1 .. s.len - 1];
    return s;
}

/// Parse a key-value pair: key = value
fn parseKeyValue(ctx: *ParseContext) !TableEntry {
    skipSpaces(ctx);

    // Parse key (bare or quoted).
    const key = try parseKey(ctx);

    skipSpaces(ctx);

    // Expect '='.
    if (ctx.pos >= ctx.source.len or ctx.source[ctx.pos] != '=') {
        return error.InvalidInput;
    }
    ctx.pos += 1;

    skipSpaces(ctx);

    // Parse value.
    const value = try parseValue(ctx);

    // Skip trailing comment and whitespace.
    skipSpaces(ctx);
    if (ctx.pos < ctx.source.len and ctx.source[ctx.pos] == '#') {
        skipToEndOfLine(ctx);
    }
    // Skip newline.
    if (ctx.pos < ctx.source.len and ctx.source[ctx.pos] == '\n') {
        ctx.pos += 1;
    } else if (ctx.pos + 1 < ctx.source.len and ctx.source[ctx.pos] == '\r' and ctx.source[ctx.pos + 1] == '\n') {
        ctx.pos += 2;
    }

    return .{ .key = key, .value = value };
}

/// Parse a TOML key (bare key, basic quoted, or literal quoted).
fn parseKey(ctx: *ParseContext) ![]const u8 {
    if (ctx.pos >= ctx.source.len) return error.InvalidInput;

    if (ctx.source[ctx.pos] == '"') {
        return try parseBasicString(ctx);
    }
    if (ctx.source[ctx.pos] == '\'') {
        return try parseLiteralString(ctx);
    }

    // Bare key: A-Za-z0-9_-
    const start = ctx.pos;
    while (ctx.pos < ctx.source.len) {
        const c = ctx.source[ctx.pos];
        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-') {
            ctx.pos += 1;
        } else {
            break;
        }
    }
    if (ctx.pos == start) return error.InvalidInput;
    return try ctx.allocator.dupe(u8, ctx.source[start..ctx.pos]);
}

/// Parse a TOML value.
fn parseValue(ctx: *ParseContext) anyerror!Value {
    if (ctx.pos >= ctx.source.len) return error.InvalidInput;

    const c = ctx.source[ctx.pos];

    // String values.
    if (c == '"') {
        // Check for multi-line basic string """.
        if (ctx.pos + 2 < ctx.source.len and ctx.source[ctx.pos + 1] == '"' and ctx.source[ctx.pos + 2] == '"') {
            const s = try parseMultiLineBasicString(ctx);
            return .{ .string = s };
        }
        const s = try parseBasicString(ctx);
        return .{ .string = s };
    }
    if (c == '\'') {
        // Check for multi-line literal string '''.
        if (ctx.pos + 2 < ctx.source.len and ctx.source[ctx.pos + 1] == '\'' and ctx.source[ctx.pos + 2] == '\'') {
            const s = try parseMultiLineLiteralString(ctx);
            return .{ .string = s };
        }
        const s = try parseLiteralString(ctx);
        return .{ .string = s };
    }

    // Boolean values (with word boundary check).
    if (startsWith(ctx, "true") and isValueEnd(ctx, ctx.pos + 4)) {
        ctx.pos += 4;
        return .{ .boolean = true };
    }
    if (startsWith(ctx, "false") and isValueEnd(ctx, ctx.pos + 5)) {
        ctx.pos += 5;
        return .{ .boolean = false };
    }

    // Array.
    if (c == '[') {
        return try parseArray(ctx);
    }

    // Inline table.
    if (c == '{') {
        return try parseInlineTable(ctx);
    }

    // Special float values (with word boundary check).
    if ((startsWith(ctx, "inf") and isValueEnd(ctx, ctx.pos + 3)) or
        (startsWith(ctx, "+inf") and isValueEnd(ctx, ctx.pos + 4)))
    {
        ctx.pos += if (c == '+') @as(usize, 4) else @as(usize, 3);
        return .{ .float = std.math.inf(f64) };
    }
    if (startsWith(ctx, "-inf") and isValueEnd(ctx, ctx.pos + 4)) {
        ctx.pos += 4;
        return .{ .float = -std.math.inf(f64) };
    }
    if ((startsWith(ctx, "nan") and isValueEnd(ctx, ctx.pos + 3)) or
        (startsWith(ctx, "+nan") and isValueEnd(ctx, ctx.pos + 4)))
    {
        ctx.pos += if (c == '+') @as(usize, 4) else @as(usize, 3);
        return .{ .float = std.math.nan(f64) };
    }
    if (startsWith(ctx, "-nan") and isValueEnd(ctx, ctx.pos + 4)) {
        ctx.pos += 4;
        return .{ .float = -std.math.nan(f64) };
    }

    // Number or datetime - read until delimiter.
    return try parseNumberOrDatetime(ctx);
}

/// Parse a basic string (double-quoted).
fn parseBasicString(ctx: *ParseContext) ![]const u8 {
    ctx.pos += 1; // Skip opening "
    var result = std.ArrayList(u8){};

    while (ctx.pos < ctx.source.len) {
        const c = ctx.source[ctx.pos];
        if (c == '"') {
            ctx.pos += 1; // Skip closing "
            return try result.toOwnedSlice(ctx.allocator);
        }
        if (c == '\\') {
            ctx.pos += 1;
            if (ctx.pos >= ctx.source.len) break;
            const esc = ctx.source[ctx.pos];
            switch (esc) {
                'n' => try result.append(ctx.allocator, '\n'),
                't' => try result.append(ctx.allocator, '\t'),
                'r' => try result.append(ctx.allocator, '\r'),
                '\\' => try result.append(ctx.allocator, '\\'),
                '"' => try result.append(ctx.allocator, '"'),
                'b' => try result.append(ctx.allocator, 0x08),
                'f' => try result.append(ctx.allocator, 0x0C),
                'u', 'U' => {
                    const n: usize = if (esc == 'u') 4 else 8;
                    ctx.pos += 1;
                    if (ctx.pos + n > ctx.source.len) return error.InvalidInput;
                    const hex = ctx.source[ctx.pos .. ctx.pos + n];
                    const codepoint = std.fmt.parseInt(u21, hex, 16) catch return error.InvalidInput;
                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(codepoint, &buf) catch return error.InvalidInput;
                    try result.appendSlice(ctx.allocator, buf[0..len]);
                    ctx.pos += n;
                    continue;
                },
                else => {
                    try result.append(ctx.allocator, '\\');
                    try result.append(ctx.allocator, esc);
                },
            }
            ctx.pos += 1;
            continue;
        }
        try result.append(ctx.allocator, c);
        ctx.pos += 1;
    }
    // Unterminated basic string.
    return error.InvalidInput;
}

/// Parse a literal string (single-quoted, no escapes).
fn parseLiteralString(ctx: *ParseContext) ![]const u8 {
    ctx.pos += 1; // Skip opening '
    const start = ctx.pos;
    while (ctx.pos < ctx.source.len and ctx.source[ctx.pos] != '\'') {
        ctx.pos += 1;
    }
    if (ctx.pos >= ctx.source.len) return error.InvalidInput; // Unterminated literal string.
    const s = try ctx.allocator.dupe(u8, ctx.source[start..ctx.pos]);
    ctx.pos += 1; // Skip closing '
    return s;
}

/// Parse a multi-line basic string (""" ... """).
fn parseMultiLineBasicString(ctx: *ParseContext) ![]const u8 {
    ctx.pos += 3; // Skip opening """
    // Skip immediate newline after opening """.
    if (ctx.pos < ctx.source.len and ctx.source[ctx.pos] == '\n') {
        ctx.pos += 1;
    } else if (ctx.pos + 1 < ctx.source.len and ctx.source[ctx.pos] == '\r' and ctx.source[ctx.pos + 1] == '\n') {
        ctx.pos += 2;
    }

    var result = std.ArrayList(u8){};
    while (ctx.pos < ctx.source.len) {
        if (ctx.pos + 2 < ctx.source.len and ctx.source[ctx.pos] == '"' and ctx.source[ctx.pos + 1] == '"' and ctx.source[ctx.pos + 2] == '"') {
            ctx.pos += 3;
            return try result.toOwnedSlice(ctx.allocator);
        }
        if (ctx.source[ctx.pos] == '\\') {
            ctx.pos += 1;
            if (ctx.pos >= ctx.source.len) break;
            const esc = ctx.source[ctx.pos];
            switch (esc) {
                'n' => try result.append(ctx.allocator, '\n'),
                't' => try result.append(ctx.allocator, '\t'),
                'r' => try result.append(ctx.allocator, '\r'),
                '\\' => try result.append(ctx.allocator, '\\'),
                '"' => try result.append(ctx.allocator, '"'),
                'u', 'U' => {
                    const n: usize = if (esc == 'u') 4 else 8;
                    ctx.pos += 1;
                    if (ctx.pos + n > ctx.source.len) return error.InvalidInput;
                    const hex = ctx.source[ctx.pos .. ctx.pos + n];
                    const codepoint = std.fmt.parseInt(u21, hex, 16) catch return error.InvalidInput;
                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(codepoint, &buf) catch return error.InvalidInput;
                    try result.appendSlice(ctx.allocator, buf[0..len]);
                    ctx.pos += n;
                    continue;
                },
                '\n' => {
                    // Line-ending backslash: skip whitespace on next line.
                    ctx.pos += 1;
                    while (ctx.pos < ctx.source.len and (ctx.source[ctx.pos] == ' ' or ctx.source[ctx.pos] == '\t' or ctx.source[ctx.pos] == '\n' or ctx.source[ctx.pos] == '\r')) {
                        ctx.pos += 1;
                    }
                    continue;
                },
                else => {
                    try result.append(ctx.allocator, '\\');
                    try result.append(ctx.allocator, esc);
                },
            }
            ctx.pos += 1;
            continue;
        }
        try result.append(ctx.allocator, ctx.source[ctx.pos]);
        ctx.pos += 1;
    }
    // Unterminated multi-line basic string.
    return error.InvalidInput;
}

/// Parse a multi-line literal string (''' ... ''').
fn parseMultiLineLiteralString(ctx: *ParseContext) ![]const u8 {
    ctx.pos += 3; // Skip opening '''
    // Skip immediate newline.
    if (ctx.pos < ctx.source.len and ctx.source[ctx.pos] == '\n') {
        ctx.pos += 1;
    } else if (ctx.pos + 1 < ctx.source.len and ctx.source[ctx.pos] == '\r' and ctx.source[ctx.pos + 1] == '\n') {
        ctx.pos += 2;
    }

    const start = ctx.pos;
    while (ctx.pos < ctx.source.len) {
        if (ctx.pos + 2 < ctx.source.len and ctx.source[ctx.pos] == '\'' and ctx.source[ctx.pos + 1] == '\'' and ctx.source[ctx.pos + 2] == '\'') {
            const s = try ctx.allocator.dupe(u8, ctx.source[start..ctx.pos]);
            ctx.pos += 3;
            return s;
        }
        ctx.pos += 1;
    }
    // Unterminated multi-line literal string.
    return error.InvalidInput;
}

/// Parse an array value: [val1, val2, ...]
fn parseArray(ctx: *ParseContext) anyerror!Value {
    ctx.pos += 1; // Skip [
    var items = std.ArrayList(Value){};

    while (ctx.pos < ctx.source.len) {
        skipWhitespaceAndNewlines(ctx);
        if (ctx.pos >= ctx.source.len) break;
        if (ctx.source[ctx.pos] == ']') {
            ctx.pos += 1;
            return .{ .array = try items.toOwnedSlice(ctx.allocator) };
        }

        // Skip comments inside arrays.
        if (ctx.source[ctx.pos] == '#') {
            skipToEndOfLine(ctx);
            continue;
        }

        const val = try parseValue(ctx);
        try items.append(ctx.allocator, val);

        skipWhitespaceAndNewlines(ctx);
        if (ctx.pos < ctx.source.len and ctx.source[ctx.pos] == '#') {
            skipToEndOfLine(ctx);
            skipWhitespaceAndNewlines(ctx);
        }
        if (ctx.pos < ctx.source.len and ctx.source[ctx.pos] == ',') {
            ctx.pos += 1;
        }
    }

    // Unterminated array (no closing ']' found).
    return error.InvalidInput;
}

/// Parse an inline table: {key = val, key2 = val2}
fn parseInlineTable(ctx: *ParseContext) anyerror!Value {
    ctx.pos += 1; // Skip {
    var entries = std.ArrayList(TableEntry){};

    skipSpaces(ctx);
    if (ctx.pos < ctx.source.len and ctx.source[ctx.pos] == '}') {
        ctx.pos += 1;
        return .{ .table = try entries.toOwnedSlice(ctx.allocator) };
    }

    while (ctx.pos < ctx.source.len) {
        skipSpaces(ctx);
        if (ctx.pos >= ctx.source.len) break;
        if (ctx.source[ctx.pos] == '}') {
            ctx.pos += 1;
            return .{ .table = try entries.toOwnedSlice(ctx.allocator) };
        }

        const key = try parseKey(ctx);
        skipSpaces(ctx);
        if (ctx.pos >= ctx.source.len or ctx.source[ctx.pos] != '=') return error.InvalidInput;
        ctx.pos += 1;
        skipSpaces(ctx);
        const val = try parseValue(ctx);
        try entries.append(ctx.allocator, .{ .key = key, .value = val });

        skipSpaces(ctx);
        if (ctx.pos < ctx.source.len and ctx.source[ctx.pos] == ',') {
            ctx.pos += 1;
        }
    }

    // Unterminated inline table (no closing '}' found).
    return error.InvalidInput;
}

/// Parse a number (integer or float) or datetime.
fn parseNumberOrDatetime(ctx: *ParseContext) !Value {
    const start = ctx.pos;

    // Read until a delimiter.
    while (ctx.pos < ctx.source.len) {
        const c = ctx.source[ctx.pos];
        if (c == ',' or c == ']' or c == '}' or c == '\n' or c == '\r' or c == '#') break;
        ctx.pos += 1;
    }

    const raw = std.mem.trimRight(u8, ctx.source[start..ctx.pos], " \t");
    if (raw.len == 0) return error.InvalidInput;

    // Check for datetime (contains T or multiple - with : pattern).
    if (isDatetime(raw)) {
        return .{ .datetime = try ctx.allocator.dupe(u8, raw) };
    }

    // Remove underscores (TOML allows _ as visual separator in numbers).
    var clean = std.ArrayList(u8){};
    for (raw) |c| {
        if (c != '_') try clean.append(ctx.allocator, c);
    }
    const cleaned = try clean.toOwnedSlice(ctx.allocator);

    // Try hex (0x), octal (0o), binary (0b).
    if (cleaned.len > 2) {
        if (cleaned[0] == '0' and cleaned[1] == 'x') {
            if (std.fmt.parseInt(i64, cleaned[2..], 16)) |n| return .{ .integer = n } else |_| {}
        }
        if (cleaned[0] == '0' and cleaned[1] == 'o') {
            if (std.fmt.parseInt(i64, cleaned[2..], 8)) |n| return .{ .integer = n } else |_| {}
        }
        if (cleaned[0] == '0' and cleaned[1] == 'b') {
            if (std.fmt.parseInt(i64, cleaned[2..], 2)) |n| return .{ .integer = n } else |_| {}
        }
    }

    // Try integer.
    if (std.fmt.parseInt(i64, cleaned, 10)) |n| {
        return .{ .integer = n };
    } else |_| {}

    // Try float.
    if (std.fmt.parseFloat(f64, cleaned)) |f| {
        return .{ .float = f };
    } else |_| {}

    // Invalid bare value - TOML requires strings to be quoted.
    return error.InvalidInput;
}

fn isDatetime(s: []const u8) bool {
    // Simple heuristic: contains digits and at least T or has pattern like YYYY-MM-DD.
    if (s.len < 10) return false;
    var has_t = false;
    var dash_count: usize = 0;
    var colon_count: usize = 0;
    for (s) |c| {
        if (c == 'T' or c == 't') has_t = true;
        if (c == '-') dash_count += 1;
        if (c == ':') colon_count += 1;
    }
    // YYYY-MM-DD or YYYY-MM-DDTHH:MM:SS
    if (dash_count >= 2 and (has_t or colon_count >= 2)) return true;
    if (dash_count >= 2 and s.len == 10) return true; // Date only
    return false;
}

fn startsWith(ctx: *const ParseContext, prefix: []const u8) bool {
    if (ctx.pos + prefix.len > ctx.source.len) return false;
    return std.mem.eql(u8, ctx.source[ctx.pos .. ctx.pos + prefix.len], prefix);
}

/// Check if position is at end-of-value (delimiter, whitespace, or end of input).
fn isValueEnd(ctx: *const ParseContext, pos: usize) bool {
    if (pos >= ctx.source.len) return true;
    const c = ctx.source[pos];
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or
        c == ',' or c == ']' or c == '}' or c == '#';
}

fn skipSpaces(ctx: *ParseContext) void {
    while (ctx.pos < ctx.source.len and (ctx.source[ctx.pos] == ' ' or ctx.source[ctx.pos] == '\t')) {
        ctx.pos += 1;
    }
}

fn skipWhitespaceAndNewlines(ctx: *ParseContext) void {
    while (ctx.pos < ctx.source.len) {
        const c = ctx.source[ctx.pos];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            ctx.pos += 1;
        } else {
            break;
        }
    }
}

fn skipToEndOfLine(ctx: *ParseContext) void {
    while (ctx.pos < ctx.source.len and ctx.source[ctx.pos] != '\n') {
        ctx.pos += 1;
    }
    if (ctx.pos < ctx.source.len) ctx.pos += 1; // Skip \n.
}

// --- Serializer ---

/// Serialize a TOML Value back to text with consistent formatting.
pub fn serialize(allocator: std.mem.Allocator, value: Value) ![]u8 {
    var output = std.ArrayList(u8){};
    errdefer output.deinit(allocator);

    switch (value) {
        .table => |entries| {
            // First write all non-table, non-array-of-tables entries.
            for (entries) |entry| {
                switch (entry.value) {
                    .table => {},
                    .array => |arr| {
                        // Check if this is an array of tables.
                        if (arr.len > 0 and arr[0] == .table) {
                            continue; // Handle below.
                        }
                        try serializeKeyValue(allocator, &output, entry.key, entry.value);
                    },
                    else => {
                        try serializeKeyValue(allocator, &output, entry.key, entry.value);
                    },
                }
            }

            // Then write table sections.
            for (entries) |entry| {
                if (entry.value == .table) {
                    try output.append(allocator, '\n');
                    try output.append(allocator, '[');
                    try serializeKey(allocator, &output, entry.key);
                    try output.appendSlice(allocator, "]\n");
                    try serializeTableEntries(allocator, &output, entry.value.table, entry.key);
                } else if (entry.value == .array) {
                    const arr = entry.value.array;
                    if (arr.len > 0 and arr[0] == .table) {
                        for (arr) |item| {
                            try output.append(allocator, '\n');
                            try output.appendSlice(allocator, "[[");
                            try serializeKey(allocator, &output, entry.key);
                            try output.appendSlice(allocator, "]]\n");
                            if (item == .table) {
                                for (item.table) |sub_entry| {
                                    try serializeKeyValue(allocator, &output, sub_entry.key, sub_entry.value);
                                }
                            }
                        }
                    }
                }
            }
        },
        else => {
            try serializeInlineValue(allocator, &output, value);
        },
    }

    return try output.toOwnedSlice(allocator);
}

fn serializeTableEntries(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    entries: []const TableEntry,
    parent_key: []const u8,
) !void {
    // Write non-table entries first.
    for (entries) |entry| {
        switch (entry.value) {
            .table => {},
            .array => |arr| {
                if (arr.len > 0 and arr[0] == .table) continue;
                try serializeKeyValue(allocator, output, entry.key, entry.value);
            },
            else => {
                try serializeKeyValue(allocator, output, entry.key, entry.value);
            },
        }
    }

    // Then sub-tables.
    for (entries) |entry| {
        if (entry.value == .table) {
            // Build full dotted path for nested tables
            const full_key = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ parent_key, entry.key });
            try output.append(allocator, '\n');
            try output.append(allocator, '[');
            try output.appendSlice(allocator, full_key);
            try output.appendSlice(allocator, "]\n");
            try serializeTableEntries(allocator, output, entry.value.table, full_key);
        } else if (entry.value == .array) {
            const arr = entry.value.array;
            if (arr.len > 0 and arr[0] == .table) {
                const full_key = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ parent_key, entry.key });
                for (arr) |item| {
                    try output.append(allocator, '\n');
                    try output.appendSlice(allocator, "[[");
                    try output.appendSlice(allocator, full_key);
                    try output.appendSlice(allocator, "]]\n");
                    if (item == .table) {
                        for (item.table) |sub_entry| {
                            try serializeKeyValue(allocator, output, sub_entry.key, sub_entry.value);
                        }
                    }
                }
            }
        }
    }
}

fn serializeKeyValue(allocator: std.mem.Allocator, output: *std.ArrayList(u8), key: []const u8, value: Value) !void {
    try serializeKey(allocator, output, key);
    try output.appendSlice(allocator, " = ");
    try serializeInlineValue(allocator, output, value);
    try output.append(allocator, '\n');
}

fn serializeKey(allocator: std.mem.Allocator, output: *std.ArrayList(u8), key: []const u8) !void {
    if (bareKeyValid(key)) {
        try output.appendSlice(allocator, key);
    } else {
        try output.append(allocator, '"');
        for (key) |c| {
            if (c == '"') {
                try output.appendSlice(allocator, "\\\"");
            } else if (c == '\\') {
                try output.appendSlice(allocator, "\\\\");
            } else {
                try output.append(allocator, c);
            }
        }
        try output.append(allocator, '"');
    }
}

fn bareKeyValid(key: []const u8) bool {
    if (key.len == 0) return false;
    for (key) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return false;
    }
    return true;
}

fn serializeInlineValue(allocator: std.mem.Allocator, output: *std.ArrayList(u8), value: Value) !void {
    switch (value) {
        .string => |s| {
            try output.append(allocator, '"');
            for (s) |c| {
                switch (c) {
                    '"' => try output.appendSlice(allocator, "\\\""),
                    '\\' => try output.appendSlice(allocator, "\\\\"),
                    '\n' => try output.appendSlice(allocator, "\\n"),
                    '\t' => try output.appendSlice(allocator, "\\t"),
                    '\r' => try output.appendSlice(allocator, "\\r"),
                    0x08 => try output.appendSlice(allocator, "\\b"),
                    0x0C => try output.appendSlice(allocator, "\\f"),
                    else => try output.append(allocator, c),
                }
            }
            try output.append(allocator, '"');
        },
        .integer => |n| {
            try std.fmt.format(output.writer(allocator), "{d}", .{n});
        },
        .float => |f| {
            if (std.math.isInf(f)) {
                if (f < 0) {
                    try output.appendSlice(allocator, "-inf");
                } else {
                    try output.appendSlice(allocator, "inf");
                }
            } else if (std.math.isNan(f)) {
                try output.appendSlice(allocator, "nan");
            } else {
                try std.fmt.format(output.writer(allocator), "{d}", .{f});
            }
        },
        .boolean => |b| {
            try output.appendSlice(allocator, if (b) "true" else "false");
        },
        .datetime => |dt| {
            try output.appendSlice(allocator, dt);
        },
        .array => |items| {
            try output.append(allocator, '[');
            for (items, 0..) |item, idx| {
                if (idx > 0) try output.appendSlice(allocator, ", ");
                try serializeInlineValue(allocator, output, item);
            }
            try output.append(allocator, ']');
        },
        .table => |entries| {
            try output.append(allocator, '{');
            for (entries, 0..) |entry, idx| {
                if (idx > 0) try output.appendSlice(allocator, ", ");
                try serializeKey(allocator, output, entry.key);
                try output.appendSlice(allocator, " = ");
                try serializeInlineValue(allocator, output, entry.value);
            }
            try output.append(allocator, '}');
        },
    }
}

/// Convert a TOML Value tree to std.json.Value for interop with other commands.
pub fn toJsonValue(allocator: std.mem.Allocator, value: Value) !std.json.Value {
    switch (value) {
        .string => |s| return .{ .string = s },
        .integer => |n| return .{ .integer = n },
        .float => |f| return .{ .float = f },
        .boolean => |b| return .{ .bool = b },
        .datetime => |dt| return .{ .string = dt },
        .array => |items| {
            var arr = std.json.Array.init(allocator);
            for (items) |item| {
                const jval = try toJsonValue(allocator, item);
                try arr.append(jval);
            }
            return .{ .array = arr };
        },
        .table => |entries| {
            var obj = std.json.ObjectMap.init(allocator);
            for (entries) |entry| {
                const jval = try toJsonValue(allocator, entry.value);
                try obj.put(entry.key, jval);
            }
            return .{ .object = obj };
        },
    }
}

/// Convert a std.json.Value tree to a TOML Value.
pub fn fromJsonValue(allocator: std.mem.Allocator, jval: std.json.Value) !Value {
    switch (jval) {
        .null => return .{ .string = "null" },
        .bool => |b| return .{ .boolean = b },
        .integer => |n| return .{ .integer = n },
        .float => |f| return .{ .float = f },
        .string => |s| return .{ .string = s },
        .number_string => |s| return .{ .string = s },
        .array => |arr| {
            var items = std.ArrayList(Value){};
            for (arr.items) |item| {
                const v = try fromJsonValue(allocator, item);
                try items.append(allocator, v);
            }
            return .{ .array = try items.toOwnedSlice(allocator) };
        },
        .object => |obj| {
            var entries = std.ArrayList(TableEntry){};
            var it = obj.iterator();
            while (it.next()) |kv| {
                const v = try fromJsonValue(allocator, kv.value_ptr.*);
                try entries.append(allocator, .{
                    .key = try allocator.dupe(u8, kv.key_ptr.*),
                    .value = v,
                });
            }
            return .{ .table = try entries.toOwnedSlice(allocator) };
        },
    }
}

// --- Tests ---

test "parse simple key-value" {
    const input = "title = \"TOML Example\"\n";
    var result = try parse(std.testing.allocator, input);
    defer result.deinit();

    try std.testing.expect(result.value == .table);
    const entries = result.value.table;
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("title", entries[0].key);
    try std.testing.expectEqualStrings("TOML Example", entries[0].value.string);
}

test "parse multiple key-value pairs" {
    const input = "name = \"zuxi\"\nversion = \"0.1.0\"\n";
    var result = try parse(std.testing.allocator, input);
    defer result.deinit();

    try std.testing.expect(result.value == .table);
    const entries = result.value.table;
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("name", entries[0].key);
    try std.testing.expectEqualStrings("zuxi", entries[0].value.string);
    try std.testing.expectEqualStrings("version", entries[1].key);
    try std.testing.expectEqualStrings("0.1.0", entries[1].value.string);
}

test "parse integer values" {
    const input = "port = 8080\nnegative = -42\n";
    var result = try parse(std.testing.allocator, input);
    defer result.deinit();

    const entries = result.value.table;
    try std.testing.expectEqual(@as(i64, 8080), entries[0].value.integer);
    try std.testing.expectEqual(@as(i64, -42), entries[1].value.integer);
}

test "parse float values" {
    const input = "pi = 3.14\nneg = -0.5\n";
    var result = try parse(std.testing.allocator, input);
    defer result.deinit();

    const entries = result.value.table;
    try std.testing.expectEqual(@as(f64, 3.14), entries[0].value.float);
    try std.testing.expectEqual(@as(f64, -0.5), entries[1].value.float);
}

test "parse boolean values" {
    const input = "enabled = true\ndebug = false\n";
    var result = try parse(std.testing.allocator, input);
    defer result.deinit();

    const entries = result.value.table;
    try std.testing.expectEqual(true, entries[0].value.boolean);
    try std.testing.expectEqual(false, entries[1].value.boolean);
}

test "parse array" {
    const input = "colors = [\"red\", \"green\", \"blue\"]\n";
    var result = try parse(std.testing.allocator, input);
    defer result.deinit();

    const entries = result.value.table;
    try std.testing.expect(entries[0].value == .array);
    const arr = entries[0].value.array;
    try std.testing.expectEqual(@as(usize, 3), arr.len);
    try std.testing.expectEqualStrings("red", arr[0].string);
    try std.testing.expectEqualStrings("green", arr[1].string);
    try std.testing.expectEqualStrings("blue", arr[2].string);
}

test "parse integer array" {
    const input = "ports = [80, 443, 8080]\n";
    var result = try parse(std.testing.allocator, input);
    defer result.deinit();

    const arr = result.value.table[0].value.array;
    try std.testing.expectEqual(@as(usize, 3), arr.len);
    try std.testing.expectEqual(@as(i64, 80), arr[0].integer);
    try std.testing.expectEqual(@as(i64, 443), arr[1].integer);
    try std.testing.expectEqual(@as(i64, 8080), arr[2].integer);
}

test "parse table section" {
    const input = "[server]\nhost = \"localhost\"\nport = 8080\n";
    var result = try parse(std.testing.allocator, input);
    defer result.deinit();

    const entries = result.value.table;
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("server", entries[0].key);
    try std.testing.expect(entries[0].value == .table);
    const server = entries[0].value.table;
    try std.testing.expectEqual(@as(usize, 2), server.len);
    try std.testing.expectEqualStrings("host", server[0].key);
    try std.testing.expectEqualStrings("localhost", server[0].value.string);
    try std.testing.expectEqual(@as(i64, 8080), server[1].value.integer);
}

test "parse nested table" {
    const input = "[database.primary]\nhost = \"db.example.com\"\nport = 5432\n";
    var result = try parse(std.testing.allocator, input);
    defer result.deinit();

    const entries = result.value.table;
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("database", entries[0].key);
    try std.testing.expect(entries[0].value == .table);
    const db = entries[0].value.table;
    try std.testing.expectEqualStrings("primary", db[0].key);
    try std.testing.expect(db[0].value == .table);
    const primary = db[0].value.table;
    try std.testing.expectEqualStrings("host", primary[0].key);
}

test "parse array of tables" {
    const input = "[[products]]\nname = \"Hammer\"\n\n[[products]]\nname = \"Nail\"\n";
    var result = try parse(std.testing.allocator, input);
    defer result.deinit();

    const entries = result.value.table;
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("products", entries[0].key);
    try std.testing.expect(entries[0].value == .array);
    const arr = entries[0].value.array;
    try std.testing.expectEqual(@as(usize, 2), arr.len);
    try std.testing.expect(arr[0] == .table);
    try std.testing.expectEqualStrings("Hammer", arr[0].table[0].value.string);
    try std.testing.expect(arr[1] == .table);
    try std.testing.expectEqualStrings("Nail", arr[1].table[0].value.string);
}

test "parse inline table" {
    const input = "point = {x = 1, y = 2}\n";
    var result = try parse(std.testing.allocator, input);
    defer result.deinit();

    const entries = result.value.table;
    try std.testing.expect(entries[0].value == .table);
    const point = entries[0].value.table;
    try std.testing.expectEqual(@as(usize, 2), point.len);
    try std.testing.expectEqualStrings("x", point[0].key);
    try std.testing.expectEqual(@as(i64, 1), point[0].value.integer);
    try std.testing.expectEqualStrings("y", point[1].key);
    try std.testing.expectEqual(@as(i64, 2), point[1].value.integer);
}

test "parse comments are ignored" {
    const input = "# This is a comment\nname = \"zuxi\" # inline comment\n";
    var result = try parse(std.testing.allocator, input);
    defer result.deinit();

    const entries = result.value.table;
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("zuxi", entries[0].value.string);
}

test "parse literal string" {
    const input = "path = 'C:\\Users\\name'\n";
    var result = try parse(std.testing.allocator, input);
    defer result.deinit();

    try std.testing.expectEqualStrings("C:\\Users\\name", result.value.table[0].value.string);
}

test "parse escape sequences in basic string" {
    const input = "text = \"hello\\nworld\\ttab\"\n";
    var result = try parse(std.testing.allocator, input);
    defer result.deinit();

    try std.testing.expectEqualStrings("hello\nworld\ttab", result.value.table[0].value.string);
}

test "parse hex integer" {
    const input = "color = 0xff\n";
    var result = try parse(std.testing.allocator, input);
    defer result.deinit();

    try std.testing.expectEqual(@as(i64, 255), result.value.table[0].value.integer);
}

test "parse octal integer" {
    const input = "perm = 0o755\n";
    var result = try parse(std.testing.allocator, input);
    defer result.deinit();

    try std.testing.expectEqual(@as(i64, 493), result.value.table[0].value.integer);
}

test "parse binary integer" {
    const input = "mask = 0b11010110\n";
    var result = try parse(std.testing.allocator, input);
    defer result.deinit();

    try std.testing.expectEqual(@as(i64, 214), result.value.table[0].value.integer);
}

test "parse integer with underscores" {
    const input = "big = 1_000_000\n";
    var result = try parse(std.testing.allocator, input);
    defer result.deinit();

    try std.testing.expectEqual(@as(i64, 1_000_000), result.value.table[0].value.integer);
}

test "parse datetime" {
    const input = "created = 2024-01-15T10:30:00Z\n";
    var result = try parse(std.testing.allocator, input);
    defer result.deinit();

    try std.testing.expect(result.value.table[0].value == .datetime);
    try std.testing.expectEqualStrings("2024-01-15T10:30:00Z", result.value.table[0].value.datetime);
}

test "parse date only" {
    const input = "date = 2024-01-15\n";
    var result = try parse(std.testing.allocator, input);
    defer result.deinit();

    try std.testing.expect(result.value.table[0].value == .datetime);
    try std.testing.expectEqualStrings("2024-01-15", result.value.table[0].value.datetime);
}

test "parse special float values" {
    const input = "pos_inf = inf\nneg_inf = -inf\nnot_a_number = nan\n";
    var result = try parse(std.testing.allocator, input);
    defer result.deinit();

    const entries = result.value.table;
    try std.testing.expect(std.math.isInf(entries[0].value.float));
    try std.testing.expect(entries[0].value.float > 0);
    try std.testing.expect(std.math.isInf(entries[1].value.float));
    try std.testing.expect(entries[1].value.float < 0);
    try std.testing.expect(std.math.isNan(entries[2].value.float));
}

test "parse empty table" {
    const input = "[empty]\n";
    var result = try parse(std.testing.allocator, input);
    defer result.deinit();

    const entries = result.value.table;
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("empty", entries[0].key);
    try std.testing.expect(entries[0].value == .table);
    try std.testing.expectEqual(@as(usize, 0), entries[0].value.table.len);
}

test "parse empty input" {
    var result = try parse(std.testing.allocator, "");
    defer result.deinit();

    try std.testing.expect(result.value == .table);
    try std.testing.expectEqual(@as(usize, 0), result.value.table.len);
}

test "parse multiline array" {
    const input = "arr = [\n  1,\n  2,\n  3\n]\n";
    var result = try parse(std.testing.allocator, input);
    defer result.deinit();

    const arr = result.value.table[0].value.array;
    try std.testing.expectEqual(@as(usize, 3), arr.len);
    try std.testing.expectEqual(@as(i64, 1), arr[0].integer);
    try std.testing.expectEqual(@as(i64, 2), arr[1].integer);
    try std.testing.expectEqual(@as(i64, 3), arr[2].integer);
}

test "parse mixed types in document" {
    const input =
        \\title = "My Config"
        \\debug = true
        \\port = 8080
        \\
        \\[server]
        \\host = "0.0.0.0"
        \\
    ;
    var result = try parse(std.testing.allocator, input);
    defer result.deinit();

    const entries = result.value.table;
    // Root: title, debug, port, server
    try std.testing.expect(entries.len >= 3);
    try std.testing.expectEqualStrings("title", entries[0].key);
    try std.testing.expectEqualStrings("My Config", entries[0].value.string);
    try std.testing.expectEqual(true, entries[1].value.boolean);
    try std.testing.expectEqual(@as(i64, 8080), entries[2].value.integer);
}

test "serialize simple key-values" {
    const entries = [_]TableEntry{
        .{ .key = "name", .value = .{ .string = "zuxi" } },
        .{ .key = "port", .value = .{ .integer = 8080 } },
        .{ .key = "debug", .value = .{ .boolean = true } },
    };
    const value = Value{ .table = &entries };

    const output = try serialize(std.testing.allocator, value);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "name = \"zuxi\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "port = 8080") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "debug = true") != null);
}

test "serialize array" {
    const arr_items = [_]Value{
        .{ .integer = 1 },
        .{ .integer = 2 },
        .{ .integer = 3 },
    };
    const entries = [_]TableEntry{
        .{ .key = "numbers", .value = .{ .array = &arr_items } },
    };
    const value = Value{ .table = &entries };

    const output = try serialize(std.testing.allocator, value);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "numbers = [1, 2, 3]") != null);
}

test "serialize string escaping" {
    const entries = [_]TableEntry{
        .{ .key = "text", .value = .{ .string = "hello\nworld" } },
    };
    const value = Value{ .table = &entries };

    const output = try serialize(std.testing.allocator, value);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "text = \"hello\\nworld\"") != null);
}

test "serialize inline table" {
    const inner = [_]TableEntry{
        .{ .key = "x", .value = .{ .integer = 1 } },
        .{ .key = "y", .value = .{ .integer = 2 } },
    };
    const entries = [_]TableEntry{
        .{ .key = "point", .value = .{ .table = &inner } },
    };
    const value = Value{ .table = &entries };

    const output = try serialize(std.testing.allocator, value);
    defer std.testing.allocator.free(output);
    // Tables at top level become [table] sections.
    try std.testing.expect(std.mem.indexOf(u8, output, "[point]") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "x = 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "y = 2") != null);
}

test "roundtrip simple document" {
    const input = "name = \"zuxi\"\nport = 8080\ndebug = true\n";
    var result = try parse(std.testing.allocator, input);
    defer result.deinit();

    const output = try serialize(std.testing.allocator, result.value);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "name = \"zuxi\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "port = 8080") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "debug = true") != null);
}

test "roundtrip with table section" {
    const input = "title = \"Config\"\n\n[server]\nhost = \"localhost\"\nport = 8080\n";
    var result = try parse(std.testing.allocator, input);
    defer result.deinit();

    const output = try serialize(std.testing.allocator, result.value);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "title = \"Config\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "[server]") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "host = \"localhost\"") != null);
}

test "bareKeyValid" {
    try std.testing.expect(bareKeyValid("name"));
    try std.testing.expect(bareKeyValid("my-key"));
    try std.testing.expect(bareKeyValid("key_123"));
    try std.testing.expect(!bareKeyValid(""));
    try std.testing.expect(!bareKeyValid("has space"));
    try std.testing.expect(!bareKeyValid("has.dot"));
}

test "isDatetime" {
    try std.testing.expect(isDatetime("2024-01-15T10:30:00Z"));
    try std.testing.expect(isDatetime("2024-01-15"));
    try std.testing.expect(!isDatetime("hello"));
    try std.testing.expect(!isDatetime("42"));
    try std.testing.expect(!isDatetime("3.14"));
}

test "parse empty inline table" {
    const input = "empty = {}\n";
    var result = try parse(std.testing.allocator, input);
    defer result.deinit();

    try std.testing.expect(result.value.table[0].value == .table);
    try std.testing.expectEqual(@as(usize, 0), result.value.table[0].value.table.len);
}

test "parse empty array" {
    const input = "empty = []\n";
    var result = try parse(std.testing.allocator, input);
    defer result.deinit();

    try std.testing.expect(result.value.table[0].value == .array);
    try std.testing.expectEqual(@as(usize, 0), result.value.table[0].value.array.len);
}

test "serialize special floats" {
    const entries = [_]TableEntry{
        .{ .key = "inf_val", .value = .{ .float = std.math.inf(f64) } },
        .{ .key = "neg_inf", .value = .{ .float = -std.math.inf(f64) } },
        .{ .key = "nan_val", .value = .{ .float = std.math.nan(f64) } },
    };
    const value = Value{ .table = &entries };

    const output = try serialize(std.testing.allocator, value);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "inf_val = inf") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "neg_inf = -inf") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "nan_val = nan") != null);
}

test "serialize boolean" {
    const entries = [_]TableEntry{
        .{ .key = "a", .value = .{ .boolean = true } },
        .{ .key = "b", .value = .{ .boolean = false } },
    };
    const value = Value{ .table = &entries };

    const output = try serialize(std.testing.allocator, value);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "a = true") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "b = false") != null);
}

test "serialize datetime" {
    const entries = [_]TableEntry{
        .{ .key = "created", .value = .{ .datetime = "2024-01-15T10:30:00Z" } },
    };
    const value = Value{ .table = &entries };

    const output = try serialize(std.testing.allocator, value);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "created = 2024-01-15T10:30:00Z") != null);
}
