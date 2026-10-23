---
name: machine-clean-up
description: Use when Codex, Claude Code, OpenCode, MCP servers, Playwright, Chrome helpers, node, bun, uv, or agent subprocesses appear duplicated, orphaned, stuck, memory-heavy, CPU-heavy, or need process cleanup on macOS. Closes orphaned and duplicate MCP processes right away, then offers anything else it found.
disable-model-invocation: true
---

# Machine Clean Up

## Purpose

Machine Clean Up frees memory held by local coding-agent process leaks on macOS: stale Codex, Claude Code, OpenCode, MCP, Playwright, Chrome helper, `node`, `bun`, `uv`, and shell-snapshot processes. It works without killing active work.

Default posture: **close what the contract covers immediately, report it, then offer the rest**.

## Contract

Closed without asking:

- **Orphans** — MCP-like processes whose parent agent is gone (`PPID=1`), older than 10 minutes.
- **Duplicates** — the exact same MCP command started more than once under the same parent agent, older than 10 minutes. The newest copy per parent is kept.

Never closed:

- active Codex, Claude Code, OpenCode, ChatGPT and Claude app roots and any process group that contains them;
- the agent running this skill and its whole ancestry;
- every process group that belongs to Cursor;
- `node_repl` and Computer Use services;
- MCP commands with relative paths, because identical text may point to different servers;
- MCPs of other live sessions, even when another session runs the same server.

Offered only, closed after the user's explicit yes: anything in `REVIEW_ONLY` or a heavy process outside the contract.

Never run broad kills such as `pkill node`, `pkill python`, `killall node` or `pkill "Google Chrome"`.

## When to Use

- Codex, Claude Code, or OpenCode feels slow after many sessions.
- Activity Monitor or Force Quit shows agents using tens of gigabytes, or many `node`, `bun`, `uv`, `npm exec`, `chrome-devtools-mcp`, `playwright-mcp`, or Chrome Helper processes.
- MCP tools keep multiplying, leaking RAM/CPU, or surviving after the parent agent closes.
- The machine is hot, battery drains quickly, swap grows, or fans run after agent work.
- The user asks to clean, inspect, kill, reap, prune, or diagnose agent/MCP processes.

Do not use it for ordinary app quitting, malware removal, launchd management, package cache cleanup, or deleting project files.

## Run

Default action, without a confirmation step:

```sh
<skill-dir>/scripts/machine-clean-up.sh --auto
```

`--auto` closes duplicate groups with `SIGTERM`, waits, sends `SIGKILL` only to survivors, then does the same for orphans. Every target is re-checked (parent, process group, age, command) right before a signal.

Plan only, nothing closed — use when the user asks what would happen:

```sh
<skill-dir>/scripts/machine-clean-up.sh --auto --dry-run
```

Read-only scan with the full `REVIEW_ONLY` list:

```sh
<skill-dir>/scripts/machine-clean-up.sh --show-all
```

A different age threshold, e.g. after a long session:

```sh
<skill-dir>/scripts/machine-clean-up.sh --auto --min-age-min 30
```

## After the run

1. Report the result in the shape below.
2. Look at `REVIEW_ONLY`. If it holds old duplicate groups of a named MCP across sessions or a clearly heavy process, list them with age and RSS and ask whether to close them.
3. Only after an explicit yes, close a named group, keeping the newest N:

```sh
<skill-dir>/scripts/machine-clean-up.sh --review chrome-devtools-mcp --keep-newest 1
<skill-dir>/scripts/machine-clean-up.sh --apply-review chrome-devtools-mcp --keep-newest 1
```

`--apply-review` keeps the newest N groups across the whole machine, so it can close an MCP of another live session. Say so when offering it.

For Playwright/Chrome, terminate the owning MCP process tree, not an individual `Google Chrome Helper`, because helpers are children and may respawn.

## Scheduling

The user may run `--auto` on a schedule (for example a launchd agent every hour). Set one up only when the user asks; the script itself never installs a schedule.

## Interpretation

- `SAFE_TO_TERMINATE`: orphaned MCP-like process with `PPID=1`, old enough to clean.
- `AUTO duplicate MCP groups`: identical MCP command under the same parent; all but the newest are closed by `--auto`.
- `REVIEW_ONLY`: MCP-like child under a live agent root; never closed automatically.
- `LIVE_DUPLICATE_REVIEW`: groups matched by name in `--review`; machine-wide, offer only.
- `SENSITIVE_ARGS`: command line appears to expose credentials or tokens; report the risk without printing secrets.

## Paths

`<skill-dir>` is the folder this file lives in, for example `~/.codex/skills/machine-clean-up` (Codex) or `~/.claude/skills/machine-clean-up` (Claude Code).

## Output Shape

Keep the user-facing response short:

- how many duplicate groups and orphans were closed;
- estimated RAM freed;
- before/after available RAM and load;
- what remains and is offered for closing, if anything;
- exact manual recovery command if needed.

If sensitive command-line arguments are found, say that credentials appear in process args and identify only the process/app, not the secret value.
