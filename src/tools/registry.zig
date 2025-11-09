const types = @import("types.zig");

const list_directory = @import("list_directory.zig").ListDirectory;
const read_file = @import("read_file.zig").ReadFile;

pub const registry = [_]types.ToolSchema{
    list_directory.schema,
    read_file.schema,
};

pub fn findSchema(id: []const u8) ?*const types.ToolSchema {
    var idx: usize = 0;
    while (idx < registry.len) : (idx += 1) {
        const schema = &registry[idx];
        if (types.eqlId(schema.id, id)) return schema;
    }
    return null;
}
