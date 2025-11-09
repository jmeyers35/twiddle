# twiddle - the most efficient coding agent in the universe

This is `twiddle`, and we're on a mission to build the best and most efficient coding agent in the universe.

## Goals/Implementation Principles
- Minimal dependencies - if we can do it with the standard library, we should
- Hyper-efficient, down to every bit. **EVERY** implementation decision made for `twiddle` must be made with this goal in mind.
- Unreasonably effective. Our goal is to be the top agent on `terminalbench` with as minimal an implementation as possible.
- Simple/concise implementation - `twiddle` source should be easy to follow and reason about.
- Follow the zen of zig!
- The Agent should be as autonomous as possible as safely as possible

## Development

- Always run `mise check` after making changes.
- The tool sandbox starts in read-only mode. Either set `sandbox_mode = "workspace-write"` up front or answer the on-request prompt when a tool needs write access. Interactive approvals are disabled when `approval_policy = "never"`.
- A “session” spans the entire lifetime of the `twiddle` CLI process. Approvals (for example workspace-write) persist until you exit Twiddle or manually change the sandbox configuration, even if you enter multiple prompts.
