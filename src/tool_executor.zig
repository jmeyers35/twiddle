const std = @import("std");
const Config = @import("config.zig");
const Tools = @import("tools.zig");
const list_dir_impl = @import("tools/impl/list_directory.zig");
const read_file_impl = @import("tools/impl/read_file.zig");
const search_impl = @import("tools/impl/search.zig");
const testing = std.testing;

pub const ToolExecutor = struct {
    allocator: std.mem.Allocator,
    sandbox_root: []u8,
    sandbox_dir: std.fs.Dir,
    sandbox_mode: Config.SandboxMode,
    workspace_write_enabled: bool,

    pub const Error = std.mem.Allocator.Error || std.fs.File.OpenError || error{
        InvalidSandbox,
        ToolNotFound,
        PermissionDenied,
        ToolUnavailable,
        WorkspaceWriteRequired,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        sandbox_root: []const u8,
        sandbox_mode: Config.SandboxMode,
    ) Error!ToolExecutor {
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
            .sandbox_mode = sandbox_mode,
            .workspace_write_enabled = sandbox_mode != .read_only,
        };
    }

    pub fn deinit(self: *ToolExecutor) void {
        self.sandbox_dir.close();
        self.allocator.free(self.sandbox_root);
        self.* = undefined;
    }

    pub fn execute(self: *ToolExecutor, invocation: Tools.ToolInvocation) (Error || std.mem.Allocator.Error)!Tools.ToolResult {
        const schema = Tools.findSchema(invocation.tool_id) orelse return error.ToolNotFound;
        try self.ensurePermissions(schema.permissions);

        switch (schema.kind) {
            .list_directory => {
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
            },
            .read_file => {
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
            },
            .search => {
                const payload = self.search(invocation.input_payload) catch |err| switch (err) {
                    error.InvalidPayload => return self.failure("invalid search payload"),
                    error.PathOutsideSandbox => return self.failure("path escapes sandbox root"),
                    error.PathNotFound => return self.failure("path not found"),
                    error.PermissionDenied => return self.failure("permission denied while running search"),
                    error.BinaryUnavailable => return self.failure("required search binary not available"),
                    error.CommandFailed => return self.failure("search command failed"),
                    error.ToolLimitExceeded => return self.failure("search output exceeded limit"),
                    error.IoFailure => return self.failure("filesystem error while running search"),
                    error.OutOfMemory => return error.OutOfMemory,
                };
                return Tools.ToolResult{ .success = payload };
            },
        }

        unreachable;
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

    fn ensurePermissions(self: *ToolExecutor, perms: []const Tools.Permission) error{PermissionDenied, WorkspaceWriteRequired}!void {
        const required = highestPermission(perms);
        switch (required) {
            .read_only => return,
            .workspace_write => {
                if (self.workspace_write_enabled) return;
                return error.WorkspaceWriteRequired;
            },
        }
    }

    const ListDirError = list_dir_impl.Error;
    const ReadFileError = read_file_impl.Error;
    const SearchError = search_impl.Error;

    fn listDirectory(self: *ToolExecutor, payload: []const u8) ListDirError![]u8 {
        return list_dir_impl.run(self, payload);
    }

    fn readFile(self: *ToolExecutor, payload: []const u8) ReadFileError![]u8 {
        return read_file_impl.run(self, payload);
    }

    fn search(self: *ToolExecutor, payload: []const u8) SearchError![]u8 {
        return search_impl.run(self, payload);
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

    pub fn sandboxRoot(self: *const ToolExecutor) []const u8 {
        return self.sandbox_root;
    }

    pub fn enableWorkspaceWrite(self: *ToolExecutor) void {
        if (self.workspace_write_enabled) return;
        self.workspace_write_enabled = true;
        if (self.sandbox_mode == .read_only) {
            self.sandbox_mode = .workspace_write;
        }
    }

    pub fn hasWorkspaceWrite(self: *const ToolExecutor) bool {
        return self.workspace_write_enabled;
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

fn highestPermission(perms: []const Tools.Permission) Tools.Permission {
    var highest = Tools.Permission.read_only;
    for (perms) |perm| {
        if (@intFromEnum(perm) > @intFromEnum(highest)) {
            highest = perm;
        }
    }
    return highest;
}

test "workspace write permission is enforced until granted" {
    var tmp = try testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root);

    var executor = try ToolExecutor.init(testing.allocator, root, .read_only);
    defer executor.deinit();

    try executor.ensurePermissions(&.{ .read_only });
    try testing.expectError(error.WorkspaceWriteRequired, executor.ensurePermissions(&.{ .workspace_write }));

    executor.enableWorkspaceWrite();
    try executor.ensurePermissions(&.{ .workspace_write });
    try testing.expect(executor.hasWorkspaceWrite());
}
