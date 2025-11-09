const std = @import("std");

pub const Permission = enum {
    read_only,
    workspace_write,
};

pub const OutputKind = enum {
    json_object,
};

pub const ParameterKind = enum {
    string,
    integer,
    boolean,
    object,
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

pub const ToolKind = enum {
    list_directory,
    read_file,
    search,
    apply_patch,
};

pub const ToolSchema = struct {
    id: []const u8,
    kind: ToolKind,
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

pub fn eqlId(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
