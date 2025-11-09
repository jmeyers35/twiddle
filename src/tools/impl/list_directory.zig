const std = @import("std");
const Tools = @import("../../tools.zig");

pub const Error = std.mem.Allocator.Error || error{
    InvalidPayload,
    PathOutsideSandbox,
    PathNotDirectory,
    PathNotFound,
    NoEntriesRequested,
    PermissionDenied,
    IoFailure,
};

pub fn run(executor: anytype, payload: []const u8) Error![]u8 {
    return listDirectory(executor, payload);
}

fn listDirectory(executor: anytype, payload: []const u8) Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(executor.allocator);
    defer arena.deinit();

    var parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), payload, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidPayload,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidPayload;
    const obj = parsed.value.object;

    const path_value = obj.get("path") orelse return error.InvalidPayload;
    if (path_value != .string) return error.InvalidPayload;
    const trimmed_path = std.mem.trim(u8, path_value.string, " \t\r\n");
    if (trimmed_path.len == 0) return error.InvalidPayload;

    var include_hidden = false;
    if (obj.get("include_hidden")) |value| include_hidden = try expectBool(value);

    var include_files = true;
    if (obj.get("include_files")) |value| include_files = try expectBool(value);

    var include_directories = true;
    if (obj.get("include_directories")) |value| include_directories = try expectBool(value);

    if (!include_files and !include_directories) return error.NoEntriesRequested;

    const limits = Tools.ListDirectory.Limits{};
    var max_entries: u16 = limits.default_max_entries;
    if (obj.get("max_entries")) |value| {
        const requested = try expectPositiveInt(value);
        if (requested > limits.hard_max_entries) return error.InvalidPayload;
        max_entries = @intCast(requested);
    }

    const resolved_path = try executor.resolvePath(trimmed_path);
    defer executor.allocator.free(resolved_path);

    var dir = std.fs.openDirAbsolute(resolved_path, .{
        .iterate = true,
    }) catch |err| switch (err) {
        error.NotDir => return error.PathNotDirectory,
        error.FileNotFound => return error.PathNotFound,
        error.AccessDenied => return error.PermissionDenied,
        else => return error.IoFailure,
    };
    defer dir.close();

    var iterator = dir.iterate();
    var sink = std.io.Writer.Allocating.init(executor.allocator);
    errdefer sink.deinit();
    var jw = std.json.Stringify{
        .writer = &sink.writer,
        .options = .{ .whitespace = .minified },
    };

    try jsonWriteStep(jw.beginObject());
    try jsonWriteStep(jw.objectField("entries"));
    try jsonWriteStep(jw.beginArray());

    var emitted: u16 = 0;
    var truncated = false;
    while (true) {
        const maybe_entry = iterator.next() catch |err| switch (err) {
            error.AccessDenied => return error.PermissionDenied,
            else => return error.IoFailure,
        };
        if (maybe_entry == null) break;
        const entry = maybe_entry.?;
        if (!include_hidden and entry.name.len != 0 and entry.name[0] == '.') continue;
        const normalized_kind: Tools.ListDirectory.EntryKind = switch (entry.kind) {
            .directory => blk: {
                if (!include_directories) continue;
                break :blk .directory;
            },
            .file => blk: {
                if (!include_files) continue;
                break :blk .file;
            },
            else => continue,
        };

        if (emitted >= max_entries) {
            truncated = true;
            break;
        }

        const stat = dir.statFile(entry.name) catch |err| switch (err) {
            error.FileNotFound => continue,
            error.AccessDenied => return error.PermissionDenied,
            else => return error.IoFailure,
        };

        try jsonWriteStep(jw.beginObject());
        try jsonWriteStep(jw.objectField("name"));
        try jsonWriteStep(jw.write(entry.name));
        try jsonWriteStep(jw.objectField("kind"));
        try jsonWriteStep(jw.write(entryKindLabel(normalized_kind)));
        try jsonWriteStep(jw.objectField("size_bytes"));
        if (normalized_kind == .file) {
            try jsonWriteStep(jw.write(stat.size));
        } else {
            try jsonWriteStep(jw.write(null));
        }
        try jsonWriteStep(jw.objectField("modified_unix_ns"));
        try jsonWriteStep(jw.write(stat.mtime));
        try jsonWriteStep(jw.endObject());
        emitted += 1;
    }

    try jsonWriteStep(jw.endArray());
    try jsonWriteStep(jw.objectField("truncated"));
    try jsonWriteStep(jw.write(truncated));
    try jsonWriteStep(jw.endObject());

    return sink.toOwnedSlice();
}

fn entryKindLabel(kind: Tools.ListDirectory.EntryKind) []const u8 {
    return switch (kind) {
        .directory => "directory",
        .file => "file",
    };
}

fn expectBool(value: std.json.Value) Error!bool {
    return switch (value) {
        .bool => |b| b,
        else => error.InvalidPayload,
    };
}

fn expectPositiveInt(value: std.json.Value) Error!u16 {
    const parsed: i64 = switch (value) {
        .integer => |v| v,
        else => return error.InvalidPayload,
    };
    if (parsed < 1) return error.InvalidPayload;
    if (parsed > std.math.maxInt(u16)) return error.InvalidPayload;
    return @intCast(parsed);
}

inline fn jsonWriteStep(res: std.json.Stringify.Error!void) Error!void {
    return res catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };
}
