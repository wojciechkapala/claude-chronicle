# claude-chronicle

A Claude Code plugin that bridges [Codex Chronicle](https://github.com/openai/codex) into Claude Code. Codex Chronicle passively records your screen and writes a markdown summary every ~10 minutes describing what you have been doing across your apps. This plugin reads those summaries and injects them into Claude Code as context, so Claude knows what you have been working on outside of the terminal.

## What it does

Two hooks, one script:

- **`SessionStart`** — when Claude Code starts, loads the **3 most recent** 10-min Chronicle summaries (within the last 12 hours) and injects them as a `systemMessage`.
- **`UserPromptSubmit`** — on every prompt, checks for **new** Chronicle entries that appeared since the last injection and adds only those. Stays silent if there is nothing new.

Both events skip the `## Recording summary` and `## Citations` sections of each Chronicle file (those contain raw OCR detail and frame paths that are not useful for Claude). Claude sees the `## Memory summary`, `### Context of everything that came before this recording`, and `### Important non-obvious context about the user` sections.

## Prerequisites

- macOS or Linux
- `bash` 3.2+ (the macOS default works) and `jq` available in `PATH`
- [Codex CLI](https://github.com/openai/codex) installed and Chronicle enabled, writing to `~/.codex/memories_extensions/chronicle/resources/`

If Chronicle is not active or the directory is empty, the plugin exits silently — it never breaks a Claude Code session.

## Installation

### Option A — via marketplace (recommended)

Inside Claude Code:

```
/plugin marketplace add wojciechkapala/claude-chronicle
/plugin install claude-chronicle@claude-chronicle
```

Then restart Claude Code.

### Option B — load directly from a local clone

```bash
git clone https://github.com/wojciechkapala/claude-chronicle.git
claude --plugin-dir ./claude-chronicle
```

### Option C — copy into the user plugin dir

```bash
git clone https://github.com/wojciechkapala/claude-chronicle.git ~/.claude/plugins/claude-chronicle
```

Then restart Claude Code. Hooks load on session start, so any change to `hooks/hooks.json` requires a restart.

## Configuration

All optional, controlled via environment variables:

| Variable | Default | Purpose |
|---|---|---|
| `CODEX_CHRONICLE_DIR` | `~/.codex/memories_extensions/chronicle/resources` | Directory containing `*-10min-*.md` files |
| `CODEX_CHRONICLE_BOOTSTRAP_N` | `3` | How many entries to load on `SessionStart` |
| `CODEX_CHRONICLE_MAX_AGE_HOURS` | `12` | Ignore entries older than this |

Set them in your shell profile (`~/.zshrc`, `~/.bashrc`) before starting Claude Code.

## Runtime state

The plugin tracks the newest Chronicle entry it has already shown in `${CLAUDE_PLUGIN_ROOT}/.state/last-seen.txt` (epoch seconds). This is what keeps `UserPromptSubmit` silent until a genuinely new file appears. Delete the file to re-inject everything on the next prompt.

## Debugging

### Run the script manually

Point `PLUGIN_DIR` at wherever you cloned or installed the plugin (e.g. `~/.claude/plugins/claude-chronicle` for Option C, or your local clone):

```bash
PLUGIN_DIR=~/.claude/plugins/claude-chronicle

echo '{"hook_event_name":"SessionStart","session_id":"test"}' \
  | CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
    bash "$PLUGIN_DIR/hooks/scripts/inject-chronicle-context.sh" \
  | jq .
```

Expected: a JSON object with `systemMessage` containing your latest activity. With no new files since the last `SessionStart`, the same command for `UserPromptSubmit` returns `{"continue":true,"suppressOutput":true}`.

### Tail the debug log inside Claude Code

```bash
claude --debug --plugin-dir ~/.claude/plugins/claude-chronicle
```

Look for `SessionStart` hook execution and the injected `systemMessage`.

## Limitations

- Hook configuration is loaded once at session start. Editing `hooks.json` or the script does not affect the running session — restart Claude Code.
- Reads only `*-10min-*.md` files. Chronicle's 6-hour rollups (`*-6h-*.md`) are intentionally skipped in this version.
- The `last-seen` cursor is global (one file across all sessions), not per-session. This works because Chronicle writes new files in chronological order.

## License

MIT
