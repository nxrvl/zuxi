const std = @import("std");

/// A YAML value: scalar, mapping (ordered key-value pairs), or sequence (list).
pub const Value = union(enum) {
    scalar: []const u8,
    mapping: []const MapEntry,
    sequence: []const Value,
};

pub const MapEntry = struct {
    key: []const u8,
    value: Value,
};

/// Parse a YAML document from text. Caller must call `deinit` on the returned
/// result to free all memory.
pub fn parse(allocator: std.mem.Allocator, source: []const u8) !ParseResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const aa = arena.allocator();

    // Split into lines, preserving original text for block scalars.
    var lines_list = std.ArrayList([]const u8){};
    var start: usize = 0;
    for (source, 0..) |c, idx| {
        if (c == '\n') {
            try lines_list.append(aa, source[start..idx]);
            start = idx + 1;
        }
    }
    if (start <= source.len) {
        try lines_list.append(aa, source[start..]);
    }
    const lines = lines_list.items;

    var ctx = ParseContext{
        .lines = lines,
        .pos = 0,
        .allocator = aa,
    };

    const value = try parseValue(&ctx, 0);
    return .{ .value = value, .arena = arena };
}

pub const ParseResult = struct {
    value: Value,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *ParseResult) void {
        self.arena.deinit();
    }
};

const ParseContext = struct {
    lines: []const []const u8,
    pos: usize,
    allocator: std.mem.Allocator,
};

/// Skip blank lines and comment-only lines starting from current position.
fn skipBlanksAndComments(ctx: *ParseContext) void {
    while (ctx.pos < ctx.lines.len) {
        const line = ctx.lines[ctx.pos];
        const stripped = std.mem.trimLeft(u8, line, " ");
        if (stripped.len == 0 or stripped[0] == '#') {
            ctx.pos += 1;
        } else {
            break;
        }
    }
}

/// Calculate the indentation level (number of leading spaces) of a line.
fn indentOf(line: []const u8) usize {
    var count: usize = 0;
    for (line) |c| {
        if (c == ' ') {
            count += 1;
        } else {
            break;
        }
    }
    return count;
}

/// Parse a value at the given minimum indentation level.
fn parseValue(ctx: *ParseContext, min_indent: usize) anyerror!Value {
    skipBlanksAndComments(ctx);
    if (ctx.pos >= ctx.lines.len) return .{ .scalar = "" };

    const line = ctx.lines[ctx.pos];
    const indent = indentOf(line);
    if (indent < min_indent) return .{ .scalar = "" };

    const content = std.mem.trimLeft(u8, line, " ");

    // Check if this is a sequence item.
    if (content.len >= 2 and content[0] == '-' and content[1] == ' ') {
        return try parseSequence(ctx, indent);
    }
    // Single dash (empty list item).
    if (content.len == 1 and content[0] == '-') {
        return try parseSequence(ctx, indent);
    }

    // Check if this is a mapping key.
    if (findUnquotedColon(content)) |_| {
        return try parseMapping(ctx, indent);
    }

    // Otherwise it's a scalar value on its own line.
    ctx.pos += 1;
    return .{ .scalar = try ctx.allocator.dupe(u8, parseScalarValue(content)) };
}

/// Parse a YAML sequence (list) at the given indentation level.
fn parseSequence(ctx: *ParseContext, base_indent: usize) anyerror!Value {
    var items = std.ArrayList(Value){};

    while (ctx.pos < ctx.lines.len) {
        skipBlanksAndComments(ctx);
        if (ctx.pos >= ctx.lines.len) break;

        const line = ctx.lines[ctx.pos];
        const indent = indentOf(line);
        if (indent != base_indent) break;

        const content = std.mem.trimLeft(u8, line, " ");
        if (content.len == 0) break;

        if (content[0] != '-') break;

        // It's a sequence item.
        if (content.len == 1) {
            // Bare dash - value is on next lines.
            ctx.pos += 1;
            const val = try parseValue(ctx, base_indent + 2);
            try items.append(ctx.allocator, val);
        } else if (content[1] == ' ') {
            // "- value" on same line.
            const after_dash = std.mem.trimLeft(u8, content[2..], " ");

            // Check for block scalar indicators.
            if (after_dash.len >= 1 and (after_dash[0] == '|' or after_dash[0] == '>')) {
                const val = try parseBlockScalar(ctx, after_dash[0], base_indent + 2);
                try items.append(ctx.allocator, val);
                continue;
            }

            // Check if after-dash content is a nested mapping.
            if (findUnquotedColon(after_dash)) |colon_pos| {
                // Inline mapping on the list item line, e.g. "- key: value".
                // Parse as a mapping starting from a virtual indented line.
                const key = std.mem.trimRight(u8, after_dash[0..colon_pos], " ");
                const rest = if (colon_pos + 1 < after_dash.len)
                    std.mem.trimLeft(u8, after_dash[colon_pos + 1 ..], " ")
                else
                    "";

                ctx.pos += 1;

                // Build the first entry.
                var entries = std.ArrayList(MapEntry){};
                const val = if (rest.len > 0) blk: {
                    // Check for block scalar.
                    if (rest[0] == '|' or rest[0] == '>') {
                        break :blk try parseBlockScalar(ctx, rest[0], base_indent + 2);
                    }
                    break :blk Value{ .scalar = try ctx.allocator.dupe(u8, parseScalarValue(rest)) };
                } else blk: {
                    // Value on next lines.
                    break :blk try parseValue(ctx, base_indent + 2);
                };
                try entries.append(ctx.allocator, .{ .key = try ctx.allocator.dupe(u8, key), .value = val });

                // Parse remaining entries at deeper indentation.
                while (ctx.pos < ctx.lines.len) {
                    skipBlanksAndComments(ctx);
                    if (ctx.pos >= ctx.lines.len) break;

                    const next_line = ctx.lines[ctx.pos];
                    const next_indent = indentOf(next_line);
                    if (next_indent <= base_indent) break;
                    // Must be deeper than the dash.
                    if (next_indent < base_indent + 2) break;

                    const next_content = std.mem.trimLeft(u8, next_line, " ");
                    if (next_content.len == 0) break;

                    if (findUnquotedColon(next_content)) |nc_pos| {
                        const nk = std.mem.trimRight(u8, next_content[0..nc_pos], " ");
                        const nv_str = if (nc_pos + 1 < next_content.len)
                            std.mem.trimLeft(u8, next_content[nc_pos + 1 ..], " ")
                        else
                            "";

                        ctx.pos += 1;
                        const nv = if (nv_str.len > 0) blk2: {
                            if (nv_str[0] == '|' or nv_str[0] == '>') {
                                break :blk2 try parseBlockScalar(ctx, nv_str[0], next_indent + 2);
                            }
                            break :blk2 Value{ .scalar = try ctx.allocator.dupe(u8, parseScalarValue(nv_str)) };
                        } else blk2: {
                            break :blk2 try parseValue(ctx, next_indent + 2);
                        };
                        try entries.append(ctx.allocator, .{ .key = try ctx.allocator.dupe(u8, nk), .value = nv });
                    } else {
                        break;
                    }
                }

                try items.append(ctx.allocator, .{ .mapping = try entries.toOwnedSlice(ctx.allocator) });
            } else {
                // Simple scalar item.
                ctx.pos += 1;
                try items.append(ctx.allocator, .{ .scalar = try ctx.allocator.dupe(u8, parseScalarValue(after_dash)) });
            }
        } else {
            // Not a valid list item format, treat as end.
            break;
        }
    }

    return .{ .sequence = try items.toOwnedSlice(ctx.allocator) };
}

/// Parse a YAML mapping at the given indentation level.
fn parseMapping(ctx: *ParseContext, base_indent: usize) anyerror!Value {
    var entries = std.ArrayList(MapEntry){};

    while (ctx.pos < ctx.lines.len) {
        skipBlanksAndComments(ctx);
        if (ctx.pos >= ctx.lines.len) break;

        const line = ctx.lines[ctx.pos];
        const indent = indentOf(line);
        if (indent != base_indent) break;

        const content = std.mem.trimLeft(u8, line, " ");
        if (content.len == 0) break;

        // Must be a "key: value" pair.
        const colon_pos = findUnquotedColon(content) orelse break;

        const key = std.mem.trimRight(u8, content[0..colon_pos], " ");
        const rest = if (colon_pos + 1 < content.len)
            std.mem.trimLeft(u8, content[colon_pos + 1 ..], " ")
        else
            "";

        ctx.pos += 1;

        const value = if (rest.len > 0) blk: {
            // Check for block scalar indicator.
            if (rest[0] == '|' or rest[0] == '>') {
                break :blk try parseBlockScalar(ctx, rest[0], base_indent + 2);
            }
            // Inline flow sequence: [item1, item2].
            if (rest[0] == '[') {
                break :blk try parseFlowSequence(ctx.allocator, rest);
            }
            // Inline flow mapping: {key: val}.
            if (rest[0] == '{') {
                break :blk try parseFlowMapping(ctx.allocator, rest);
            }
            break :blk Value{ .scalar = try ctx.allocator.dupe(u8, parseScalarValue(rest)) };
        } else blk: {
            // Value on next lines (nested structure).
            break :blk try parseValue(ctx, base_indent + 1);
        };

        try entries.append(ctx.allocator, .{
            .key = try ctx.allocator.dupe(u8, unquoteKey(key)),
            .value = value,
        });
    }

    return .{ .mapping = try entries.toOwnedSlice(ctx.allocator) };
}

/// Parse a block scalar (literal | or folded >).
fn parseBlockScalar(ctx: *ParseContext, indicator: u8, min_indent: usize) !Value {
    var result = std.ArrayList(u8){};

    // Determine the actual indentation from the first content line.
    var content_indent: ?usize = null;

    while (ctx.pos < ctx.lines.len) {
        const line = ctx.lines[ctx.pos];
        // Empty lines are part of the block.
        if (std.mem.trimLeft(u8, line, " ").len == 0) {
            if (content_indent != null) {
                // Preserve empty lines within block.
                try result.append(ctx.allocator, '\n');
            }
            ctx.pos += 1;
            continue;
        }

        const indent = indentOf(line);
        if (indent < min_indent) break;

        if (content_indent == null) {
            content_indent = indent;
        } else if (indent < content_indent.?) {
            break;
        }

        const ci = content_indent.?;
        const text = if (indent >= ci) line[ci..] else line[indent..];

        if (result.items.len > 0) {
            if (indicator == '|') {
                try result.append(ctx.allocator, '\n');
            } else {
                // Folded: replace newlines with spaces (unless blank line).
                try result.append(ctx.allocator, ' ');
            }
        }
        try result.appendSlice(ctx.allocator, text);
        ctx.pos += 1;
    }

    return .{ .scalar = result.items };
}

/// Parse a flow sequence: [item1, item2, ...]
fn parseFlowSequence(allocator: std.mem.Allocator, text: []const u8) !Value {
    // Strip outer brackets.
    if (text.len < 2 or text[0] != '[') return .{ .scalar = text };
    const inner = findMatchingBracket(text) orelse return .{ .scalar = text };
    const content = std.mem.trim(u8, text[1..inner], " ");

    var items = std.ArrayList(Value){};
    if (content.len == 0) return .{ .sequence = try items.toOwnedSlice(allocator) };

    // Split by commas (respecting nesting).
    var depth: usize = 0;
    var seg_start: usize = 0;
    for (content, 0..) |c, i| {
        if (c == '[' or c == '{') depth += 1;
        if (c == ']' or c == '}') {
            if (depth > 0) depth -= 1;
        }
        if (c == ',' and depth == 0) {
            const seg = std.mem.trim(u8, content[seg_start..i], " ");
            if (seg.len > 0) {
                try items.append(allocator, try parseFlowValue(allocator, seg));
            }
            seg_start = i + 1;
        }
    }
    const last = std.mem.trim(u8, content[seg_start..], " ");
    if (last.len > 0) {
        try items.append(allocator, try parseFlowValue(allocator, last));
    }

    return .{ .sequence = try items.toOwnedSlice(allocator) };
}

/// Parse a flow value, recursing into nested sequences/mappings.
fn parseFlowValue(allocator: std.mem.Allocator, seg: []const u8) std.mem.Allocator.Error!Value {
    if (seg.len > 0 and seg[0] == '[') {
        return parseFlowSequence(allocator, seg);
    }
    if (seg.len > 0 and seg[0] == '{') {
        return parseFlowMapping(allocator, seg);
    }
    return .{ .scalar = try allocator.dupe(u8, parseScalarValue(seg)) };
}

/// Parse a flow mapping: {key: val, key2: val2}
fn parseFlowMapping(allocator: std.mem.Allocator, text: []const u8) !Value {
    if (text.len < 2 or text[0] != '{') return .{ .scalar = text };
    const inner = findMatchingBrace(text) orelse return .{ .scalar = text };
    const content = std.mem.trim(u8, text[1..inner], " ");

    var entries = std.ArrayList(MapEntry){};
    if (content.len == 0) return .{ .mapping = try entries.toOwnedSlice(allocator) };

    var depth: usize = 0;
    var seg_start: usize = 0;
    for (content, 0..) |c, i| {
        if (c == '[' or c == '{') depth += 1;
        if (c == ']' or c == '}') {
            if (depth > 0) depth -= 1;
        }
        if (c == ',' and depth == 0) {
            try parseFlowEntry(allocator, &entries, content[seg_start..i]);
            seg_start = i + 1;
        }
    }
    try parseFlowEntry(allocator, &entries, content[seg_start..]);

    return .{ .mapping = try entries.toOwnedSlice(allocator) };
}

fn parseFlowEntry(allocator: std.mem.Allocator, entries: *std.ArrayList(MapEntry), segment: []const u8) !void {
    const trimmed = std.mem.trim(u8, segment, " ");
    if (trimmed.len == 0) return;
    // Use ": " (colon-space) as the delimiter per YAML spec for flow mappings.
    // This avoids splitting on colons inside values (e.g., URLs like http://...).
    // Fall back to bare ":" only if ": " is not found.
    const colon_pos = std.mem.indexOf(u8, trimmed, ": ") orelse std.mem.indexOf(u8, trimmed, ":") orelse return;
    const sep_len: usize = if (std.mem.indexOf(u8, trimmed, ": ") != null) 2 else 1;
    const k = std.mem.trim(u8, trimmed[0..colon_pos], " ");
    const v = std.mem.trim(u8, trimmed[colon_pos + sep_len ..], " ");
    try entries.append(allocator, .{
        .key = try allocator.dupe(u8, unquoteKey(k)),
        .value = .{ .scalar = try allocator.dupe(u8, parseScalarValue(v)) },
    });
}

fn findMatchingBracket(text: []const u8) ?usize {
    var depth: usize = 0;
    for (text, 0..) |c, i| {
        if (c == '[') depth += 1;
        if (c == ']') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn findMatchingBrace(text: []const u8) ?usize {
    var depth: usize = 0;
    for (text, 0..) |c, i| {
        if (c == '{') depth += 1;
        if (c == '}') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

/// Find the position of an unquoted colon-space (": ") or colon at end of content.
/// Returns the index of the colon, or null if not found.
fn findUnquotedColon(content: []const u8) ?usize {
    var i: usize = 0;
    while (i < content.len) {
        const c = content[i];
        if (c == '"') {
            // Skip double-quoted string (backslash escapes apply).
            i += 1;
            while (i < content.len) {
                if (content[i] == '\\' and i + 1 < content.len) {
                    i += 2;
                    continue;
                }
                if (content[i] == '"') {
                    i += 1;
                    break;
                }
                i += 1;
            }
            continue;
        }
        if (c == '\'') {
            // Skip single-quoted string (only '' is an escape, no backslash escapes).
            i += 1;
            while (i < content.len) {
                if (content[i] == '\'' and i + 1 < content.len and content[i + 1] == '\'') {
                    i += 2;
                    continue;
                }
                if (content[i] == '\'') {
                    i += 1;
                    break;
                }
                i += 1;
            }
            continue;
        }
        if (c == ':') {
            // Colon at end of line or followed by space.
            if (i + 1 >= content.len or content[i + 1] == ' ') {
                return i;
            }
        }
        i += 1;
    }
    return null;
}

/// Strip surrounding quotes from a YAML key.
fn unquoteKey(key: []const u8) []const u8 {
    if (key.len >= 2) {
        if ((key[0] == '"' and key[key.len - 1] == '"') or
            (key[0] == '\'' and key[key.len - 1] == '\''))
        {
            return key[1 .. key.len - 1];
        }
    }
    return key;
}

/// Parse a scalar value: strip inline comments, remove surrounding quotes.
fn parseScalarValue(raw: []const u8) []const u8 {
    const trimmed = std.mem.trimRight(u8, raw, " \t");
    if (trimmed.len == 0) return trimmed;

    // Remove surrounding quotes.
    if (trimmed.len >= 2) {
        if ((trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') or
            (trimmed[0] == '\'' and trimmed[trimmed.len - 1] == '\''))
        {
            return trimmed[1 .. trimmed.len - 1];
        }
    }

    // Strip inline comment (unquoted # preceded by space).
    var i: usize = 0;
    while (i < trimmed.len) {
        if (trimmed[i] == '#' and i > 0 and trimmed[i - 1] == ' ') {
            return std.mem.trimRight(u8, trimmed[0 .. i - 1], " \t");
        }
        i += 1;
    }

    return trimmed;
}

// --- Serializer ---

/// Serialize a YAML Value back to text with consistent 2-space indentation.
pub fn serialize(allocator: std.mem.Allocator, value: Value) ![]u8 {
    var output = std.ArrayList(u8){};
    errdefer output.deinit(allocator);
    try serializeValue(allocator, &output, value, 0, false);
    return try output.toOwnedSlice(allocator);
}

fn serializeValue(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    value: Value,
    indent: usize,
    inline_first: bool,
) !void {
    switch (value) {
        .scalar => |s| {
            if (!inline_first) {
                try writeSpaces(allocator, output, indent);
            }
            try writeQuotedScalar(allocator, output, s);
            try output.append(allocator, '\n');
        },
        .mapping => |entries| {
            for (entries, 0..) |entry, idx| {
                if (idx == 0 and inline_first) {
                    // First entry of a mapping inside a list item: no extra indent.
                } else {
                    try writeSpaces(allocator, output, indent);
                }
                try writeQuotedKey(allocator, output, entry.key);
                try output.append(allocator, ':');

                switch (entry.value) {
                    .scalar => |s| {
                        try output.append(allocator, ' ');
                        try writeQuotedScalar(allocator, output, s);
                        try output.append(allocator, '\n');
                    },
                    .mapping => {
                        try output.append(allocator, '\n');
                        try serializeValue(allocator, output, entry.value, indent + 2, false);
                    },
                    .sequence => {
                        try output.append(allocator, '\n');
                        try serializeValue(allocator, output, entry.value, indent + 2, false);
                    },
                }
            }
        },
        .sequence => |items| {
            for (items) |item| {
                try writeSpaces(allocator, output, indent);
                try output.appendSlice(allocator, "- ");
                switch (item) {
                    .scalar => |s| {
                        try writeQuotedScalar(allocator, output, s);
                        try output.append(allocator, '\n');
                    },
                    .mapping => {
                        try serializeValue(allocator, output, item, indent + 2, true);
                    },
                    .sequence => {
                        try output.append(allocator, '\n');
                        try serializeValue(allocator, output, item, indent + 2, false);
                    },
                }
            }
        },
    }
}

/// Write `count` spaces to output.
fn writeSpaces(allocator: std.mem.Allocator, output: *std.ArrayList(u8), count: usize) !void {
    for (0..count) |_| {
        try output.append(allocator, ' ');
    }
}

/// Write a scalar value, quoting it if it contains special characters.
fn writeQuotedScalar(allocator: std.mem.Allocator, output: *std.ArrayList(u8), s: []const u8) !void {
    if (s.len == 0) {
        try output.appendSlice(allocator, "\"\"");
        return;
    }
    if (needsQuoting(s)) {
        try output.append(allocator, '"');
        for (s) |c| {
            if (c == '"') {
                try output.appendSlice(allocator, "\\\"");
            } else if (c == '\\') {
                try output.appendSlice(allocator, "\\\\");
            } else {
                try output.append(allocator, c);
            }
        }
        try output.append(allocator, '"');
    } else {
        try output.appendSlice(allocator, s);
    }
}

/// Write a key, quoting it if needed.
fn writeQuotedKey(allocator: std.mem.Allocator, output: *std.ArrayList(u8), key: []const u8) !void {
    if (key.len == 0) {
        try output.appendSlice(allocator, "\"\"");
        return;
    }
    if (keyNeedsQuoting(key)) {
        try output.append(allocator, '"');
        for (key) |c| {
            if (c == '"') {
                try output.appendSlice(allocator, "\\\"");
            } else {
                try output.append(allocator, c);
            }
        }
        try output.append(allocator, '"');
    } else {
        try output.appendSlice(allocator, key);
    }
}

/// Check if a scalar value needs quoting in YAML output.
fn needsQuoting(s: []const u8) bool {
    if (s.len == 0) return true;
    // Starts with special characters.
    if (s[0] == '{' or s[0] == '[' or s[0] == '&' or s[0] == '*' or
        s[0] == '!' or s[0] == '|' or s[0] == '>' or s[0] == '\'' or
        s[0] == '"' or s[0] == '%' or s[0] == '@' or s[0] == '`')
        return true;

    // YAML reserved words are native types - do NOT quote them.
    // They should serialize as bare words (true, false, null, etc.)
    // so that round-trips (json2yaml -> yaml2json) preserve types.

    // Contains colon-space, hash-space, or newlines.
    for (s, 0..) |c, i| {
        if (c == ':' and i + 1 < s.len and s[i + 1] == ' ') return true;
        if (c == '#' and i > 0 and s[i - 1] == ' ') return true;
        if (c == '\n' or c == '\r') return true;
    }

    // Numeric strings are native YAML types - do NOT quote them.
    // They should serialize as bare values so round-trips preserve types.

    return false;
}

fn keyNeedsQuoting(key: []const u8) bool {
    if (key.len == 0) return true;
    for (key) |c| {
        if (c == ':' or c == ' ' or c == '#' or c == '[' or c == ']' or
            c == '{' or c == '}' or c == ',' or c == '"' or c == '\'' or
            c == '\n')
            return true;
    }
    // Check if it looks like a boolean or null.
    if (std.mem.eql(u8, key, "true") or std.mem.eql(u8, key, "false") or
        std.mem.eql(u8, key, "null") or std.mem.eql(u8, key, "yes") or
        std.mem.eql(u8, key, "no"))
        return true;
    return false;
}

fn isNumericString(s: []const u8) bool {
    if (s.len == 0) return false;
    var i: usize = 0;
    if (s[i] == '-' or s[i] == '+') i += 1;
    if (i >= s.len) return false;
    var has_digit = false;
    var has_dot = false;
    while (i < s.len) : (i += 1) {
        if (s[i] >= '0' and s[i] <= '9') {
            has_digit = true;
        } else if (s[i] == '.' and !has_dot) {
            has_dot = true;
        } else {
            return false;
        }
    }
    return has_digit;
}

/// Convert a YAML Value tree to std.json.Value for interop (e.g. with jsonstruct).
pub fn toJsonValue(allocator: std.mem.Allocator, value: Value) !std.json.Value {
    switch (value) {
        .scalar => |s| {
            // Try to infer types from YAML scalar text.
            if (s.len == 0) return .null;
            if (std.mem.eql(u8, s, "null") or std.mem.eql(u8, s, "~") or
                std.mem.eql(u8, s, "Null") or std.mem.eql(u8, s, "NULL"))
                return .null;
            if (std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "True") or
                std.mem.eql(u8, s, "TRUE") or std.mem.eql(u8, s, "yes") or
                std.mem.eql(u8, s, "Yes") or std.mem.eql(u8, s, "YES"))
                return .{ .bool = true };
            if (std.mem.eql(u8, s, "false") or std.mem.eql(u8, s, "False") or
                std.mem.eql(u8, s, "FALSE") or std.mem.eql(u8, s, "no") or
                std.mem.eql(u8, s, "No") or std.mem.eql(u8, s, "NO"))
                return .{ .bool = false };
            // Try integer.
            if (std.fmt.parseInt(i64, s, 10)) |n| {
                return .{ .integer = n };
            } else |_| {}
            // Try float.
            if (std.fmt.parseFloat(f64, s)) |f| {
                // Only treat as float if it contains a dot or 'e'/'E'.
                if (std.mem.indexOf(u8, s, ".") != null or
                    std.mem.indexOf(u8, s, "e") != null or
                    std.mem.indexOf(u8, s, "E") != null)
                {
                    return .{ .float = f };
                }
            } else |_| {}
            return .{ .string = s };
        },
        .mapping => |entries| {
            var obj = std.json.ObjectMap.init(allocator);
            for (entries) |entry| {
                const jval = try toJsonValue(allocator, entry.value);
                try obj.put(entry.key, jval);
            }
            return .{ .object = obj };
        },
        .sequence => |items| {
            var arr = std.json.Array.init(allocator);
            for (items) |item| {
                const jval = try toJsonValue(allocator, item);
                try arr.append(jval);
            }
            return .{ .array = arr };
        },
    }
}

/// Convert a std.json.Value tree to a YAML Value.
pub fn fromJsonValue(allocator: std.mem.Allocator, jval: std.json.Value) !Value {
    switch (jval) {
        .null => return .{ .scalar = try allocator.dupe(u8, "null") },
        .bool => |b| return .{ .scalar = try allocator.dupe(u8, if (b) "true" else "false") },
        .integer => |n| {
            const s = try std.fmt.allocPrint(allocator, "{d}", .{n});
            return .{ .scalar = s };
        },
        .float => |f| {
            const s = try std.fmt.allocPrint(allocator, "{d}", .{f});
            return .{ .scalar = s };
        },
        .string => |s| return .{ .scalar = try allocator.dupe(u8, s) },
        .number_string => |s| return .{ .scalar = try allocator.dupe(u8, s) },
        .array => |arr| {
            var items = std.ArrayList(Value){};
            for (arr.items) |item| {
                const v = try fromJsonValue(allocator, item);
                try items.append(allocator, v);
            }
            return .{ .sequence = try items.toOwnedSlice(allocator) };
        },
        .object => |obj| {
            var entries = std.ArrayList(MapEntry){};
            var it = obj.iterator();
            while (it.next()) |kv| {
                const v = try fromJsonValue(allocator, kv.value_ptr.*);
                try entries.append(allocator, .{
                    .key = try allocator.dupe(u8, kv.key_ptr.*),
                    .value = v,
                });
            }
            return .{ .mapping = try entries.toOwnedSlice(allocator) };
        },
    }
}

// --- Tests ---

test "parse simple mapping" {
    const yaml = "name: zuxi\nversion: 1";
    var result = try parse(std.testing.allocator, yaml);
    defer result.deinit();

    try std.testing.expect(result.value == .mapping);
    const entries = result.value.mapping;
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("name", entries[0].key);
    try std.testing.expectEqualStrings("zuxi", entries[0].value.scalar);
    try std.testing.expectEqualStrings("version", entries[1].key);
    try std.testing.expectEqualStrings("1", entries[1].value.scalar);
}

test "parse simple sequence" {
    const yaml = "- apple\n- banana\n- cherry";
    var result = try parse(std.testing.allocator, yaml);
    defer result.deinit();

    try std.testing.expect(result.value == .sequence);
    const items = result.value.sequence;
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqualStrings("apple", items[0].scalar);
    try std.testing.expectEqualStrings("banana", items[1].scalar);
    try std.testing.expectEqualStrings("cherry", items[2].scalar);
}

test "parse nested mapping" {
    const yaml = "server:\n  host: localhost\n  port: 8080";
    var result = try parse(std.testing.allocator, yaml);
    defer result.deinit();

    try std.testing.expect(result.value == .mapping);
    const entries = result.value.mapping;
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("server", entries[0].key);
    try std.testing.expect(entries[0].value == .mapping);
    const nested = entries[0].value.mapping;
    try std.testing.expectEqual(@as(usize, 2), nested.len);
    try std.testing.expectEqualStrings("host", nested[0].key);
    try std.testing.expectEqualStrings("localhost", nested[0].value.scalar);
}

test "parse mapping with sequence value" {
    const yaml = "fruits:\n  - apple\n  - banana";
    var result = try parse(std.testing.allocator, yaml);
    defer result.deinit();

    try std.testing.expect(result.value == .mapping);
    const entries = result.value.mapping;
    try std.testing.expectEqualStrings("fruits", entries[0].key);
    try std.testing.expect(entries[0].value == .sequence);
    const items = entries[0].value.sequence;
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("apple", items[0].scalar);
    try std.testing.expectEqualStrings("banana", items[1].scalar);
}

test "parse comments are ignored" {
    const yaml = "# This is a comment\nname: zuxi\n# Another comment\nversion: 1";
    var result = try parse(std.testing.allocator, yaml);
    defer result.deinit();

    try std.testing.expect(result.value == .mapping);
    try std.testing.expectEqual(@as(usize, 2), result.value.mapping.len);
    try std.testing.expectEqualStrings("name", result.value.mapping[0].key);
    try std.testing.expectEqualStrings("zuxi", result.value.mapping[0].value.scalar);
}

test "parse quoted strings" {
    const yaml = "name: \"hello world\"\nsingle: 'test value'";
    var result = try parse(std.testing.allocator, yaml);
    defer result.deinit();

    try std.testing.expect(result.value == .mapping);
    try std.testing.expectEqualStrings("hello world", result.value.mapping[0].value.scalar);
    try std.testing.expectEqualStrings("test value", result.value.mapping[1].value.scalar);
}

test "parse literal block scalar" {
    const yaml = "description: |\n  line one\n  line two\n  line three";
    var result = try parse(std.testing.allocator, yaml);
    defer result.deinit();

    try std.testing.expect(result.value == .mapping);
    const desc = result.value.mapping[0].value.scalar;
    try std.testing.expect(std.mem.indexOf(u8, desc, "line one") != null);
    try std.testing.expect(std.mem.indexOf(u8, desc, "line two") != null);
    try std.testing.expect(std.mem.indexOf(u8, desc, "line three") != null);
}

test "parse folded block scalar" {
    const yaml = "description: >\n  first part\n  second part";
    var result = try parse(std.testing.allocator, yaml);
    defer result.deinit();

    try std.testing.expect(result.value == .mapping);
    const desc = result.value.mapping[0].value.scalar;
    try std.testing.expect(std.mem.indexOf(u8, desc, "first part") != null);
    try std.testing.expect(std.mem.indexOf(u8, desc, "second part") != null);
}

test "parse sequence of mappings" {
    const yaml = "- name: Alice\n  age: 30\n- name: Bob\n  age: 25";
    var result = try parse(std.testing.allocator, yaml);
    defer result.deinit();

    try std.testing.expect(result.value == .sequence);
    const items = result.value.sequence;
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expect(items[0] == .mapping);
    try std.testing.expectEqualStrings("name", items[0].mapping[0].key);
    try std.testing.expectEqualStrings("Alice", items[0].mapping[0].value.scalar);
}

test "parse empty input" {
    var result = try parse(std.testing.allocator, "");
    defer result.deinit();
    try std.testing.expect(result.value == .scalar);
}

test "parse flow sequence" {
    const yaml = "tags: [dev, test, prod]";
    var result = try parse(std.testing.allocator, yaml);
    defer result.deinit();

    try std.testing.expect(result.value == .mapping);
    try std.testing.expect(result.value.mapping[0].value == .sequence);
    const items = result.value.mapping[0].value.sequence;
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqualStrings("dev", items[0].scalar);
    try std.testing.expectEqualStrings("test", items[1].scalar);
    try std.testing.expectEqualStrings("prod", items[2].scalar);
}

test "parse flow mapping" {
    const yaml = "config: {debug: true, port: 8080}";
    var result = try parse(std.testing.allocator, yaml);
    defer result.deinit();

    try std.testing.expect(result.value == .mapping);
    try std.testing.expect(result.value.mapping[0].value == .mapping);
    const nested = result.value.mapping[0].value.mapping;
    try std.testing.expectEqual(@as(usize, 2), nested.len);
    try std.testing.expectEqualStrings("debug", nested[0].key);
    try std.testing.expectEqualStrings("true", nested[0].value.scalar);
}

test "serialize simple mapping" {
    const entries = [_]MapEntry{
        .{ .key = "name", .value = .{ .scalar = "zuxi" } },
        .{ .key = "version", .value = .{ .scalar = "1" } },
    };
    const value = Value{ .mapping = &entries };

    const output = try serialize(std.testing.allocator, value);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "name: zuxi\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "version: 1\n") != null);
}

test "serialize simple sequence" {
    const items = [_]Value{
        .{ .scalar = "apple" },
        .{ .scalar = "banana" },
    };
    const value = Value{ .sequence = &items };

    const output = try serialize(std.testing.allocator, value);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "- apple\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "- banana\n") != null);
}

test "serialize nested mapping" {
    const inner = [_]MapEntry{
        .{ .key = "host", .value = .{ .scalar = "localhost" } },
    };
    const outer = [_]MapEntry{
        .{ .key = "server", .value = .{ .mapping = &inner } },
    };
    const value = Value{ .mapping = &outer };

    const output = try serialize(std.testing.allocator, value);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "server:\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "  host: localhost\n") != null);
}

test "serialize quotes special values" {
    const entries = [_]MapEntry{
        .{ .key = "active", .value = .{ .scalar = "true" } },
        .{ .key = "empty", .value = .{ .scalar = "" } },
    };
    const value = Value{ .mapping = &entries };

    const output = try serialize(std.testing.allocator, value);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "active: true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "empty: \"\"\n") != null);
}

test "roundtrip simple mapping" {
    const yaml = "name: zuxi\ndebug: enabled\n";
    var result = try parse(std.testing.allocator, yaml);
    defer result.deinit();

    const output = try serialize(std.testing.allocator, result.value);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "name: zuxi") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "debug: enabled") != null);
}

test "toJsonValue scalars" {
    var result = try parse(std.testing.allocator, "name: zuxi\ncount: 42\npi: 3.14\nactive: true\nempty: null");
    defer result.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const jval = try toJsonValue(arena.allocator(), result.value);

    try std.testing.expect(jval == .object);
    try std.testing.expectEqualStrings("zuxi", jval.object.get("name").?.string);
    try std.testing.expectEqual(@as(i64, 42), jval.object.get("count").?.integer);
    try std.testing.expectEqual(@as(f64, 3.14), jval.object.get("pi").?.float);
    try std.testing.expectEqual(true, jval.object.get("active").?.bool);
    try std.testing.expect(jval.object.get("empty").? == .null);
}

test "toJsonValue sequence" {
    var result = try parse(std.testing.allocator, "- one\n- 2\n- true");
    defer result.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const jval = try toJsonValue(arena.allocator(), result.value);

    try std.testing.expect(jval == .array);
    try std.testing.expectEqual(@as(usize, 3), jval.array.items.len);
    try std.testing.expectEqualStrings("one", jval.array.items[0].string);
    try std.testing.expectEqual(@as(i64, 2), jval.array.items[1].integer);
    try std.testing.expectEqual(true, jval.array.items[2].bool);
}

test "findUnquotedColon basic" {
    try std.testing.expectEqual(@as(?usize, 4), findUnquotedColon("name: value"));
    try std.testing.expectEqual(@as(?usize, null), findUnquotedColon("no colon here"));
}

test "findUnquotedColon ignores colon in quotes" {
    try std.testing.expectEqual(@as(?usize, null), findUnquotedColon("\"key: with colon\""));
}

test "parseScalarValue strips inline comment" {
    const result = parseScalarValue("hello # comment");
    try std.testing.expectEqualStrings("hello", result);
}

test "parseScalarValue preserves unquoted value" {
    const result = parseScalarValue("just a value");
    try std.testing.expectEqualStrings("just a value", result);
}

test "needsQuoting for special values" {
    // YAML native types (true, false, null, numbers) should NOT be quoted
    // so that round-trips preserve types correctly.
    try std.testing.expect(!needsQuoting("true"));
    try std.testing.expect(!needsQuoting("false"));
    try std.testing.expect(!needsQuoting("null"));
    try std.testing.expect(!needsQuoting("42"));
    try std.testing.expect(!needsQuoting("3.14"));
    try std.testing.expect(needsQuoting(""));
    try std.testing.expect(!needsQuoting("hello"));
    try std.testing.expect(!needsQuoting("some-text"));
}
