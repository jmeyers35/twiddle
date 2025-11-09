const std = @import("std");
const Tools = @import("tools.zig");
const list_dir_impl = @import("tools/impl/list_directory.zig");
const read_file_impl = @import("tools/impl/read_file.zig");

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

        if (std.mem.eql(u8, schema.id, Tools.ReadFile.id)) {
            const payload = self.readFile(invocation.input_payload) catch |err| switch (err) {
                error.InvalidPayload => return self.failure("invalid read_file payload"),
                error.PathOutsideSandbox => return self.failure("path escapes sandbox root"),
                error.PathNotFound => return self.failure("path not found"),
                error.PathNotFile => return self.failure("path is not a regular file"),
                error.OffsetExceedsLength => return self.failure("offset exceeds file length"),
                error.AnchorExceedsLength => return self.failure("anchor_line exceeds file length"),
                error.PermissionDenied => return self.failure("permission denied when reading file"),
                error.IoFailure => return self.failure("filesystem error while reading file"),
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

    const ListDirError = list_dir_impl.Error;
    const ReadFileError = read_file_impl.Error;

    fn listDirectory(self: *ToolExecutor, payload: []const u8) ListDirError![]u8 {
        return list_dir_impl.run(self, payload);
    }

    fn readFile(self: *ToolExecutor, payload: []const u8) ReadFileError![]u8 {
        return read_file_impl.run(self, payload);
    }

    const ResolveError = std.mem.Allocator.Error || error{
        PathNotFound,
        PathOutsideSandbox,
        PermissionDenied,
    };

    pub fn resolvePath(self: *ToolExecutor, path: []const u8) ResolveError![]u8 {
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
