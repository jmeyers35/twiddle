const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Role = enum { user, assistant, tool };

pub const ToolCall = struct {
    id: []u8,
    name: []u8,
    arguments_json: []u8,
};

pub const Message = struct {
    role: Role,
    content: []u8 = &.{},
    content_is_null: bool = false,
    tool_call_id: []u8 = &.{},
    tool_name: []u8 = &.{},
    tool_calls: []ToolCall = &.{},
    processed_tool_calls: usize = 0,

    pub fn deinit(self: *Message, allocator: Allocator) void {
        switch (self.role) {
            .tool => {
                if (self.tool_call_id.len != 0) allocator.free(self.tool_call_id);
                if (self.tool_name.len != 0) allocator.free(self.tool_name);
            },
            else => {},
        }

        if (self.tool_calls.len != 0) {
            for (self.tool_calls) |call| {
                if (call.id.len != 0) allocator.free(call.id);
                if (call.name.len != 0) allocator.free(call.name);
                if (call.arguments_json.len != 0) allocator.free(call.arguments_json);
            }
            allocator.free(self.tool_calls);
        }

        if (self.content.len != 0) allocator.free(self.content);
        self.* = undefined;
    }
};

pub fn freeToolCalls(allocator: Allocator, calls: []const ToolCall) void {
    for (calls) |call| {
        if (call.id.len != 0) allocator.free(call.id);
        if (call.name.len != 0) allocator.free(call.name);
        if (call.arguments_json.len != 0) allocator.free(call.arguments_json);
    }
}

pub fn truncate(list: *std.ArrayListUnmanaged(Message), allocator: Allocator, new_len: usize) void {
    var len = list.items.len;
    while (len > new_len) {
        len -= 1;
        var message = &list.items[len];
        message.deinit(allocator);
    }
    list.items.len = new_len;
}

pub fn clear(list: *std.ArrayListUnmanaged(Message), allocator: Allocator) void {
    truncate(list, allocator, 0);
}
