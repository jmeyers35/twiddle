const std = @import("std");
const Tools = @import("../tools.zig");
const msgs = @import("messages.zig");

pub fn buildPayload(client: anytype, buffer: *std.io.Writer.Allocating) error{PayloadTooLarge}![]const u8 {
    const config = client.config;
    buffer.clearRetainingCapacity();
    var jw = std.json.Stringify{
        .writer = &buffer.writer,
        .options = .{ .whitespace = .minified },
    };

    try stringifyStep(jw.beginObject());
    try stringifyStep(jw.objectField("model"));
    try stringifyStep(jw.write(config.model));

    try stringifyStep(jw.objectField("stream"));
    try stringifyStep(jw.write(true));

    try stringifyStep(jw.objectField("stream_options"));
    try stringifyStep(jw.beginObject());
    try stringifyStep(jw.objectField("include_usage"));
    try stringifyStep(jw.write(true));
    try stringifyStep(jw.endObject());

    if (config.max_completion_tokens) |limit| {
        try stringifyStep(jw.objectField("max_completion_tokens"));
        try stringifyStep(jw.write(limit));
    }

    try stringifyStep(jw.objectField("temperature"));
    try stringifyStep(jw.write(config.temperature));

    try stringifyStep(jw.objectField("parallel_tool_calls"));
    try stringifyStep(jw.write(false));

    try stringifyStep(jw.objectField("tools"));
    try stringifyStep(jw.beginArray());
    for (Tools.registry) |schema| {
        try stringifyStep(jw.beginObject());
        try stringifyStep(jw.objectField("type"));
        try stringifyStep(jw.write("function"));
        try stringifyStep(jw.objectField("function"));
        try stringifyStep(jw.beginObject());
        try stringifyStep(jw.objectField("name"));
        try stringifyStep(jw.write(schema.id));
        try stringifyStep(jw.objectField("description"));
        try stringifyStep(jw.write(schema.summary));
        try stringifyStep(jw.objectField("parameters"));
        try stringifyStep(jw.beginObject());
        try stringifyStep(jw.objectField("type"));
        try stringifyStep(jw.write("object"));
        try stringifyStep(jw.objectField("properties"));
        try stringifyStep(jw.beginObject());
        for (schema.parameters) |param| {
            try stringifyStep(jw.objectField(param.name));
            try stringifyStep(jw.beginObject());
            try stringifyStep(jw.objectField("type"));
            try stringifyStep(jw.write(parameterTypeLabel(param.kind)));
            if (param.description.len != 0) {
                try stringifyStep(jw.objectField("description"));
                try stringifyStep(jw.write(param.description));
            }
            if (param.minimum) |min| {
                try stringifyStep(jw.objectField("minimum"));
                try stringifyStep(jw.write(min));
            }
            if (param.maximum) |max| {
                try stringifyStep(jw.objectField("maximum"));
                try stringifyStep(jw.write(max));
            }
            switch (param.default_value) {
                .none => {},
                .string => |value| {
                    try stringifyStep(jw.objectField("default"));
                    try stringifyStep(jw.write(value));
                },
                .integer => |value| {
                    try stringifyStep(jw.objectField("default"));
                    try stringifyStep(jw.write(value));
                },
                .boolean => |value| {
                    try stringifyStep(jw.objectField("default"));
                    try stringifyStep(jw.write(value));
                },
            }
            try stringifyStep(jw.endObject());
        }
        try stringifyStep(jw.endObject());
        try stringifyStep(jw.objectField("required"));
        try stringifyStep(jw.beginArray());
        for (schema.parameters) |param| {
            if (param.required) {
                try stringifyStep(jw.write(param.name));
            }
        }
        try stringifyStep(jw.endArray());
        try stringifyStep(jw.endObject());
        try stringifyStep(jw.endObject());
        try stringifyStep(jw.endObject());
    }
    try stringifyStep(jw.endArray());

    try stringifyStep(jw.objectField("messages"));
    try stringifyStep(jw.beginArray());
    if (config.system_prompt.len != 0) {
        try stringifyStep(jw.beginObject());
        try stringifyStep(jw.objectField("role"));
        try stringifyStep(jw.write("system"));
        try stringifyStep(jw.objectField("content"));
        try stringifyStep(jw.write(config.system_prompt));
        try stringifyStep(jw.endObject());
    }

    if (client.tool_context.len != 0) {
        try stringifyStep(jw.beginObject());
        try stringifyStep(jw.objectField("role"));
        try stringifyStep(jw.write("system"));
        try stringifyStep(jw.objectField("content"));
        try stringifyStep(jw.write(client.tool_context));
        try stringifyStep(jw.endObject());
    }

    for (client.messages.items) |message| {
        try stringifyStep(jw.beginObject());
        try stringifyStep(jw.objectField("role"));
        try stringifyStep(jw.write(roleName(message.role)));
        switch (message.role) {
            .tool => {
                if (message.tool_call_id.len != 0) {
                    try stringifyStep(jw.objectField("tool_call_id"));
                    try stringifyStep(jw.write(message.tool_call_id));
                }
                if (message.tool_name.len != 0) {
                    try stringifyStep(jw.objectField("name"));
                    try stringifyStep(jw.write(message.tool_name));
                }
                try stringifyStep(jw.objectField("content"));
                try stringifyStep(jw.write(message.content));
            },
            else => {
                try stringifyStep(jw.objectField("content"));
                if (message.content_is_null) {
                    try stringifyStep(jw.write(@as(?bool, null)));
                } else {
                    try stringifyStep(jw.write(message.content));
                }

                if (message.tool_calls.len != 0) {
                    try stringifyStep(jw.objectField("tool_calls"));
                    try stringifyStep(jw.beginArray());
                    for (message.tool_calls) |call| {
                        try stringifyStep(jw.beginObject());
                        try stringifyStep(jw.objectField("id"));
                        try stringifyStep(jw.write(call.id));
                        try stringifyStep(jw.objectField("type"));
                        try stringifyStep(jw.write("function"));
                        try stringifyStep(jw.objectField("function"));
                        try stringifyStep(jw.beginObject());
                        try stringifyStep(jw.objectField("name"));
                        try stringifyStep(jw.write(call.name));
                        try stringifyStep(jw.objectField("arguments"));
                        try stringifyStep(jw.write(call.arguments_json));
                        try stringifyStep(jw.endObject());
                        try stringifyStep(jw.endObject());
                    }
                    try stringifyStep(jw.endArray());
                }
            },
        }
        try stringifyStep(jw.endObject());
    }

    try stringifyStep(jw.endArray());
    try stringifyStep(jw.endObject());

    return buffer.written();
}

inline fn stringifyStep(res: std.json.Stringify.Error!void) error{PayloadTooLarge}!void {
    return res catch |err| switch (err) {
        error.WriteFailed => return error.PayloadTooLarge,
    };
}

fn parameterTypeLabel(kind: Tools.ParameterKind) []const u8 {
    return switch (kind) {
        .string => "string",
        .integer => "integer",
        .boolean => "boolean",
        .object => "object",
    };
}

fn roleName(role: msgs.Role) []const u8 {
    return switch (role) {
        .user => "user",
        .assistant => "assistant",
        .tool => "tool",
    };
}
