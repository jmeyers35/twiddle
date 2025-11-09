const std = @import("std");
const types = @import("types.zig");

pub const ReadFile = struct {
    pub const id = "read_file";

    pub const Limits = struct {
        hard_limit: u16 = 4000,
        default_limit: u16 = 2000,
        max_line_length: u16 = 500,
        tab_width: u8 = 4,
    };

    pub const schema = blk: {
        const limits = Limits{};
        const parameters = [_]types.Parameter{
            .{
                .name = "file_path",
                .description = "Absolute path constrained to workspace sandbox",
                .kind = .string,
            },
            .{
                .name = "offset",
                .description = "1-indexed line number to start reading from (default 1)",
                .kind = .integer,
                .required = false,
                .minimum = 1,
                .default_value = .{ .integer = 1 },
            },
            .{
                .name = "limit",
                .description = "Maximum number of lines to return (default 2000, max 4000)",
                .kind = .integer,
                .required = false,
                .minimum = 1,
                .maximum = limits.hard_limit,
                .default_value = .{ .integer = limits.default_limit },
            },
            .{
                .name = "mode",
                .description = "Either 'slice' for a simple range or 'indentation' for structural reads",
                .kind = .string,
                .required = false,
                .default_value = .{ .string = "slice" },
            },
            .{
                .name = "indentation",
                .description = "Indentation mode options: anchor_line, max_levels, include_siblings, include_header, max_lines",
                .kind = .object,
                .required = false,
            },
        };

        break :blk types.ToolSchema{
            .id = id,
            .summary = "Read formatted source lines from a sandboxed file",
            .permissions = &[_]types.Permission{.read_only},
            .parameters = parameters[0..],
            .output_kind = .json_object,
        };
    };

    pub fn emitSummary(writer: *std.Io.Writer, value: std.json.Value) bool {
        if (value != .object) return false;
        const mode_val = value.object.get("mode") orelse return false;
        if (mode_val != .string) return false;
        const lines_val = value.object.get("lines") orelse return false;
        if (lines_val != .array) return false;
        const truncated_val = value.object.get("truncated") orelse return false;
        if (truncated_val != .bool) return false;
        writer.print(" ({s} mode, {d} lines, truncated={})", .{ mode_val.string, lines_val.array.items.len, truncated_val.bool }) catch return false;
        return true;
    }
};
