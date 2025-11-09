const std = @import("std");
const Application = @import("app/runner.zig").Application;
const PromptLoop = @import("cli/prompt_loop.zig").PromptLoop;

comptime {
    std.debug.assert(@import("tools.zig").registry.len != 0);
}

pub fn main() !void {
    const stdin = std.fs.File.stdin();
    const stdout = std.fs.File.stdout();
    const stdout_is_tty = stdout.isTty();

    var stdin_buffer: [64 * 1024]u8 = undefined;
    var stdout_buffer: [4 * 1024]u8 = undefined;

    var stdin_reader = std.fs.File.reader(stdin, stdin_buffer[0..]);
    var stdout_writer = std.fs.File.writer(stdout, stdout_buffer[0..]);

    const input_stream = &stdin_reader.interface;
    const output_stream = &stdout_writer.interface;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var app = try Application.init(gpa.allocator(), output_stream);
    defer app.deinit();

    const prompt = "twiddle> ";
    const wait_message = "twiddling...";

    var loop = PromptLoop.init(input_stream, output_stream, prompt, wait_message, stdout_is_tty);
    try loop.run(&app);
}
