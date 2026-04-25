# claude-chronicle

A Claude Code plugin that bridges [Codex Chronicle](https://github.com/openai/codex) into Claude Code. Codex Chronicle passively records your screen and writes a markdown summary every ~10 minutes describing what you have been doing across your apps. This plugin reads those summaries and injects them into Claude Code as context, so Claude knows what you have been working on outside of the terminal.

## What it does

Two hooks, one script:

- **`SessionStart`** — when Claude Code starts, injects:
  1. The **3 most recent** 10-minute Chronicle summaries as full content (current focus).
  2. A **manifest of every Chronicle entry on disk** — timestamps, relative ages, absolute paths — so Claude knows the full memory window and can `Read` any older entry on demand.
  3. A **Chronicle live state** section — pidfile health, freshest screen frames per display, OCR sidecar locations, and a usage guide that tells Claude *which* source to reach for given the kind of question.
- **`UserPromptSubmit`** — on every prompt, checks for **new** Chronicle entries that appeared since the last injection and adds only those. Stays silent if there is nothing new.

Both events skip the `## Recording summary` and `## Citations` sections of each Chronicle file (raw OCR detail and frame paths). Claude sees the `## Memory summary`, `### Context of everything that came before this recording`, and `### Important non-obvious context about the user` sections.

### Asking about earlier activity

Because the SessionStart manifest lists **every** Chronicle file with its local timestamp and "Xh ago" tag, you can ask about anything in that window and Claude will pick the right file(s) and read them:

- "co robiłem 5 godzin temu?"
- "what was I working on yesterday evening?"
- "przedwczoraj nad południem nad jakim projektem siedziałem?"
- "podsumuj mi cały tydzień"

No regex / NLU in the hook — Claude does the time reasoning over the manifest table itself, then uses the `Read` tool to pull only the entries it actually needs.

### Looking at the screen

The live state section also exposes the ephemeral screen-recording side of Chronicle:

- **Live frames** (`*-display-N-latest.jpg`) per display, refreshed by the recorder. Useful for "what's on my screen right now?".
- **OCR sidecars** (`*.ocr.jsonl`) — append-only OCR text history. Useful for `rg`-style searches like "where did I see this error?".
- **1-minute historical frames** (`1min/<segment>/frame-*.jpg`).

The injected guidance teaches Claude to (a) prefer authoritative sources (connectors, file system) over OCR'd screen text, (b) copy `latest.jpg` to a temp file before manipulating it (the recorder silently overwrites the original), and (c) use OCR only for keyword search, not for verbatim text extraction.

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
| `CODEX_CHRONICLE_DIR` | `~/.codex/memories_extensions/chronicle/resources` | Directory containing `*-10min-*.md` (and `*-6h-*.md` if any) files |
| `CODEX_CHRONICLE_BOOTSTRAP_N` | `3` | How many recent entries to inline as full content on `SessionStart` |
| `CODEX_CHRONICLE_MAX_AGE_HOURS` | `12` | Window for the "full content" entries on `SessionStart` (manifest is unaffected) |
| `CODEX_CHRONICLE_MANIFEST_MAX` | `500` | Hard cap on how many entries to list in the manifest table (most recent are kept) |
| `CODEX_CHRONICLE_LIVE_DIR` | `$TMPDIR` | Root for Chronicle's ephemeral state — expects `<dir>/codex_chronicle/chronicle-started.pid` and `<dir>/chronicle/screen_recording/` |

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
