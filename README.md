# twiddle - the most efficient coding agent in the universe

## Goals
- Minimal dependencies
- Hyper-efficient, down to every bit
- Unreasonably effective

## Evaluating Performance
- We'll use terminalbench to evaluate Agent effectiveness

## Development
- Trust the repo config once via `mise trust` (required before tasks run).
- Install the pinned Zig toolchain via `mise install` (reads `.mise.toml`).
- Install `zlint` from https://github.com/DonIsaac/zlint (needed for linting).
- Run `mise run check` to build the project and execute `zlint` in one shot.

## Configuration
Create `~/.twiddle/twiddle.toml` to override the default OpenRouter settings or to store your API key. The current schema is intentionally tiny:

```toml
# All fields are optional. Omitted values fall back to the defaults below.
base_url = "https://openrouter.ai/api"   # string URL used to build the chat endpoint
model    = "openai/gpt-5-codex"            # string identifier for the model
api_key  = "sk-your-key"                   # string API key; falls back to $OPENAI_API_KEY if missing
sandbox_mode = "read-only"                 # "read-only", "workspace-write", or "danger-full-access"
approval_policy = "on-request"            # "on-request" prompts when more access is needed, "never" auto-denies
```

If the file is missing, twiddle falls back to the built-in defaults and reads the API key from the `OPENAI_API_KEY` environment variable. Invalid or empty strings are rejected during startup so you get fast feedback.

Twiddle starts in `read-only` mode and only grants write access inside the workspace after you explicitly approve it. Leave `sandbox_mode` at `read-only` to keep the hardened default and set `approval_policy = "on-request"` (the default) so Twiddle can prompt when a tool needs writes. If you prefer to opt in ahead of time, set `sandbox_mode = "workspace-write"` and Twiddle will skip the interactive prompt and allow write tools immediately. Setting `approval_policy = "never"` keeps runs non-interactive by automatically denying escalation attempts unless the sandbox mode already grants the required capability.

### Sessions vs conversations

In Twiddle, a **session** lasts from the moment you launch the CLI until you exit it. Multiple prompts (and even `/clear` in the future) still belong to the same session, while a conversation refers to the rolling chat history managed by the shared client. Approval prompts such as workspace-write access therefore remain in effect for the entire CLI lifetime unless you restart Twiddle or explicitly downgrade the sandbox mode.
