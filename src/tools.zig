const std = @import("std");

pub const Permission = enum {
    read_only,
};

pub const OutputKind = enum {
    json_object,
};

pub const ParameterKind = enum {
    string,
    integer,
    boolean,
};

pub const ParameterDefault = union(enum) {
    none,
    string: []const u8,
    integer: i64,
    boolean: bool,
};

pub const Parameter = struct {
    name: []const u8,
    description: []const u8 = "",
    kind: ParameterKind,
    required: bool = true,
    minimum: ?i64 = null,
    maximum: ?i64 = null,
    default_value: ParameterDefault = .none,
};

pub const ToolSchema = struct {
    id: []const u8,
    summary: []const u8,
    permissions: []const Permission,
    parameters: []const Parameter,
    output_kind: OutputKind,
};

pub const ToolInvocation = struct {
    tool_id: []const u8,
    input_payload: []const u8,
};

pub const ToolResult = union(enum) {
    success: []u8,
    failure: []u8,
};

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
    const permissions = [_]Permission{ .read_only };

    const parameters = [_]Parameter{
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

    pub const schema = ToolSchema{
        .id = id,
        .summary = "List filesystem entries under a sandboxed absolute path",
        .permissions = permissions[0..],
        .parameters = parameters[0..],
        .output_kind = .json_object,
    };
};

pub const registry = [_]ToolSchema{
    ListDirectory.schema,
};

pub fn findSchema(id: []const u8) ?*const ToolSchema {
    var idx: usize = 0;
    while (idx < registry.len) : (idx += 1) {
        const schema = &registry[idx];
        if (std.mem.eql(u8, schema.id, id)) return schema;
    }
    return null;
}
