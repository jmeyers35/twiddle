const std = @import("std");
const ManagedArrayList = std.array_list.Managed;

const max_file_bytes = 8 * 1024 * 1024;

pub const Error = std.mem.Allocator.Error || error{
    InvalidPayload,
    InvalidPatch,
    PathOutsideSandbox,
    AbsolutePathForbidden,
    IoFailure,
    PatchConflict,
};

pub fn run(executor: anytype, payload: []const u8) Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(executor.allocator);
    defer arena.deinit();

    const parsed = try parsePayload(arena.allocator(), executor, payload);
    const operations = try parsePatch(arena.allocator(), parsed.patch_text);
    const summary = try applyOperations(arena.allocator(), executor, parsed.base_dir, operations);
    return try encodeResult(executor.allocator, summary);
}

const ParsedPayload = struct {
    patch_text: []const u8,
    base_dir: []const u8,
};

fn parsePayload(
    allocator: std.mem.Allocator,
    executor: anytype,
    payload: []const u8,
) Error!ParsedPayload {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidPayload,
    };
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidPayload;
    const obj = parsed.value.object;

    const input_value = obj.get("input") orelse return error.InvalidPayload;
    if (input_value != .string) return error.InvalidPayload;
    const trimmed = std.mem.trim(u8, input_value.string, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidPayload;
    const patch_copy = try allocator.dupe(u8, trimmed);

    var base_dir = executor.sandboxRoot();
    if (obj.get("workdir")) |workdir_val| {
        if (workdir_val == .null) {
            // no-op
        } else if (workdir_val == .string) {
            const normalized = std.mem.trim(u8, workdir_val.string, " \t\r\n");
            if (normalized.len != 0) {
                base_dir = try resolveBaseDir(allocator, executor.sandboxRoot(), normalized);
            }
        } else {
            return error.InvalidPayload;
        }
    }

    return ParsedPayload{
        .patch_text = patch_copy,
        .base_dir = base_dir,
    };
}

fn resolveBaseDir(
    allocator: std.mem.Allocator,
    sandbox_root: []const u8,
    workdir: []const u8,
) Error![]const u8 {
    const resolved = if (std.fs.path.isAbsolute(workdir))
        try std.fs.path.resolve(allocator, &.{workdir})
    else
        try std.fs.path.resolve(allocator, &.{ sandbox_root, workdir });
    if (!pathWithinSandbox(sandbox_root, resolved)) return error.PathOutsideSandbox;
    return resolved;
}

const Operation = union(enum) {
    add_file: struct {
        rel_path: []const u8,
        contents: []const u8,
    },
    delete_file: struct {
        rel_path: []const u8,
    },
    update_file: struct {
        rel_path: []const u8,
        move_path: ?[]const u8,
        chunks: []const UpdateChunk,
    },
};

const UpdateChunk = struct {
    change_context: ?[]const u8,
    old_lines: []const []const u8,
    new_lines: []const []const u8,
    is_end_of_file: bool,
};

fn parsePatch(allocator: std.mem.Allocator, patch_text: []const u8) Error![]const Operation {
    var lines = ManagedArrayList([]const u8).init(allocator);
    errdefer lines.deinit();
    var iter = std.mem.splitScalar(u8, patch_text, '\n');
    while (iter.next()) |line| {
        const without_cr = if (line.len != 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
        try lines.append(without_cr);
    }

    if (lines.items.len < 2) return error.InvalidPatch;
    if (!std.mem.eql(u8, lines.items[0], "*** Begin Patch")) return error.InvalidPatch;
    if (!std.mem.eql(u8, lines.items[lines.items.len - 1], "*** End Patch")) return error.InvalidPatch;

    var ops = ManagedArrayList(Operation).init(allocator);
    errdefer ops.deinit();

    var idx: usize = 1;
    const last_hunk_line = lines.items.len - 1;

    while (idx < last_hunk_line) {
        const raw_line = lines.items[idx];
        if (raw_line.len == 0) {
            idx += 1;
            continue;
        }

        if (std.mem.startsWith(u8, raw_line, "*** Add File: ")) {
            const rel_path = std.mem.trim(u8, raw_line["*** Add File: ".len..], " \t");
            if (rel_path.len == 0) return error.InvalidPatch;
            const add_result = try parseAddFile(allocator, lines.items, idx + 1);
            try ops.append(.{ .add_file = .{ .rel_path = rel_path, .contents = add_result.contents } });
            idx = add_result.next_index;
            continue;
        }

        if (std.mem.startsWith(u8, raw_line, "*** Delete File: ")) {
            const rel_path = std.mem.trim(u8, raw_line["*** Delete File: ".len..], " \t");
            if (rel_path.len == 0) return error.InvalidPatch;
            try ops.append(.{ .delete_file = .{ .rel_path = rel_path } });
            idx += 1;
            continue;
        }

        if (std.mem.startsWith(u8, raw_line, "*** Update File: ")) {
            const rel_path = std.mem.trim(u8, raw_line["*** Update File: ".len..], " \t");
            if (rel_path.len == 0) return error.InvalidPatch;
            const update_result = try parseUpdateFile(allocator, lines.items, idx + 1);
            try ops.append(.{
                .update_file = .{
                    .rel_path = rel_path,
                    .move_path = update_result.move_path,
                    .chunks = update_result.chunks,
                },
            });
            idx = update_result.next_index;
            continue;
        }

        return error.InvalidPatch;
    }

    return ops.toOwnedSlice() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
}

const AddFileParseResult = struct {
    contents: []const u8,
    next_index: usize,
};

fn parseAddFile(
    allocator: std.mem.Allocator,
    lines: []const []const u8,
    start_index: usize,
) Error!AddFileParseResult {
    var builder = ManagedArrayList(u8).init(allocator);
    errdefer builder.deinit();

    var idx = start_index;
    var saw_content = false;

    while (idx < lines.len) {
        const line = lines[idx];
        if (line.len == 0) break;
        if (std.mem.startsWith(u8, line, "***")) break;
        if (line[0] != '+') break;
        try builder.appendSlice(line[1..]);
        try builder.append('\n');
        saw_content = true;
        idx += 1;
    }

    if (!saw_content) return error.InvalidPatch;
    const contents = try builder.toOwnedSlice();
    return AddFileParseResult{
        .contents = contents,
        .next_index = idx,
    };
}

const UpdateFileParseResult = struct {
    move_path: ?[]const u8,
    chunks: []const UpdateChunk,
    next_index: usize,
};

fn parseUpdateFile(
    allocator: std.mem.Allocator,
    lines: []const []const u8,
    start_index: usize,
) Error!UpdateFileParseResult {
    var idx = start_index;
    var move_path: ?[]const u8 = null;
    if (idx < lines.len and std.mem.startsWith(u8, lines[idx], "*** Move to: ")) {
        const path = std.mem.trim(u8, lines[idx]["*** Move to: ".len..], " \t");
        if (path.len == 0) return error.InvalidPatch;
        move_path = path;
        idx += 1;
    }

    var chunks = ManagedArrayList(UpdateChunk).init(allocator);
    errdefer chunks.deinit();
    var first_chunk = true;

    while (idx < lines.len) {
        const line = lines[idx];
        if (line.len == 0) {
            idx += 1;
            continue;
        }
        if (std.mem.startsWith(u8, line, "***")) break;
        if (!std.mem.startsWith(u8, line, "@@") and !first_chunk) {
            // treat missing @@ between chunks as end of this update block
            break;
        }
        const parsed_chunk = try parseChunk(allocator, lines, idx, first_chunk);
        try chunks.append(parsed_chunk.chunk);
        idx = parsed_chunk.next_index;
        first_chunk = false;
    }

    if (chunks.items.len == 0) return error.InvalidPatch;

    return UpdateFileParseResult{
        .move_path = move_path,
        .chunks = try chunks.toOwnedSlice(),
        .next_index = idx,
    };
}

const ChunkParseResult = struct {
    chunk: UpdateChunk,
    next_index: usize,
};

fn parseChunk(
    allocator: std.mem.Allocator,
    lines: []const []const u8,
    start_index: usize,
    allow_missing_context: bool,
) Error!ChunkParseResult {
    var idx = start_index;
    const header = lines[idx];
    var change_context: ?[]const u8 = null;
    if (std.mem.eql(u8, header, "@@")) {
        idx += 1;
    } else if (std.mem.startsWith(u8, header, "@@")) {
        if (header.len > 2) {
            const remainder = header[2..];
            const second_idx = std.mem.indexOf(u8, remainder, "@@");
            if (second_idx) |pos| {
                const after_second = remainder[pos + 2 ..];
                const trimmed = std.mem.trim(u8, after_second, " \t");
                if (trimmed.len != 0) {
                    change_context = trimmed;
                }
            } else {
                const trimmed = std.mem.trim(u8, remainder, " \t");
                if (trimmed.len != 0) {
                    change_context = trimmed;
                }
            }
        }
        idx += 1;
    } else if (!allow_missing_context) {
        return error.InvalidPatch;
    }

    var old_lines = ManagedArrayList([]const u8).init(allocator);
    errdefer old_lines.deinit();
    var new_lines = ManagedArrayList([]const u8).init(allocator);
    errdefer new_lines.deinit();

    var is_end_of_file = false;

    while (idx < lines.len) {
        const line = lines[idx];
        if (line.len == 0) break;
        if (std.mem.eql(u8, line, "*** End of File")) {
            is_end_of_file = true;
            idx += 1;
            break;
        }
        if (std.mem.startsWith(u8, line, "***")) break;
        if (std.mem.startsWith(u8, line, "@@")) break; // next chunk

        const head = line[0];
        const tail = if (line.len > 1) line[1..] else &[_]u8{};

        switch (head) {
            ' ' => {
                try old_lines.append(tail);
                try new_lines.append(tail);
            },
            '+' => {
                try new_lines.append(tail);
            },
            '-' => {
                try old_lines.append(tail);
            },
            else => return error.InvalidPatch,
        }

        idx += 1;
    }

    if (old_lines.items.len == 0 and new_lines.items.len == 0) return error.InvalidPatch;

    return ChunkParseResult{
        .chunk = .{
            .change_context = change_context,
            .old_lines = try old_lines.toOwnedSlice(),
            .new_lines = try new_lines.toOwnedSlice(),
            .is_end_of_file = is_end_of_file,
        },
        .next_index = idx,
    };
}

const ChangeKind = enum { add, delete, update };

const ChangeSummary = struct {
    rel_path: []const u8,
    kind: ChangeKind,
    move_path: ?[]const u8 = null,
    workspace_path: []const u8,
};

const ApplySummary = struct {
    changes: []const ChangeSummary,
};

fn applyOperations(
    allocator: std.mem.Allocator,
    executor: anytype,
    base_dir: []const u8,
    operations: []const Operation,
) Error!ApplySummary {
    var changes = ManagedArrayList(ChangeSummary).init(allocator);
    errdefer changes.deinit();

    for (operations) |op| switch (op) {
        .add_file => |add| {
            const abs_path = try resolveFilePath(allocator, executor.sandboxRoot(), base_dir, add.rel_path);
            const exists = blk: {
                std.fs.accessAbsolute(abs_path, .{}) catch |err| switch (err) {
                    error.FileNotFound => break :blk false,
                    else => return error.IoFailure,
                };
                break :blk true;
            };
            if (exists) return error.PatchConflict;
            try ensureParentDirs(abs_path);
            var file = std.fs.createFileAbsolute(abs_path, .{ .truncate = true }) catch return error.IoFailure;
            defer file.close();
            file.writeAll(add.contents) catch return error.IoFailure;
            const workspace_path = try relativeToRoot(allocator, executor.sandboxRoot(), abs_path);
            try changes.append(.{ .rel_path = add.rel_path, .kind = .add, .workspace_path = workspace_path });
        },
        .delete_file => |del| {
            const abs_path = try resolveFilePath(allocator, executor.sandboxRoot(), base_dir, del.rel_path);
            std.fs.deleteFileAbsolute(abs_path) catch |err| switch (err) {
                error.FileNotFound => return error.PatchConflict,
                else => return error.IoFailure,
            };
            const workspace_path = try relativeToRoot(allocator, executor.sandboxRoot(), abs_path);
            try changes.append(.{ .rel_path = del.rel_path, .kind = .delete, .workspace_path = workspace_path });
        },
        .update_file => |upd| {
            const src_abs = try resolveFilePath(allocator, executor.sandboxRoot(), base_dir, upd.rel_path);
            const dest_abs = blk: {
                if (upd.move_path) |move_path| {
                    break :blk try resolveFilePath(allocator, executor.sandboxRoot(), base_dir, move_path);
                } else break :blk src_abs;
            };
            const new_contents = try deriveNewContents(allocator, src_abs, upd.chunks);
            try ensureParentDirs(dest_abs);
            var file = std.fs.createFileAbsolute(dest_abs, .{ .truncate = true }) catch return error.IoFailure;
            defer file.close();
            file.writeAll(new_contents) catch return error.IoFailure;
            const workspace_path = try relativeToRoot(allocator, executor.sandboxRoot(), dest_abs);
            if (upd.move_path) |move_path| {
                if (!std.mem.eql(u8, src_abs, dest_abs)) {
                    std.fs.deleteFileAbsolute(src_abs) catch |err| switch (err) {
                        error.FileNotFound => return error.PatchConflict,
                        else => return error.IoFailure,
                    };
                }
                try changes.append(.{ .rel_path = upd.rel_path, .kind = .update, .move_path = move_path, .workspace_path = workspace_path });
            } else {
                try changes.append(.{ .rel_path = upd.rel_path, .kind = .update, .workspace_path = workspace_path });
            }
        },
    };

    return ApplySummary{
        .changes = try changes.toOwnedSlice(),
    };
}

fn resolveFilePath(
    allocator: std.mem.Allocator,
    sandbox_root: []const u8,
    base_dir: []const u8,
    rel_path: []const u8,
) Error![]const u8 {
    if (rel_path.len == 0) return error.InvalidPatch;
    if (std.fs.path.isAbsolute(rel_path)) return error.AbsolutePathForbidden;
    const resolved = try std.fs.path.resolve(allocator, &.{ base_dir, rel_path });
    if (!pathWithinSandbox(sandbox_root, resolved)) return error.PathOutsideSandbox;
    return resolved;
}

fn ensureParentDirs(abs_path: []const u8) Error!void {
    if (std.fs.path.dirname(abs_path)) |dir_path| {
        if (dir_path.len != 0) {
            try makePathRecursive(dir_path);
        }
    }
}

fn makePathRecursive(path: []const u8) Error!void {
    std.fs.makeDirAbsolute(path) catch |err| switch (err) {
        error.PathAlreadyExists => return,
        error.FileNotFound => {
            if (std.fs.path.dirname(path)) |parent| {
                if (parent.len == 0) return error.IoFailure;
                try makePathRecursive(parent);
                std.fs.makeDirAbsolute(path) catch return error.IoFailure;
            } else {
                return error.IoFailure;
            }
        },
        else => return error.IoFailure,
    };
}

fn deriveNewContents(
    allocator: std.mem.Allocator,
    src_abs: []const u8,
    chunks: []const UpdateChunk,
) Error![]const u8 {
    var file = std.fs.openFileAbsolute(src_abs, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.PatchConflict,
        else => return error.IoFailure,
    };
    defer file.close();
    const original = file.readToEndAlloc(allocator, max_file_bytes) catch return error.IoFailure;
    defer allocator.free(original);
    var lines = try splitLines(allocator, original);
    defer lines.deinit();
    const replacements = try computeReplacements(allocator, lines.items, chunks);
    const updated = try applyReplacements(allocator, lines.items, replacements);
    return updated;
}

fn splitLines(allocator: std.mem.Allocator, data: []const u8) Error!ManagedArrayList([]const u8) {
    var list = ManagedArrayList([]const u8).init(allocator);
    errdefer list.deinit();
    var iterator = std.mem.splitScalar(u8, data, '\n');
    var had_trailing_newline = false;
    while (iterator.next()) |line| {
        const trimmed = if (line.len != 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
        try list.append(trimmed);
    }
    if (data.len != 0 and data[data.len - 1] == '\n') {
        had_trailing_newline = true;
    }
    if (had_trailing_newline) try list.append(&.{});
    return list;
}

const Replacement = struct {
    start: usize,
    remove_len: usize,
    insert_lines: []const []const u8,
};

fn computeReplacements(
    allocator: std.mem.Allocator,
    lines: []const []const u8,
    chunks: []const UpdateChunk,
) Error![]const Replacement {
    var replacements = ManagedArrayList(Replacement).init(allocator);
    errdefer replacements.deinit();
    var cursor: usize = 0;

    for (chunks) |chunk| {
        if (chunk.change_context) |ctx| {
            if (seekSequence(lines, &.{ctx}, cursor, chunk.is_end_of_file)) |idx| {
                cursor = idx + 1;
            } else {
                return error.PatchConflict;
            }
        }

        if (chunk.old_lines.len == 0) {
            const insertion = @min(cursor, lines.len);
            try replacements.append(.{
                .start = insertion,
                .remove_len = 0,
                .insert_lines = chunk.new_lines,
            });
            continue;
        }

        if (seekSequence(lines, chunk.old_lines, cursor, chunk.is_end_of_file)) |match_idx| {
            try replacements.append(.{
                .start = match_idx,
                .remove_len = chunk.old_lines.len,
                .insert_lines = chunk.new_lines,
            });
            cursor = match_idx + chunk.old_lines.len;
        } else {
            return error.PatchConflict;
        }
    }

    return replacements.toOwnedSlice() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
}

fn applyReplacements(
    allocator: std.mem.Allocator,
    lines: []const []const u8,
    replacements: []const Replacement,
) Error![]const u8 {
    const sorted = try allocator.dupe(Replacement, replacements);
    defer allocator.free(sorted);
    std.sort.insertion(Replacement, sorted, {}, struct {
        fn less(_: void, a: Replacement, b: Replacement) bool {
            return a.start < b.start;
        }
    }.less);

    var merged = ManagedArrayList([]const u8).init(allocator);
    defer merged.deinit();
    var cursor: usize = 0;
    for (sorted) |replacement| {
        if (replacement.start < cursor) return error.PatchConflict;
        if (replacement.start > lines.len) return error.PatchConflict;
        try merged.appendSlice(lines[cursor..replacement.start]);
        try merged.appendSlice(replacement.insert_lines);
        cursor = replacement.start + replacement.remove_len;
    }
    if (cursor <= lines.len) {
        try merged.appendSlice(lines[cursor..]);
    }

    var builder = ManagedArrayList(u8).init(allocator);
    defer builder.deinit();
    const has_trailing_newline = merged.items.len != 0 and merged.items[merged.items.len - 1].len == 0;
    const content = if (has_trailing_newline) merged.items[0 .. merged.items.len - 1] else merged.items;
    for (content, 0..) |line, idx| {
        try builder.appendSlice(line);
        if (idx + 1 != content.len) try builder.append('\n');
    }
    if (has_trailing_newline) {
        try builder.append('\n');
    }
    return try builder.toOwnedSlice();
}

fn seekSequence(
    lines: []const []const u8,
    pattern: []const []const u8,
    start_index: usize,
    eof: bool,
) ?usize {
    if (pattern.len == 0) return start_index;
    if (pattern.len > lines.len) return null;
    var candidate_starts = [_]usize{ start_index, start_index };
    var candidate_len: usize = 1;
    if (eof and lines.len >= pattern.len) {
        const eof_start = lines.len - pattern.len;
        candidate_starts[0] = eof_start;
        if (eof_start != start_index) {
            candidate_starts[1] = start_index;
            candidate_len = 2;
        } else {
            candidate_len = 1;
        }
    }

    for (candidate_starts[0..candidate_len]) |initial| {
        var passes: usize = 0;
        while (passes < 3) : (passes += 1) {
            var i = initial;
            while (i + pattern.len <= lines.len) : (i += 1) {
                var matched = true;
                var p_idx: usize = 0;
                while (p_idx < pattern.len) : (p_idx += 1) {
                    const target = lines[i + p_idx];
                    const probe = switch (passes) {
                        0 => target,
                        1 => std.mem.trimRight(u8, target, " \t"),
                        else => std.mem.trim(u8, target, " \t"),
                    };
                    const source = switch (passes) {
                        0 => pattern[p_idx],
                        1 => std.mem.trimRight(u8, pattern[p_idx], " \t"),
                        else => std.mem.trim(u8, pattern[p_idx], " \t"),
                    };
                    if (!std.mem.eql(u8, probe, source)) {
                        matched = false;
                        break;
                    }
                }
                if (matched) return i;
            }
        }
    }
    return null;
}

fn encodeResult(allocator: std.mem.Allocator, summary: ApplySummary) Error![]u8 {
    var sink = std.io.Writer.Allocating.init(allocator);
    errdefer sink.deinit();
    var jw = std.json.Stringify{
        .writer = &sink.writer,
        .options = .{ .whitespace = .minified },
    };

    try jsonStep(jw.beginObject());
    try jsonStep(jw.objectField("status"));
    try jsonStep(jw.write("success"));
    try jsonStep(jw.objectField("files_changed"));
    try jsonStep(jw.write(summary.changes.len));
    try jsonStep(jw.objectField("changes"));
    try jsonStep(jw.beginArray());
    for (summary.changes) |change| {
        try jsonStep(jw.beginObject());
        try jsonStep(jw.objectField("path"));
        try jsonStep(jw.write(change.rel_path));
        try jsonStep(jw.objectField("workspace_path"));
        try jsonStep(jw.write(change.workspace_path));
        try jsonStep(jw.objectField("kind"));
        const kind_str = switch (change.kind) {
            .add => "add",
            .delete => "delete",
            .update => "update",
        };
        try jsonStep(jw.write(kind_str));
        if (change.move_path) |move_path| {
            try jsonStep(jw.objectField("move_to"));
            try jsonStep(jw.write(move_path));
        }
        try jsonStep(jw.endObject());
    }
    try jsonStep(jw.endArray());
    try jsonStep(jw.endObject());

    return sink.toOwnedSlice();
}

inline fn jsonStep(res: std.json.Stringify.Error!void) Error!void {
    return res catch |err| switch (err) {
        else => error.OutOfMemory,
    };
}

fn pathWithinSandbox(root: []const u8, candidate: []const u8) bool {
    if (!std.mem.startsWith(u8, candidate, root)) return false;
    if (candidate.len == root.len) return true;
    const sep = candidate[root.len];
    return sep == std.fs.path.sep;
}

test "apply_patch parser rejects missing markers" {
    const allocator = std.testing.allocator;
    const patch =
        \\*** Begin Patch
        \\*** End Patch
    ;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const lines = parsePatch(arena.allocator(), patch) catch |err| {
        try std.testing.expectEqual(err, error.InvalidPatch);
        return;
    };
    std.debug.print("unexpected {any}\n", .{lines.len});
    try std.testing.expect(false);
}
fn relativeToRoot(allocator: std.mem.Allocator, root: []const u8, abs: []const u8) Error![]const u8 {
    if (!pathWithinSandbox(root, abs)) return error.PathOutsideSandbox;
    var start: usize = root.len;
    if (start < abs.len and abs[start] == std.fs.path.sep) start += 1;
    const rel = abs[start..];
    return allocator.dupe(u8, rel);
}
