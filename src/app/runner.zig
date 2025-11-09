const std = @import("std");

const ChatClient = @import("../chat_client.zig").ChatClient;
const Config = @import("../config.zig");
const Session = @import("session.zig").Session;
const ToolExecutor = @import("../tool_executor.zig").ToolExecutor;

pub const Application = struct {
    allocator: std.mem.Allocator,
    config_path: ?[]u8,
    runtime_config: Config.Loaded,
    chat_client: ChatClient,
    tool_executor: ToolExecutor,

    pub fn init(allocator: std.mem.Allocator, output_stream: *std.io.Writer) !Application {
        const config_path = try Config.defaultConfigPath(allocator);
        errdefer if (config_path) |p| allocator.free(p);

        var runtime_config = Config.load(allocator, config_path) catch |err| switch (err) {
            error.ConfigParseFailed => {
                try emitConfigError(output_stream, "Failed to parse twiddle config", config_path);
                try output_stream.flush();
                return err;
            },
            error.ConfigTooLarge => {
                try emitConfigError(output_stream, "Config file exceeds 64KiB limit", config_path);
                try output_stream.flush();
                return err;
            },
            else => return err,
        };
        errdefer runtime_config.deinit(allocator);

        var chat_client = ChatClient.init(allocator, .{
            .base_url = runtime_config.base_url,
            .model = runtime_config.model,
            .api_key = runtime_config.api_key,
        }) catch |err| switch (err) {
            error.ApiKeyMissing => {
                try output_stream.writeAll("\nMissing API key. Set OPENAI_API_KEY or add api_key to ");
                if (config_path) |p| {
                    try output_stream.writeAll(p);
                } else {
                    try output_stream.writeAll("~/.twiddle/twiddle.toml");
                }
                try output_stream.writeAll(".\n");
                try output_stream.flush();
                return err;
            },
            else => return err,
        };
        errdefer chat_client.deinit();

        var tool_executor = ToolExecutor.init(allocator, ".", runtime_config.sandbox_mode) catch |err| {
            try output_stream.writeAll("failed to initialize tool executor: ");
            try output_stream.writeAll(@errorName(err));
            try output_stream.writeAll("\n");
            return err;
        };
        errdefer tool_executor.deinit();

        const tool_context_message = try std.fmt.allocPrint(
            allocator,
            "Workspace root: {s}. Provide absolute paths within this root when using tools. Sandbox mode: {s}.",
            .{ tool_executor.sandbox_root, Config.sandboxModeLabel(runtime_config.sandbox_mode) },
        );
        defer allocator.free(tool_context_message);
        try chat_client.setToolContext(tool_context_message);

        return .{
            .allocator = allocator,
            .config_path = config_path,
            .runtime_config = runtime_config,
            .chat_client = chat_client,
            .tool_executor = tool_executor,
        };
    }

    pub fn deinit(self: *Application) void {
        self.tool_executor.deinit();
        self.chat_client.deinit();
        self.runtime_config.deinit(self.allocator);
        if (self.config_path) |path| {
            self.allocator.free(path);
        }
        self.* = undefined;
    }

    pub fn makeSession(
        self: *Application,
        input_stream: *std.io.Reader,
        stdout_is_tty: bool,
        wait_message: []const u8,
        output_stream: *std.io.Writer,
    ) Session {
        return Session.init(
            self.allocator,
            &self.chat_client,
            &self.tool_executor,
            input_stream,
            stdout_is_tty,
            wait_message,
            self.runtime_config.approval_policy,
            output_stream,
        );
    }
};

fn emitConfigError(writer: anytype, message: []const u8, config_path: ?[]const u8) !void {
    try writer.writeAll("\n");
    try writer.writeAll(message);
    try writer.writeAll(" (");
    if (config_path) |p| {
        try writer.writeAll(p);
    } else {
        try writer.writeAll("~/.twiddle/twiddle.toml");
    }
    try writer.writeAll(").\n");
}
