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
```

If the file is missing, twiddle falls back to the built-in defaults and reads the API key from the `OPENAI_API_KEY` environment variable. Invalid or empty strings are rejected during startup so you get fast feedback.
