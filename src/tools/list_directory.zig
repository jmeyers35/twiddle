const types = @import("types.zig");

pub const ListDirectory = struct {
    pub const id = "list_directory";

    pub const Limits = struct {
        hard_max_entries: u16 = 256,
        default_max_entries: u16 = 128,
    };

    pub const EntryKind = enum {
        file,
        directory,
    };

    pub const Entry = struct {
        name: []const u8,
        kind: EntryKind,
        size_bytes: ?u64 = null,
        modified_unix_ns: ?i128 = null,
    };

    pub const Result = struct {
        entries: []const Entry,
        truncated: bool = false,
    };

    const limits = Limits{};

    const permissions = [_]types.Permission{.read_only};

    const parameters = [_]types.Parameter{
        .{
            .name = "path",
            .description = "Absolute path constrained to workspace sandbox",
            .kind = .string,
        },
        .{
            .name = "max_entries",
            .description = "Upper bound on entries to return (default 128, max 256)",
            .kind = .integer,
            .required = false,
            .minimum = 1,
            .maximum = limits.hard_max_entries,
            .default_value = .{ .integer = limits.default_max_entries },
        },
        .{
            .name = "include_hidden",
            .description = "If true, include entries whose names begin with '.'",
            .kind = .boolean,
            .required = false,
            .default_value = .{ .boolean = false },
        },
        .{
            .name = "include_files",
            .description = "Emit regular files when true",
            .kind = .boolean,
            .required = false,
            .default_value = .{ .boolean = true },
        },
        .{
            .name = "include_directories",
            .description = "Emit directories when true",
            .kind = .boolean,
            .required = false,
            .default_value = .{ .boolean = true },
        },
    };

    pub const schema = types.ToolSchema{
        .id = id,
        .summary = "List filesystem entries under a sandboxed absolute path",
        .permissions = permissions[0..],
        .parameters = parameters[0..],
        .output_kind = .json_object,
    };
};
