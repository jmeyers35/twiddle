const std = @import("std");

const Application = @import("../app/runner.zig").Application;

pub const PromptLoop = struct {
    input_stream: *std.io.Reader,
    output_stream: *std.io.Writer,
    prompt: []const u8,
    wait_message: []const u8,
    stdout_is_tty: bool,

    pub fn init(
        input_stream: *std.io.Reader,
        output_stream: *std.io.Writer,
        prompt: []const u8,
        wait_message: []const u8,
        stdout_is_tty: bool,
    ) PromptLoop {
        return .{
            .input_stream = input_stream,
            .output_stream = output_stream,
            .prompt = prompt,
            .wait_message = wait_message,
            .stdout_is_tty = stdout_is_tty,
        };
    }

    pub fn run(self: *PromptLoop, app: *Application) !void {
        while (true) {
            try self.output_stream.writeAll(self.prompt);
            try self.output_stream.flush();

            const maybe_line = self.input_stream.takeDelimiter('\n') catch |err| switch (err) {
                error.StreamTooLong => {
                    try self.output_stream.writeAll(
                        "\nInput line exceeded internal buffer capacity (64KiB). Please shorten the request.\n",
                    );
                    try self.output_stream.flush();
                    return err;
                },
                else => return err,
            };
            const raw_line = maybe_line orelse break;

            const without_cr = std.mem.trimRight(u8, raw_line, "\r");
            const trimmed = std.mem.trim(u8, without_cr, " \t");

            if (trimmed.len == 0) continue;
            if (std.mem.eql(u8, trimmed, "exit")) break;

            var session = app.makeSession(self.stdout_is_tty, self.wait_message, self.output_stream);
            session.run(trimmed) catch |err| switch (err) {
                error.ToolEnvelopeInvalid => {},
                else => return err,
            };
        }
    }
};
