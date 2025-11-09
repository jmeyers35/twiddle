const std = @import("std");

const ManagedArrayList = std.array_list.Managed;

const max_paths = 16;
const max_globs = 32;
const max_command_output = 512 * 1024;
const max_stderr_note = 512;

pub const Error = std.mem.Allocator.Error || error{
    InvalidPayload,
    PathOutsideSandbox,
    PathNotFound,
    PermissionDenied,
    BinaryUnavailable,
    CommandFailed,
    ToolLimitExceeded,
    IoFailure,
};

pub fn run(executor: anytype, payload: []const u8) Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(executor.allocator);
    defer arena.deinit();

    const parsed = try parsePayload(arena.allocator(), payload);

    return switch (parsed.engine) {
        .ripgrep => ripgrepSearch(executor, parsed),
        .ast_grep => astGrepSearch(executor, parsed),
    };
}

const Engine = enum { ripgrep, ast_grep };

const ParsedPayload = struct {
    pattern: []const u8,
    engine: Engine,
    raw_paths: []const []const u8,
    include_globs: []const []const u8,
    exclude_globs: []const []const u8,
    case_sensitive: bool,
    regex: bool,
    context_before: usize,
    context_after: usize,
    limit: usize,
    ast_language: ?[]const u8,
};

fn parsePayload(allocator: std.mem.Allocator, payload: []const u8) Error!ParsedPayload {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidPayload,
    };
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidPayload;
    const obj = parsed.value.object;

    const pattern_value = obj.get("pattern") orelse return error.InvalidPayload;
    if (pattern_value != .string) return error.InvalidPayload;
    const raw_pattern = pattern_value.string;
    const trimmed_pattern = std.mem.trim(u8, raw_pattern, " \r\n\t");
    if (trimmed_pattern.len == 0) return error.InvalidPayload;
    const pattern_copy = try dupSlice(allocator, raw_pattern);

    var engine: Engine = .ripgrep;
    if (obj.get("engine")) |value| {
        if (value != .string) return error.InvalidPayload;
        const trimmed_engine = std.mem.trim(u8, value.string, " \t\r\n");
        if (trimmed_engine.len == 0) return error.InvalidPayload;
        if (std.ascii.eqlIgnoreCase(trimmed_engine, "ast-grep") or std.ascii.eqlIgnoreCase(trimmed_engine, "ast_grep")) {
            engine = .ast_grep;
        } else if (std.ascii.eqlIgnoreCase(trimmed_engine, "ripgrep")) {
            engine = .ripgrep;
        } else return error.InvalidPayload;
    }

    const raw_paths = try parseStringArray(allocator, obj, "paths");
    if (raw_paths.len > max_paths) return error.InvalidPayload;

    const include_globs = try parseStringArray(allocator, obj, "include_globs");
    if (include_globs.len > max_globs) return error.InvalidPayload;

    const exclude_globs = try parseStringArray(allocator, obj, "exclude_globs");
    if (exclude_globs.len > max_globs) return error.InvalidPayload;

    var case_sensitive = true;
    if (obj.get("case_sensitive")) |value| {
        case_sensitive = try expectBool(value);
    }

    var regex = false;
    if (obj.get("regex")) |value| {
        regex = try expectBool(value);
    }

    const before = try parseOptionalInt(obj, "context_before", 0, 0, 10);
    const after = try parseOptionalInt(obj, "context_after", 0, 0, 10);

    const limit = try parseOptionalInt(obj, "limit", 200, 1, 2000);

    var ast_language: ?[]const u8 = null;
    if (obj.get("ast_language")) |value| {
        if (value != .string) return error.InvalidPayload;
        const trimmed = std.mem.trim(u8, value.string, " \t\r\n");
        if (trimmed.len == 0) return error.InvalidPayload;
        ast_language = try dupSlice(allocator, trimmed);
    }

    return ParsedPayload{
        .pattern = pattern_copy,
        .engine = engine,
        .raw_paths = raw_paths,
        .include_globs = include_globs,
        .exclude_globs = exclude_globs,
        .case_sensitive = case_sensitive,
        .regex = regex,
        .context_before = before,
        .context_after = after,
        .limit = limit,
        .ast_language = ast_language,
    };
}

fn parseStringArray(allocator: std.mem.Allocator, obj: std.json.ObjectMap, field: []const u8) Error![]const []const u8 {
    const value = obj.get(field) orelse return &.{};
    if (value == .null) return &.{};
    if (value != .array) return error.InvalidPayload;
    const items = value.array.items;
    var list = ManagedArrayList([]const u8).init(allocator);
    errdefer list.deinit();
    for (items) |elem| {
        if (elem != .string) return error.InvalidPayload;
        const trimmed = std.mem.trim(u8, elem.string, " \t\r\n");
        if (trimmed.len == 0) return error.InvalidPayload;
        const duped = try dupSlice(allocator, trimmed);
        try list.append(duped);
    }
    const owned = try list.toOwnedSlice();
    return owned;
}

fn parseOptionalInt(
    obj: std.json.ObjectMap,
    field: []const u8,
    default_value: usize,
    min_value: usize,
    max_value: usize,
) Error!usize {
    const value = obj.get(field) orelse return default_value;
    const parsed_raw = switch (value) {
        .integer => |int| int,
        else => return error.InvalidPayload,
    };
    if (parsed_raw < 0) return error.InvalidPayload;
    const parsed: usize = @intCast(parsed_raw);
    if (parsed < min_value) return error.InvalidPayload;
    if (parsed > max_value) return error.InvalidPayload;
    return parsed;
}

fn expectBool(value: std.json.Value) Error!bool {
    return switch (value) {
        .bool => |b| b,
        else => error.InvalidPayload,
    };
}

const ResolvedPath = struct {
    text: []const u8,
    owned: bool,
};

fn acquireSearchRoots(executor: anytype, allocator: std.mem.Allocator, raw_paths: []const []const u8) Error![]ResolvedPath {
    var list = ManagedArrayList(ResolvedPath).init(allocator);
    errdefer {
        for (list.items) |entry| {
            if (entry.owned) executor.allocator.free(entry.text);
        }
        list.deinit();
    }

    if (raw_paths.len == 0) {
        try list.append(.{ .text = executor.sandboxRoot(), .owned = false });
    } else {
        for (raw_paths) |raw| {
            const resolved = executor.resolvePath(raw) catch |err| switch (err) {
                error.PathOutsideSandbox => return error.PathOutsideSandbox,
                error.PathNotFound => return error.PathNotFound,
                error.PermissionDenied => return error.PermissionDenied,
                else => return err,
            };
            try list.append(.{ .text = resolved, .owned = true });
        }
    }

    return list.toOwnedSlice() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
}

fn ripgrepSearch(executor: anytype, cfg: ParsedPayload) Error![]u8 {
    const roots = try acquireSearchRoots(executor, executor.allocator, cfg.raw_paths);
    defer executor.allocator.free(roots);
    defer {
        for (roots) |entry| {
            if (entry.owned) executor.allocator.free(entry.text);
        }
    }

    var args = ManagedArrayList([]const u8).init(executor.allocator);
    defer args.deinit();
    var owned_exclude_globs = ManagedArrayList([]const u8).init(executor.allocator);
    defer {
        for (owned_exclude_globs.items) |glob| {
            executor.allocator.free(glob);
        }
        owned_exclude_globs.deinit();
    }

    try args.appendSlice(&.{
        "rg",
        "--json",
        "--color=never",
        "--line-number",
        "--column",
        "--no-heading",
        "--with-filename",
    });

    if (!cfg.case_sensitive) try args.append("--ignore-case");
    if (!cfg.regex) try args.append("--fixed-strings");

    for (cfg.include_globs) |glob| {
        try args.append("--glob");
        try args.append(glob);
    }
    for (cfg.exclude_globs) |glob| {
        try args.append("--glob");
        const formatted = try std.fmt.allocPrint(executor.allocator, "!{s}", .{glob});
        try owned_exclude_globs.append(formatted);
        try args.append(formatted);
    }

    try args.append("-e");
    try args.append(cfg.pattern);
    try args.append("--");
    for (roots) |entry| {
        try args.append(entry.text);
    }

    const cmd_result = runCommand(executor.allocator, args.items, null) catch |err| switch (err) {
        error.BinaryUnavailable => return error.BinaryUnavailable,
        else => return err,
    };
    defer {
        if (cmd_result.stdout.len != 0) executor.allocator.free(cmd_result.stdout);
        if (cmd_result.stderr.len != 0) executor.allocator.free(cmd_result.stderr);
    }

    if (cmd_result.exit_code >= 2) return error.CommandFailed;

    var records_arena = std.heap.ArenaAllocator.init(executor.allocator);
    defer records_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(executor.allocator);
    defer parse_arena.deinit();

    var matches = ManagedArrayList(MatchRecord).init(records_arena.allocator());

    var truncated = false;
    var iter = std.mem.tokenizeScalar(u8, cmd_result.stdout, '\n');
    parse: while (iter.next()) |line| {
        if (line.len == 0) continue;
        _ = parse_arena.reset(.retain_capacity);
        var json_value = std.json.parseFromSlice(std.json.Value, parse_arena.allocator(), line, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue :parse,
        };
        defer json_value.deinit();
        if (json_value.value != .object) continue;
        const obj = json_value.value.object;
        const type_value = obj.get("type") orelse continue;
        if (type_value != .string) continue;
        if (!std.mem.eql(u8, type_value.string, "match")) continue;
        const data_value = obj.get("data") orelse continue;
        if (data_value != .object) continue;
        const record = data_value.object;
        const path_text = extractNestedString(record, "path", "text") orelse continue;
        const line_text = extractNestedString(record, "lines", "text") orelse continue;
        const line_number_value = record.get("line_number") orelse continue;
        const abs_line = switch (line_number_value) {
            .integer => |v| v,
            else => continue,
        };
        if (abs_line <= 0) continue;
        if (abs_line > std.math.maxInt(usize)) continue;
        const submatches_value = record.get("submatches") orelse continue;
        if (submatches_value != .array) continue;
        if (submatches_value.array.items.len == 0) continue;

        for (submatches_value.array.items) |submatch| {
            if (submatch != .object) continue;
            const start_value = submatch.object.get("start") orelse continue;
            const match_text = extractNestedString(submatch.object, "match", "text") orelse continue;
            const column_index = switch (start_value) {
                .integer => |v| v,
                else => continue,
            };
            if (column_index < 0) continue;
            if (column_index >= std.math.maxInt(usize)) continue;
            const relative_column = column_index + 1;

            const duplicated_path = try dupSlice(records_arena.allocator(), path_text);
            const duplicated_line = try dupSlice(records_arena.allocator(), line_text);
            const duplicated_match = try dupSlice(records_arena.allocator(), match_text);
            try matches.append(.{
                .absolute_path = duplicated_path,
                .line_number = @intCast(abs_line),
                .column_number = @intCast(relative_column),
                .line_text = duplicated_line,
                .match_text = duplicated_match,
            });

            if (matches.items.len >= cfg.limit) {
                truncated = true;
                break;
            }
        }
        if (truncated) break;
    }

    const payload = try encodeRipgrepResults(executor, cfg, matches.items, truncated, cmd_result.stderr);
    matches.deinit();
    return payload;
}

const MatchRecord = struct {
    absolute_path: []const u8,
    line_number: usize,
    column_number: usize,
    line_text: []const u8,
    match_text: []const u8,
};

fn extractNestedString(obj: std.json.ObjectMap, field: []const u8, nested: []const u8) ?[]const u8 {
    const value = obj.get(field) orelse return null;
    if (value != .object) return null;
    const nested_value = value.object.get(nested) orelse return null;
    return switch (nested_value) {
        .string => nested_value.string,
        else => null,
    };
}

fn encodeRipgrepResults(
    executor: anytype,
    cfg: ParsedPayload,
    matches: []const MatchRecord,
    truncated: bool,
    stderr_bytes: []const u8,
) Error![]u8 {
    var sink = std.io.Writer.Allocating.init(executor.allocator);
    errdefer sink.deinit();
    var jw = std.json.Stringify{ .writer = &sink.writer, .options = .{ .whitespace = .minified } };

    try jsonStep(jw.beginObject());
    try jsonStep(jw.objectField("engine"));
    try jsonStep(jw.write("ripgrep"));
    try jsonStep(jw.objectField("results"));
    try jsonStep(jw.beginArray());

    for (matches) |entry| {
        try jsonStep(jw.beginObject());
        try jsonStep(jw.objectField("path"));
        try jsonStep(jw.write(relativePath(executor.sandboxRoot(), entry.absolute_path)));
        try jsonStep(jw.objectField("line"));
        try jsonStep(jw.write(entry.line_number));
        try jsonStep(jw.objectField("column"));
        try jsonStep(jw.write(entry.column_number));
        try jsonStep(jw.objectField("match"));
        try jsonStep(jw.write(entry.match_text));
        try jsonStep(jw.objectField("line_text"));
        try jsonStep(jw.write(trimLine(entry.line_text)));

        const context = try gatherContext(executor.allocator, entry.absolute_path, entry.line_number, cfg.context_before, cfg.context_after);
        defer context.deinit();

        try jsonStep(jw.objectField("context_before"));
        try jsonStep(jw.beginArray());
        for (context.before.items) |line| {
            try jsonStep(jw.write(line));
        }
        try jsonStep(jw.endArray());
        try jsonStep(jw.objectField("context_after"));
        try jsonStep(jw.beginArray());
        for (context.after.items) |line| {
            try jsonStep(jw.write(line));
        }
        try jsonStep(jw.endArray());
        try jsonStep(jw.endObject());
    }

    try jsonStep(jw.endArray());
    try jsonStep(jw.objectField("truncated"));
    try jsonStep(jw.write(truncated));
    try jsonStep(jw.objectField("stats"));
    try jsonStep(jw.beginObject());
    try jsonStep(jw.objectField("matches"));
    try jsonStep(jw.write(matches.len));
    try jsonStep(jw.endObject());

    if (stderr_bytes.len != 0) {
        try jsonStep(jw.objectField("notes"));
        try jsonStep(jw.beginArray());
        const note = trimNote(stderr_bytes);
        try jsonStep(jw.write(note));
        try jsonStep(jw.endArray());
    }

    try jsonStep(jw.endObject());

    return sink.toOwnedSlice();
}

const ContextBuffers = struct {
    before: ManagedArrayList([]const u8),
    after: ManagedArrayList([]const u8),
    arena: std.heap.ArenaAllocator,

    fn deinit(self: ContextBuffers) void {
        self.before.deinit();
        self.after.deinit();
        var owned = self.arena;
        owned.deinit();
    }
};

fn gatherContext(
    allocator: std.mem.Allocator,
    absolute_path: []const u8,
    line_number: usize,
    before_count: usize,
    after_count: usize,
) Error!ContextBuffers {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var before = ManagedArrayList([]const u8).init(arena.allocator());
    var after = ManagedArrayList([]const u8).init(arena.allocator());

    if (before_count == 0 and after_count == 0) {
        return ContextBuffers{ .before = before, .after = after, .arena = arena };
    }

    var file = std.fs.openFileAbsolute(absolute_path, .{ .mode = .read_only }) catch |err| switch (err) {
        error.FileNotFound => return error.PathNotFound,
        error.AccessDenied => return error.PermissionDenied,
        else => return error.IoFailure,
    };
    defer file.close();

    var chunk: [1024]u8 = undefined;
    var partial = ManagedArrayList(u8).init(arena.allocator());
    defer partial.deinit();
    var line_index: usize = 0;
    var done = false;

    while (!done) {
        const bytes_read = file.read(&chunk) catch |err| switch (err) {
            error.AccessDenied => return error.PermissionDenied,
            else => return error.IoFailure,
        };
        if (bytes_read == 0) {
            if (partial.items.len != 0) {
                done = try emitContextLine(
                    partial.items,
                    arena.allocator(),
                    line_number,
                    before_count,
                    after_count,
                    &line_index,
                    &before,
                    &after,
                );
                partial.clearRetainingCapacity();
            }
            break;
        }

        var idx: usize = 0;
        while (idx < bytes_read) : (idx += 1) {
            const byte = chunk[idx];
            try partial.append(byte);
            if (byte == '\n') {
                done = try emitContextLine(
                    partial.items,
                    arena.allocator(),
                    line_number,
                    before_count,
                    after_count,
                    &line_index,
                    &before,
                    &after,
                );
                partial.clearRetainingCapacity();
                if (done) break;
            }
        }
    }

    return ContextBuffers{ .before = before, .after = after, .arena = arena };
}

fn emitContextLine(
    buffer: []const u8,
    allocator: std.mem.Allocator,
    target_line: usize,
    before_count: usize,
    after_count: usize,
    current_index: *usize,
    before: *ManagedArrayList([]const u8),
    after: *ManagedArrayList([]const u8),
) !bool {
    const trimmed = trimLine(buffer);
    const copy = try dupSlice(allocator, trimmed);

    current_index.* += 1;
    if (current_index.* < target_line) {
        try pushSliding(before, copy, before_count);
        return false;
    }

    if (current_index.* == target_line) {
        return false;
    }

    if (after_count == 0) return current_index.* >= target_line;

    if (current_index.* <= target_line + after_count) {
        try after.append(copy);
        return current_index.* == target_line + after_count;
    }

    return true;
}

fn pushSliding(list: *ManagedArrayList([]const u8), line: []const u8, limit: usize) !void {
    if (limit == 0) return;
    if (list.items.len < limit) {
        try list.append(line);
        return;
    }
    std.mem.copyForwards([]const u8, list.items[0 .. limit - 1], list.items[1..limit]);
    list.items[limit - 1] = line;
}

fn trimLine(line: []const u8) []const u8 {
    return std.mem.trimRight(u8, line, "\r\n");
}

fn relativePath(root: []const u8, candidate: []const u8) []const u8 {
    if (candidate.len >= root.len and std.mem.startsWith(u8, candidate, root)) {
        if (candidate.len == root.len) return ".";
        if (candidate[root.len] == std.fs.path.sep) {
            return candidate[root.len + 1 ..];
        }
    }
    return candidate;
}

const CommandOutput = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,
};

fn runCommand(allocator: std.mem.Allocator, args: []const []const u8, cwd: ?[]const u8) Error!CommandOutput {
    const run_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = args,
        .cwd = cwd,
        .max_output_bytes = max_command_output,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StdoutStreamTooLong, error.StderrStreamTooLong => return error.ToolLimitExceeded,
        error.FileNotFound => return error.BinaryUnavailable,
        error.AccessDenied => return error.PermissionDenied,
        else => return error.CommandFailed,
    };

    const code: u8 = switch (run_result.term) {
        .Exited => |status| status,
        else => return error.CommandFailed,
    };

    return CommandOutput{
        .stdout = run_result.stdout,
        .stderr = run_result.stderr,
        .exit_code = code,
    };
}

fn trimNote(data: []const u8) []const u8 {
    if (data.len <= max_stderr_note) return std.mem.trim(u8, data, " \r\n\t");
    const slice = data[0..max_stderr_note];
    return std.mem.trim(u8, slice, " \r\n\t");
}

fn astGrepSearch(executor: anytype, cfg: ParsedPayload) Error![]u8 {
    const roots = try acquireSearchRoots(executor, executor.allocator, cfg.raw_paths);
    defer executor.allocator.free(roots);
    defer {
        for (roots) |entry| {
            if (entry.owned) executor.allocator.free(entry.text);
        }
    }

    var args = ManagedArrayList([]const u8).init(executor.allocator);
    defer args.deinit();
    var owned_exclude_globs = ManagedArrayList([]const u8).init(executor.allocator);
    defer {
        for (owned_exclude_globs.items) |glob| {
            executor.allocator.free(glob);
        }
        owned_exclude_globs.deinit();
    }

    try args.appendSlice(&.{ "sg", "run", "--json=stream", "-p", cfg.pattern });

    if (cfg.ast_language) |lang| {
        try args.append("--lang");
        try args.append(lang);
    }

    for (cfg.include_globs) |glob| {
        try args.append("--globs");
        try args.append(glob);
    }
    for (cfg.exclude_globs) |glob| {
        try args.append("--globs");
        const formatted = try std.fmt.allocPrint(executor.allocator, "!{s}", .{glob});
        try owned_exclude_globs.append(formatted);
        try args.append(formatted);
    }

    for (roots) |entry| {
        try args.append(entry.text);
    }

    const cmd_result = runCommand(executor.allocator, args.items, null) catch |err| switch (err) {
        error.BinaryUnavailable => blk: {
            args.items[0] = "ast-grep";
            break :blk try runCommand(executor.allocator, args.items, null);
        },
        else => return err,
    };
    defer {
        if (cmd_result.stdout.len != 0) executor.allocator.free(cmd_result.stdout);
        if (cmd_result.stderr.len != 0) executor.allocator.free(cmd_result.stderr);
    }

    if (cmd_result.exit_code >= 2) return error.CommandFailed;

    var records_arena = std.heap.ArenaAllocator.init(executor.allocator);
    defer records_arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(executor.allocator);
    defer parse_arena.deinit();

    var matches = ManagedArrayList(AstMatchRecord).init(records_arena.allocator());
    var truncated = false;

    var iter = std.mem.tokenizeScalar(u8, cmd_result.stdout, '\n');
    parse_loop: while (iter.next()) |line| {
        if (line.len == 0) continue;
        _ = parse_arena.reset(.retain_capacity);
        var parsed = std.json.parseFromSlice(std.json.Value, parse_arena.allocator(), line, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue :parse_loop,
        };
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const obj = parsed.value.object;
        const file_value = obj.get("file") orelse continue;
        if (file_value != .string) continue;
        const range_value = obj.get("range") orelse continue;
        if (range_value != .object) continue;
        const start_value = range_value.object.get("start") orelse continue;
        if (start_value != .object) continue;
        const line_field = start_value.object.get("line") orelse continue;
        const column_field = start_value.object.get("column") orelse continue;
        const match_text_value = obj.get("text") orelse continue;
        if (match_text_value != .string) continue;
        const lines_value = obj.get("lines") orelse match_text_value;
        if (lines_value != .string) continue;
        const line_number = switch (line_field) {
            .integer => |v| v,
            else => continue,
        };
        const column_number = switch (column_field) {
            .integer => |v| v,
            else => continue,
        };
        if (line_number < 0) continue;
        if (column_number < 0) continue;
        if (line_number >= std.math.maxInt(usize)) continue;
        if (column_number >= std.math.maxInt(usize)) continue;

        const dup_path = try dupSlice(records_arena.allocator(), file_value.string);
        const dup_line = try dupSlice(records_arena.allocator(), lines_value.string);
        const dup_match = try dupSlice(records_arena.allocator(), match_text_value.string);

        var replacement: ?[]const u8 = null;
        if (obj.get("replacement")) |value| {
            if (value == .string) {
                const dup = try dupSlice(records_arena.allocator(), value.string);
                replacement = dup;
            }
        }

        try matches.append(.{
            .absolute_path = dup_path,
            .line_number = @intCast(line_number + 1),
            .column_number = @intCast(column_number + 1),
            .snippet = dup_line,
            .match_text = dup_match,
            .replacement = replacement,
        });

        if (matches.items.len >= cfg.limit) {
            truncated = true;
            break;
        }
    }

    const payload = try encodeAstGrepResults(executor, cfg, matches.items, truncated, cmd_result.stderr);
    matches.deinit();
    return payload;
}

const AstMatchRecord = struct {
    absolute_path: []const u8,
    line_number: usize,
    column_number: usize,
    snippet: []const u8,
    match_text: []const u8,
    replacement: ?[]const u8,
};

fn encodeAstGrepResults(
    executor: anytype,
    cfg: ParsedPayload,
    matches: []const AstMatchRecord,
    truncated: bool,
    stderr_bytes: []const u8,
) Error![]u8 {
    var sink = std.io.Writer.Allocating.init(executor.allocator);
    errdefer sink.deinit();
    var jw = std.json.Stringify{ .writer = &sink.writer, .options = .{ .whitespace = .minified } };

    try jsonStep(jw.beginObject());
    try jsonStep(jw.objectField("engine"));
    try jsonStep(jw.write("ast-grep"));
    try jsonStep(jw.objectField("results"));
    try jsonStep(jw.beginArray());

    for (matches) |entry| {
        try jsonStep(jw.beginObject());
        try jsonStep(jw.objectField("path"));
        try jsonStep(jw.write(relativePath(executor.sandboxRoot(), entry.absolute_path)));
        try jsonStep(jw.objectField("line"));
        try jsonStep(jw.write(entry.line_number));
        try jsonStep(jw.objectField("column"));
        try jsonStep(jw.write(entry.column_number));
        try jsonStep(jw.objectField("match"));
        try jsonStep(jw.write(entry.match_text));
        try jsonStep(jw.objectField("snippet"));
        try jsonStep(jw.write(entry.snippet));

        const context = try gatherContext(executor.allocator, entry.absolute_path, entry.line_number, cfg.context_before, cfg.context_after);
        defer context.deinit();

        try jsonStep(jw.objectField("context_before"));
        try jsonStep(jw.beginArray());
        for (context.before.items) |line| {
            try jsonStep(jw.write(line));
        }
        try jsonStep(jw.endArray());
        try jsonStep(jw.objectField("context_after"));
        try jsonStep(jw.beginArray());
        for (context.after.items) |line| {
            try jsonStep(jw.write(line));
        }
        try jsonStep(jw.endArray());

        if (entry.replacement) |replacement| {
            try jsonStep(jw.objectField("replacement_preview"));
            try jsonStep(jw.write(replacement));
        }

        try jsonStep(jw.endObject());
    }

    try jsonStep(jw.endArray());
    try jsonStep(jw.objectField("truncated"));
    try jsonStep(jw.write(truncated));
    try jsonStep(jw.objectField("stats"));
    try jsonStep(jw.beginObject());
    try jsonStep(jw.objectField("matches"));
    try jsonStep(jw.write(matches.len));
    try jsonStep(jw.endObject());

    if (stderr_bytes.len != 0) {
        try jsonStep(jw.objectField("notes"));
        try jsonStep(jw.beginArray());
        const note = trimNote(stderr_bytes);
        try jsonStep(jw.write(note));
        try jsonStep(jw.endArray());
    }

    try jsonStep(jw.endObject());

    return sink.toOwnedSlice();
}

fn dupSlice(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
    const copy = try allocator.alloc(u8, data.len);
    if (data.len != 0) @memcpy(copy, data);
    return copy;
}

inline fn jsonStep(res: std.json.Stringify.Error!void) Error!void {
    return res catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };
}
