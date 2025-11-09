const types = @import("types.zig");

pub const Search = struct {
    pub const id = "search";

    const parameters = [_]types.Parameter{
        .{
            .name = "pattern",
            .description = "Needle to search for. Use literal text for ripgrep, structured patterns or rules for ast-grep.",
            .kind = .string,
        },
        .{
            .name = "engine",
            .description = "Either 'ripgrep' for fast textual scans or 'ast-grep' for syntax-aware, structured matching (default ripgrep).",
            .kind = .string,
            .required = false,
            .default_value = .{ .string = "ripgrep" },
        },
        .{
            .name = "paths",
            .description = "Optional JSON array of sandboxed absolute paths to search. Defaults to the workspace root when omitted.",
            .kind = .object,
            .required = false,
        },
        .{
            .name = "include_globs",
            .description = "Optional JSON array of glob patterns to narrow the file set (e.g. ['src/**/*.zig']).",
            .kind = .object,
            .required = false,
        },
        .{
            .name = "exclude_globs",
            .description = "Optional JSON array of globs to ignore (e.g. ['zig-cache/**']).",
            .kind = .object,
            .required = false,
        },
        .{
            .name = "case_sensitive",
            .description = "Controls case sensitivity for ripgrep searches (default true).",
            .kind = .boolean,
            .required = false,
            .default_value = .{ .boolean = true },
        },
        .{
            .name = "regex",
            .description = "Interpret the pattern as ripgrep regex when true, otherwise search literal text (default false).",
            .kind = .boolean,
            .required = false,
            .default_value = .{ .boolean = false },
        },
        .{
            .name = "context_before",
            .description = "Number of ripgrep context lines to include before each match (default 0, max 10).",
            .kind = .integer,
            .required = false,
            .minimum = 0,
            .maximum = 10,
            .default_value = .{ .integer = 0 },
        },
        .{
            .name = "context_after",
            .description = "Number of ripgrep context lines to include after each match (default 0, max 10).",
            .kind = .integer,
            .required = false,
            .minimum = 0,
            .maximum = 10,
            .default_value = .{ .integer = 0 },
        },
        .{
            .name = "limit",
            .description = "Upper bound on results to return (default 200, max 2000).",
            .kind = .integer,
            .required = false,
            .minimum = 1,
            .maximum = 2000,
            .default_value = .{ .integer = 200 },
        },
        .{
            .name = "ast_language",
            .description = "Language flag passed to ast-grep (e.g. 'TypeScript'). Ignored when engine is ripgrep.",
            .kind = .string,
            .required = false,
        },
    };

    pub const schema = types.ToolSchema{
        .id = id,
        .summary = "Search files with ripgrep for fast text scans or ast-grep for precise, syntax-aware matches",
        .permissions = &[_]types.Permission{.read_only},
        .parameters = parameters[0..],
        .output_kind = .json_object,
    };
};
