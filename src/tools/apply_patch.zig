const std = @import("std");
const types = @import("types.zig");

pub const ApplyPatch = struct {
    pub const id = "apply_patch";

    const permissions = [_]types.Permission{.workspace_write};

    const parameters = [_]types.Parameter{
        .{
            .name = "input",
            .description = "Entire apply_patch payload, including *** Begin Patch and *** End Patch markers.",
            .kind = .string,
        },
        .{
            .name = "workdir",
            .description = "Optional working directory relative to the sandbox root. Defaults to the sandbox root.",
            .kind = .string,
            .required = false,
        },
    };

    pub const schema = types.ToolSchema{
        .id = id,
        .kind = .apply_patch,
        .summary = "Apply a structured patch (*** Begin Patch ... *** End Patch) within the sandbox",
        .permissions = permissions[0..],
        .parameters = parameters[0..],
        .output_kind = .json_object,
    };

    pub fn emitSummary(writer: *std.Io.Writer, value: std.json.Value) bool {
        if (value != .object) return false;
        const changes_val = value.object.get("changes") orelse return false;
        if (changes_val != .array) return false;

        var add_count: usize = 0;
        var delete_count: usize = 0;
        var update_count: usize = 0;

        for (changes_val.array.items) |item| {
            if (item != .object) continue;
            const kind_val = item.object.get("kind") orelse continue;
            if (kind_val != .string) continue;
            if (std.mem.eql(u8, kind_val.string, "add")) {
                add_count += 1;
            } else if (std.mem.eql(u8, kind_val.string, "delete")) {
                delete_count += 1;
            } else if (std.mem.eql(u8, kind_val.string, "update")) {
                update_count += 1;
            }
        }

        const total = add_count + delete_count + update_count;
        writer.print(" ({d} file(s): +{d} / -{d} / Δ{d})", .{ total, add_count, delete_count, update_count }) catch return false;
        return true;
    }
};
