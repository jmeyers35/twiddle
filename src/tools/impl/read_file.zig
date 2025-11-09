const std = @import("std");
const Tools = @import("../../tools.zig");
const ManagedArrayList = std.array_list.Managed;

const limits = Tools.ReadFile.Limits{};
const hard_line_cap: usize = limits.hard_limit;
const default_line_limit: usize = limits.default_limit;
const max_line_length: usize = limits.max_line_length;
const tab_width: usize = limits.tab_width;
const slice_mode_label = "slice";
const indentation_mode_label = "indentation";
const whitespace_all = " \t\r\n";
const comment_prefixes = [_][]const u8{ "#", "//", "--" };

const ByteStream = struct {
    file: *std.fs.File,
    buffer: [4096]u8,
    head: usize = 0,
    tail: usize = 0,
    eof: bool = false,

    fn init(file: *std.fs.File) ByteStream {
        // SAFETY: buffer bytes are populated before being read from.
        return .{ .file = file, .buffer = undefined };
    }

    fn nextByte(self: *ByteStream) Error!?u8 {
        if (self.head >= self.tail) {
            if (self.eof) return null;
            const bytes_read = self.file.read(self.buffer[0..]) catch |err| switch (err) {
                error.AccessDenied => return error.PermissionDenied,
                else => return error.IoFailure,
            };
            if (bytes_read == 0) {
                self.eof = true;
                return null;
            }
            self.head = 0;
            self.tail = bytes_read;
        }
        const byte = self.buffer[self.head];
        self.head += 1;
        return byte;
    }
};

pub const Error = std.mem.Allocator.Error || error{
    InvalidPayload,
    PathOutsideSandbox,
    PathNotFound,
    PathNotFile,
    OffsetExceedsLength,
    AnchorExceedsLength,
    PermissionDenied,
    IoFailure,
};

pub fn run(executor: anytype, payload: []const u8) Error![]u8 {
    return readFile(executor, payload);
}

const Mode = enum { slice, indentation };

const IndentationConfig = struct {
    anchor_line: ?usize = null,
    max_levels: usize = 0,
    include_siblings: bool = false,
    include_header: bool = true,
    max_lines: ?usize = null,
};

const Config = struct {
    file_path: []const u8,
    offset: usize,
    limit: usize,
    mode: Mode,
    indentation: IndentationConfig,
};

fn readFile(executor: anytype, payload: []const u8) Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(executor.allocator);
    defer arena.deinit();

    const cfg = try parsePayload(arena.allocator(), payload);

    const resolved_path = try executor.resolvePath(cfg.file_path);
    defer executor.allocator.free(resolved_path);

    var file = std.fs.openFileAbsolute(resolved_path, .{ .mode = .read_only }) catch |err| switch (err) {
        error.FileNotFound => return error.PathNotFound,
        error.AccessDenied => return error.PermissionDenied,
        else => return error.IoFailure,
    };
    defer file.close();

    const stat = file.stat() catch |err| switch (err) {
        error.AccessDenied => return error.PermissionDenied,
        else => return error.IoFailure,
    };
    if (stat.kind != .file) return error.PathNotFile;

    return switch (cfg.mode) {
        .slice => sliceMode(executor, &file, cfg),
        .indentation => indentationMode(executor, &file, cfg),
    };
}

fn sliceMode(executor: anytype, file: *std.fs.File, cfg: Config) Error![]u8 {
    var stream = ByteStream.init(file);

    var source_buf = ManagedArrayList(u8).init(executor.allocator);
    defer source_buf.deinit();

    var normalized_buf = ManagedArrayList(u8).init(executor.allocator);
    defer normalized_buf.deinit();

    var formatted_buf = ManagedArrayList(u8).init(executor.allocator);
    defer formatted_buf.deinit();

    var sink = std.io.Writer.Allocating.init(executor.allocator);
    errdefer sink.deinit();
    var jw = std.json.Stringify{ .writer = &sink.writer, .options = .{ .whitespace = .minified } };

    try jsonWriteStep(jw.beginObject());
    try jsonWriteStep(jw.objectField("mode"));
    try jsonWriteStep(jw.write(slice_mode_label));
    try jsonWriteStep(jw.objectField("lines"));
    try jsonWriteStep(jw.beginArray());

    var seen: usize = 0;
    var emitted: usize = 0;
    var truncated = false;

    while (true) {
        const has_line = try readLineInto(&stream, &source_buf);
        if (!has_line) break;

        seen += 1;
        if (seen < cfg.offset) continue;

        if (emitted >= cfg.limit) {
            truncated = true;
            break;
        }

        const normalized = try normalizeLine(&normalized_buf, source_buf.items, null);
        const display_len = clampUtf8Len(normalized, max_line_length);
        const display_slice = normalized[0..display_len];
        const labeled = try formatLabeledLine(&formatted_buf, seen, display_slice);
        try jsonWriteStep(jw.write(labeled));
        emitted += 1;
    }

    if (seen < cfg.offset) return error.OffsetExceedsLength;

    try jsonWriteStep(jw.endArray());
    try jsonWriteStep(jw.objectField("truncated"));
    try jsonWriteStep(jw.write(truncated));
    try jsonWriteStep(jw.endObject());

    return sink.toOwnedSlice();
}

fn indentationMode(executor: anytype, file: *std.fs.File, cfg: Config) Error![]u8 {
    file.seekTo(0) catch |err| switch (err) {
        error.AccessDenied => return error.PermissionDenied,
        else => return error.IoFailure,
    };

    const storage_allocator = executor.allocator;
    var records_arena = std.heap.ArenaAllocator.init(storage_allocator);
    defer records_arena.deinit();

    var records = try collectRecords(records_arena.allocator(), storage_allocator, file);
    if (records.items.len == 0) return error.AnchorExceedsLength;

    const opts = cfg.indentation;

    const anchor_line = opts.anchor_line orelse cfg.offset;
    if (anchor_line == 0) return error.InvalidPayload;
    if (anchor_line > records.items.len) return error.AnchorExceedsLength;

    const guard_limit = opts.max_lines orelse cfg.limit;
    if (guard_limit == 0) return error.InvalidPayload;

    const final_limit = @min(@min(cfg.limit, guard_limit), records.items.len);
    if (final_limit == 0) return error.AnchorExceedsLength;

    const anchor_index = anchor_line - 1;
    const effective = try computeEffectiveIndents(records_arena.allocator(), records.items);
    const anchor_indent = effective[anchor_index];

    const span = blk: {
        if (opts.max_levels == 0) break :blk 0;
        const maybe_span = std.math.mul(usize, opts.max_levels, tab_width) catch std.math.maxInt(usize);
        break :blk maybe_span;
    };
    const min_indent = if (opts.max_levels == 0)
        0
    else
        saturatingSub(anchor_indent, span);

    var out = ManagedArrayList(*const LineRecord).init(records_arena.allocator());
    try out.append(&records.items[anchor_index]);

    var up_index: isize = @as(isize, @intCast(anchor_index)) - 1;
    var down_index: usize = anchor_index + 1;
    var up_min_counter: usize = 0;
    var down_min_counter: usize = 0;

    while (out.items.len < final_limit) {
        var progressed = false;

        if (up_index >= 0) {
            const idx: usize = @intCast(up_index);
            if (effective[idx] >= min_indent) {
                try out.insert(0, &records.items[idx]);
                progressed = true;
                up_index -= 1;

                if (effective[idx] == min_indent and !opts.include_siblings) {
                    const allow_header = opts.include_header and records.items[idx].isComment();
                    const can_take = allow_header or up_min_counter == 0;
                    if (can_take) {
                        up_min_counter += 1;
                    } else {
                        _ = out.orderedRemove(0);
                        progressed = false;
                        up_index = -1;
                    }
                }

                if (out.items.len >= final_limit) break;
            } else {
                up_index = -1;
            }
        }

        if (down_index < records.items.len and out.items.len < final_limit) {
            if (effective[down_index] >= min_indent) {
                try out.append(&records.items[down_index]);
                progressed = true;
                down_index += 1;

                if (effective[down_index - 1] == min_indent and !opts.include_siblings) {
                    if (down_min_counter > 0) {
                        _ = out.pop();
                        progressed = false;
                        down_index = records.items.len;
                    }
                    down_min_counter += 1;
                }
            } else {
                down_index = records.items.len;
            }
        }

        if (!progressed) break;
    }

    const reached_cap = out.items.len >= final_limit;
    trimEmptyLines(&out);

    var sink = std.io.Writer.Allocating.init(storage_allocator);
    errdefer sink.deinit();
    var jw = std.json.Stringify{ .writer = &sink.writer, .options = .{ .whitespace = .minified } };

    try jsonWriteStep(jw.beginObject());
    try jsonWriteStep(jw.objectField("mode"));
    try jsonWriteStep(jw.write(indentation_mode_label));
    try jsonWriteStep(jw.objectField("lines"));
    try jsonWriteStep(jw.beginArray());

    var formatted_buf = ManagedArrayList(u8).init(storage_allocator);
    defer formatted_buf.deinit();

    for (out.items) |record| {
        const labeled = try formatLabeledLine(&formatted_buf, record.number, record.display);
        try jsonWriteStep(jw.write(labeled));
    }

    try jsonWriteStep(jw.endArray());
    try jsonWriteStep(jw.objectField("truncated"));
    const truncated = reached_cap and (up_index >= 0 or down_index < records.items.len);
    try jsonWriteStep(jw.write(truncated));
    try jsonWriteStep(jw.endObject());

    return sink.toOwnedSlice();
}

fn readLineInto(stream: *ByteStream, buffer: *ManagedArrayList(u8)) Error!bool {
    buffer.clearRetainingCapacity();
    var saw_byte = false;
    while (true) {
        const maybe_byte = try stream.nextByte();
        if (maybe_byte == null) {
            if (!saw_byte) return false;
            break;
        }
        const byte = maybe_byte.?;
        saw_byte = true;
        if (byte == '\n') break;
        try buffer.append(byte);
    }

    if (buffer.items.len != 0 and buffer.items[buffer.items.len - 1] == '\r') {
        buffer.items.len -= 1;
    }

    return true;
}

fn normalizeLine(buffer: *ManagedArrayList(u8), bytes: []const u8, clamp: ?usize) std.mem.Allocator.Error![]const u8 {
    buffer.clearRetainingCapacity();
    try buffer.writer().print("{f}", .{std.unicode.fmtUtf8(bytes)});
    if (clamp) |max_chars| {
        const limit = clampUtf8Len(buffer.items, max_chars);
        buffer.items.len = limit;
    }
    return buffer.items;
}

fn formatLabeledLine(buffer: *ManagedArrayList(u8), line_no: usize, text: []const u8) std.mem.Allocator.Error![]const u8 {
    buffer.clearRetainingCapacity();
    try buffer.writer().print("L{}: {s}", .{ line_no, text });
    return buffer.items;
}

fn clampUtf8Len(text: []const u8, max_chars: usize) usize {
    if (text.len == 0 or max_chars == 0) return 0;
    var view = std.unicode.Utf8View.initUnchecked(text);
    var it = view.iterator();
    var consumed: usize = 0;
    var count: usize = 0;
    while (it.nextCodepointSlice()) |slice| {
        consumed += slice.len;
        count += 1;
        if (count == max_chars) break;
    }
    if (count < max_chars) return text.len;
    return consumed;
}

const LineRecord = struct {
    number: usize,
    raw: []const u8,
    display: []const u8,
    indent: usize,

    fn isBlank(self: *const LineRecord) bool {
        return std.mem.trim(u8, self.raw, whitespace_all).len == 0;
    }

    fn isComment(self: *const LineRecord) bool {
        const trimmed = std.mem.trim(u8, self.raw, whitespace_all);
        for (comment_prefixes) |prefix| {
            if (std.mem.startsWith(u8, trimmed, prefix)) return true;
        }
        return false;
    }
};

fn trimEmptyLines(list: *ManagedArrayList(*const LineRecord)) void {
    while (list.items.len != 0 and list.items[0].isBlank()) {
        _ = list.orderedRemove(0);
    }
    while (list.items.len != 0 and list.items[list.items.len - 1].isBlank()) {
        _ = list.pop();
    }
}

fn collectRecords(
    storage_allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    file: *std.fs.File,
) Error!ManagedArrayList(LineRecord) {
    var lines = ManagedArrayList(LineRecord).init(storage_allocator);

    var stream = ByteStream.init(file);

    var source_buf = ManagedArrayList(u8).init(scratch_allocator);
    defer source_buf.deinit();

    var line_no: usize = 0;
    while (true) {
        const has_line = try readLineInto(&stream, &source_buf);
        if (!has_line) break;
        line_no += 1;

        const raw_text = try allocLossy(storage_allocator, source_buf.items);
        const display_len = clampUtf8Len(raw_text, max_line_length);
        const record = LineRecord{
            .number = line_no,
            .raw = raw_text,
            .display = raw_text[0..display_len],
            .indent = measureIndent(raw_text),
        };
        try lines.append(record);
    }

    return lines;
}

fn allocLossy(allocator: std.mem.Allocator, bytes: []const u8) std.mem.Allocator.Error![]u8 {
    return std.fmt.allocPrint(allocator, "{f}", .{std.unicode.fmtUtf8(bytes)});
}

fn measureIndent(line: []const u8) usize {
    var idx: usize = 0;
    var total: usize = 0;
    while (idx < line.len) : (idx += 1) {
        const ch = line[idx];
        switch (ch) {
            ' ' => total += 1,
            '\t' => total += tab_width,
            else => return total,
        }
    }
    return total;
}

fn computeEffectiveIndents(allocator: std.mem.Allocator, records: []const LineRecord) Error![]usize {
    const list = try allocator.alloc(usize, records.len);
    var previous: usize = 0;
    for (records, 0..) |record, idx| {
        if (record.isBlank()) {
            list[idx] = previous;
        } else {
            previous = record.indent;
            list[idx] = previous;
        }
    }
    return list;
}

fn parsePayload(allocator: std.mem.Allocator, payload: []const u8) Error!Config {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidPayload,
    };
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidPayload;
    const obj = parsed.value.object;

    const path_value = obj.get("file_path") orelse return error.InvalidPayload;
    if (path_value != .string) return error.InvalidPayload;
    const trimmed_path = std.mem.trim(u8, path_value.string, whitespace_all);
    if (trimmed_path.len == 0) return error.InvalidPayload;
    const path_copy = try allocator.alloc(u8, trimmed_path.len);
    @memcpy(path_copy, trimmed_path);

    var offset: usize = 1;
    if (obj.get("offset")) |value| {
        offset = try expectPositive(value);
    }

    var limit: usize = default_line_limit;
    if (obj.get("limit")) |value| {
        const requested = try expectPositive(value);
        if (requested > hard_line_cap) return error.InvalidPayload;
        limit = requested;
    }

    var mode: Mode = .slice;
    if (obj.get("mode")) |value| {
        const label = try expectString(value);
        if (std.mem.eql(u8, label, slice_mode_label)) {
            mode = .slice;
        } else if (std.mem.eql(u8, label, indentation_mode_label)) {
            mode = .indentation;
        } else {
            return error.InvalidPayload;
        }
    }

    var indentation = IndentationConfig{};
    if (obj.get("indentation")) |value| {
        indentation = try parseIndentationOptions(value);
    }

    return Config{
        .file_path = path_copy,
        .offset = offset,
        .limit = limit,
        .mode = mode,
        .indentation = indentation,
    };
}

fn parseIndentationOptions(value: std.json.Value) Error!IndentationConfig {
    if (value != .object) return error.InvalidPayload;
    const obj = value.object;
    var opts = IndentationConfig{};

    if (obj.get("anchor_line")) |line_value| {
        opts.anchor_line = try expectPositive(line_value);
    }
    if (obj.get("max_levels")) |levels_value| {
        opts.max_levels = try expectNonNegative(levels_value);
    }
    if (obj.get("include_siblings")) |flag| {
        opts.include_siblings = try expectBool(flag);
    }
    if (obj.get("include_header")) |flag| {
        opts.include_header = try expectBool(flag);
    }
    if (obj.get("max_lines")) |max_value| {
        const requested = try expectPositive(max_value);
        if (requested > hard_line_cap) return error.InvalidPayload;
        opts.max_lines = requested;
    }

    return opts;
}

fn expectPositive(value: std.json.Value) Error!usize {
    const parsed: i64 = switch (value) {
        .integer => |v| v,
        else => return error.InvalidPayload,
    };
    if (parsed < 1) return error.InvalidPayload;
    return std.math.cast(usize, parsed) orelse return error.InvalidPayload;
}

fn expectNonNegative(value: std.json.Value) Error!usize {
    const parsed: i64 = switch (value) {
        .integer => |v| v,
        else => return error.InvalidPayload,
    };
    if (parsed < 0) return error.InvalidPayload;
    return std.math.cast(usize, parsed) orelse return error.InvalidPayload;
}

fn expectBool(value: std.json.Value) Error!bool {
    return switch (value) {
        .bool => |b| b,
        else => error.InvalidPayload,
    };
}

fn expectString(value: std.json.Value) Error![]const u8 {
    return switch (value) {
        .string => |s| s,
        else => error.InvalidPayload,
    };
}

fn saturatingSub(a: usize, b: usize) usize {
    return if (a > b) a - b else 0;
}

inline fn jsonWriteStep(res: std.json.Stringify.Error!void) Error!void {
    return res catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };
}

test "clampUtf8Len respects codepoints" {
    const sample = "héllo";
    try std.testing.expectEqual(@as(usize, 0), clampUtf8Len(sample, 0));
    try std.testing.expectEqual(@as(usize, 1), clampUtf8Len(sample, 1));
    try std.testing.expectEqual(sample.len, clampUtf8Len(sample, 10));
}
