const std = @import("std");
const Tools = @import("tools.zig");

pub const ToolExecutor = struct {
    allocator: std.mem.Allocator,
    sandbox_root: []u8,
    sandbox_dir: std.fs.Dir,

    pub const Error = std.mem.Allocator.Error || std.fs.File.OpenError || error{
        InvalidSandbox,
        ToolNotFound,
        PermissionDenied,
        ToolUnavailable,
    };

    pub fn init(allocator: std.mem.Allocator, sandbox_root: []const u8) Error!ToolExecutor {
        const resolved = try resolveRootPath(allocator, sandbox_root);
        errdefer allocator.free(resolved);

        const dir = std.fs.openDirAbsolute(resolved, .{
            .iterate = true,
            .access_sub_paths = true,
        }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return error.InvalidSandbox,
            else => return err,
        };

        return .{
            .allocator = allocator,
            .sandbox_root = resolved,
            .sandbox_dir = dir,
        };
    }

    pub fn deinit(self: *ToolExecutor) void {
        self.sandbox_dir.close();
        self.allocator.free(self.sandbox_root);
        self.* = undefined;
    }

    pub fn execute(self: *ToolExecutor, invocation: Tools.ToolInvocation) (Error || std.mem.Allocator.Error)!Tools.ToolResult {
        const schema = Tools.findSchema(invocation.tool_id) orelse return error.ToolNotFound;
        try ensureReadOnly(schema.permissions);

        if (std.mem.eql(u8, schema.id, Tools.ListDirectory.id)) {
            const payload = self.listDirectory(invocation.input_payload) catch |err| switch (err) {
                error.InvalidPayload => return self.failure("invalid list_directory payload"),
                error.PathOutsideSandbox => return self.failure("path escapes sandbox root"),
                error.PathNotDirectory => return self.failure("path is not a directory"),
                error.PathNotFound => return self.failure("path not found"),
                error.NoEntriesRequested => return self.failure("include_files and include_directories cannot both be false"),
                error.PermissionDenied => return self.failure("permission denied when reading directory"),
                error.IoFailure => return self.failure("filesystem error while reading directory"),
                error.OutOfMemory => return error.OutOfMemory,
            };
            return Tools.ToolResult{ .success = payload };
        }

        return error.ToolUnavailable;
    }

    pub fn deinitResult(self: *ToolExecutor, result: *Tools.ToolResult) void {
        switch (result.*) {
            .success => |payload| {
                if (payload.len != 0) self.allocator.free(payload);
            },
            .failure => |payload| {
                if (payload.len != 0) self.allocator.free(payload);
            },
        }
        // SAFETY: All union payloads freed above; clearing prevents accidental reuse.
        result.* = undefined;
    }

    fn failure(self: *ToolExecutor, message: []const u8) std.mem.Allocator.Error!Tools.ToolResult {
        const duped = try self.allocator.alloc(u8, message.len);
        if (message.len != 0) @memcpy(duped, message);
        return .{ .failure = duped };
    }

    fn ensureReadOnly(perms: []const Tools.Permission) error{PermissionDenied}!void {
        for (perms) |perm| {
            if (perm != .read_only) return error.PermissionDenied;
        }
    }

    const ListDirError = std.mem.Allocator.Error || error{
        InvalidPayload,
        PathOutsideSandbox,
        PathNotDirectory,
        PathNotFound,
        NoEntriesRequested,
        PermissionDenied,
        IoFailure,
    };

    fn listDirectory(self: *ToolExecutor, payload: []const u8) ListDirError![]u8 {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
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

        const resolved_path = try self.resolvePath(trimmed_path);
        defer self.allocator.free(resolved_path);

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
        var sink = std.io.Writer.Allocating.init(self.allocator);
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

    const ResolveError = std.mem.Allocator.Error || error{
        PathNotFound,
        PathOutsideSandbox,
        PermissionDenied,
    };

    fn resolvePath(self: *ToolExecutor, path: []const u8) ResolveError![]u8 {
        const resolved = std.fs.cwd().realpathAlloc(self.allocator, path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.FileNotFound, error.NotDir => return error.PathNotFound,
            error.AccessDenied => return error.PermissionDenied,
            else => return error.PathNotFound,
        };
        errdefer self.allocator.free(resolved);
        if (!pathWithinSandbox(self.sandbox_root, resolved)) {
            return error.PathOutsideSandbox;
        }
        return resolved;
    }

    fn expectBool(value: std.json.Value) ListDirError!bool {
        return switch (value) {
            .bool => |b| b,
            else => error.InvalidPayload,
        };
    }

    fn expectPositiveInt(value: std.json.Value) ListDirError!u16 {
        const parsed: i64 = switch (value) {
            .integer => |v| v,
            else => return error.InvalidPayload,
        };
        if (parsed < 1) return error.InvalidPayload;
        if (parsed > std.math.maxInt(u16)) return error.InvalidPayload;
        return @intCast(parsed);
    }
};

fn resolveRootPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const resolved = std.fs.cwd().realpathAlloc(allocator, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidSandbox,
    };
    errdefer allocator.free(resolved);
    const trimmed_len = trimTrailingSeparators(resolved);
    return resolved[0..trimmed_len];
}

inline fn jsonWriteStep(res: std.json.Stringify.Error!void) error{OutOfMemory}!void {
    return res catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };
}

fn trimTrailingSeparators(path: []u8) usize {
    var len = path.len;
    while (len > 1 and path[len - 1] == std.fs.path.sep) {
        len -= 1;
    }
    return len;
}

fn pathWithinSandbox(root: []const u8, candidate: []const u8) bool {
    if (!std.mem.startsWith(u8, candidate, root)) return false;
    if (candidate.len == root.len) return true;
    const sep = candidate[root.len];
    return sep == std.fs.path.sep;
}
