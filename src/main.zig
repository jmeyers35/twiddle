const std = @import("std");
const Application = @import("app/runner.zig").Application;
const PromptLoop = @import("cli/prompt_loop.zig").PromptLoop;

const CliArgs = struct {
    const Mode = union(enum) {
        interactive,
        headless: []const u8,
    };

    allocator: std.mem.Allocator,
    mode: Mode = .interactive,
    prompt_buffer: ?[]u8 = null,

    fn deinit(self: *CliArgs) void {
        if (self.prompt_buffer) |buffer| {
            self.allocator.free(buffer);
        }
        self.* = undefined;
    }
};

const max_prompt_bytes: usize = 512 * 1024;

comptime {
    std.debug.assert(@import("tools.zig").registry.len != 0);
}

pub fn main() !void {
    const stdin = std.fs.File.stdin();
    const stdout = std.fs.File.stdout();
    const stderr = std.fs.File.stderr();
    const stdout_is_tty = stdout.isTty();

    var stdin_buffer: [64 * 1024]u8 = undefined;
    var stdout_buffer: [4 * 1024]u8 = undefined;
    var stderr_buffer: [1 * 1024]u8 = undefined;

    var stdin_reader = std.fs.File.reader(stdin, stdin_buffer[0..]);
    var stdout_writer = std.fs.File.writer(stdout, stdout_buffer[0..]);
    var stderr_writer = std.fs.File.writer(stderr, stderr_buffer[0..]);

    const input_stream = &stdin_reader.interface;
    const output_stream = &stdout_writer.interface;
    const error_stream = &stderr_writer.interface;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var cli_args = parseArgs(gpa.allocator(), error_stream) catch |err| switch (err) {
        error.ShowHelp => {
            try error_stream.flush();
            try printUsage(output_stream);
            try output_stream.flush();
            return;
        },
        error.InvalidUsage => {
            try error_stream.flush();
            try printUsage(output_stream);
            try output_stream.flush();
            std.process.exit(1);
        },
        else => return err,
    };
    defer cli_args.deinit();

    var app = try Application.init(gpa.allocator(), output_stream);
    defer app.deinit();

    const prompt = "twiddle> ";
    const wait_message = "twiddling...";

    switch (cli_args.mode) {
        .interactive => {
            var loop = PromptLoop.init(input_stream, output_stream, prompt, wait_message, stdout_is_tty);
            try loop.run(&app);
        },
        .headless => |instruction| {
            var session = app.makeSession(input_stream, stdout_is_tty, wait_message, output_stream);
            session.run(instruction) catch |err| switch (err) {
                error.ToolEnvelopeInvalid => return,
                else => return err,
            };
        },
    }
}

fn parseArgs(allocator: std.mem.Allocator, stderr: anytype) !CliArgs {
    var iterator = try std.process.argsWithAllocator(allocator);
    defer iterator.deinit();

    var parsed = CliArgs{
        .allocator = allocator,
        .mode = .interactive,
        .prompt_buffer = null,
    };
    errdefer if (parsed.prompt_buffer) |buffer| {
        allocator.free(buffer);
        parsed.prompt_buffer = null;
    };

    _ = iterator.next(); // skip executable path

    while (iterator.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            return error.ShowHelp;
        }

        if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--prompt")) {
            const value = iterator.next() orelse {
                try stderr.writeAll("missing value for -p/--prompt\n");
                return error.InvalidUsage;
            };
            const duped = try allocator.dupe(u8, value);
            try installPrompt(&parsed, duped, allocator, stderr);
            continue;
        }

        if (std.mem.eql(u8, arg, "--prompt-file")) {
            const path = iterator.next() orelse {
                try stderr.writeAll("missing value for --prompt-file\n");
                return error.InvalidUsage;
            };
            const buffer = readPromptFile(allocator, path) catch |err| switch (err) {
                error.FileTooBig => {
                    try stderr.print("prompt file exceeds {d} bytes\n", .{max_prompt_bytes});
                    return error.InvalidUsage;
                },
                else => {
                    try stderr.print("failed to read prompt file: {s}\n", .{@errorName(err)});
                    return error.InvalidUsage;
                },
            };
            try installPrompt(&parsed, buffer, allocator, stderr);
            continue;
        }

        try stderr.print("unknown argument: {s}\n", .{arg});
        return error.InvalidUsage;
    }

    return parsed;
}

fn installPrompt(parsed: *CliArgs, buffer: []u8, allocator: std.mem.Allocator, stderr: anytype) !void {
    if (buffer.len == 0) {
        allocator.free(buffer);
        try stderr.writeAll("prompt cannot be empty\n");
        return error.InvalidUsage;
    }

    if (parsed.prompt_buffer != null) {
        allocator.free(buffer);
        try stderr.writeAll("prompt already specified\n");
        return error.InvalidUsage;
    }

    parsed.prompt_buffer = buffer;
    parsed.mode = .{ .headless = buffer };
}

fn readPromptFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return file.readToEndAlloc(allocator, max_prompt_bytes);
}

fn printUsage(writer: anytype) !void {
    try writer.writeAll(
        \\
        \\Usage:
        \\  twiddle                          # interactive REPL
        \\  twiddle -p \"<prompt>\"            # run a single headless turn
        \\  twiddle --prompt-file path       # headless turn using file contents
        \\
        \\Options:
        \\  -p, --prompt <text>        Provide the instruction inline.
        \\      --prompt-file <path>   Read the instruction from a file (<=512KiB).
        \\  -h, --help                 Show this help message.
    );
}
