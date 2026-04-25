# Changelog

All notable changes to **claude-chronicle** are recorded here. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0] — 2026-04-25

### Added
- **`/claude-chronicle:remind` skill** — on-demand search of the Chronicle archive. Three auto-detected modes:
  1. **Time** — argument is a time reference (EN: `5 hours ago`, `yesterday evening`, `Tuesday afternoon`; PL: `5 godzin temu`, `wczoraj wieczorem`, `wtorek po południu`). The skill resolves it to a UTC window and picks files whose filename timestamp falls inside.
  2. **Topic** — argument is a thing the user wants to recall but does not say when (EN: `the auth bug`, `React 418 error`, `Figma logo project`; PL: `ten bug z auth`, `błąd Reacta 418`, `projekt logo w Figmie`). The skill `rg`-greps the Chronicle archive for the keyword(s), ranks by recency, and reports **when** the user last touched the topic. Falls back to OCR sidecars (`*.ocr.jsonl`) if no markdown match is found.
  3. **Hybrid** — argument has both: `the auth bug yesterday`, `Figma logo last week`. The skill narrows by time first, then keyword-greps inside that window.
- The skill runs autonomously (no "do you want me to read X?" prompts), reads picked entries, skips noisy `Recording summary` / `Citations` sections, and answers in the user's language.

## [0.2.0] — 2026-04-25

### Added
- **Chronicle archive manifest** on `SessionStart`. After the 3 freshest 10-min entries (full content), the plugin now appends a markdown table listing every Chronicle file on disk with its local timestamp, relative age (`Xh ago`), kind (`10min` / `6h`), and absolute path. Claude reads this table and uses the `Read` tool to fetch only the entries it needs when you ask about earlier activity in any language — `"5 hours ago"` / `"5 godzin temu"`, `"yesterday evening"` / `"wczoraj wieczorem"`, `"last week"` / `"tydzień temu"`, … — no NLU in the hook.
- **Chronicle live state** section on `SessionStart` (adapted from the upstream Codex `chronicle` skill):
  - Pidfile health (`running` / stale / off) so Claude knows whether recordings are live or historical.
  - Freshest `*-display-N-latest.jpg` per display with relative ages (multi-display aware).
  - OCR sidecar (`*.ocr.jsonl`) and `1min/<segment>/frame-*.jpg` snapshot locations.
  - Inline guidance for Claude on which source to reach for given the question (live frame → `rg` over OCR → archive → upgrade to authoritative source).
- Support for `*-6h-*.md` rollups in the manifest (auto-detected when Chronicle generates them).

### Changed
- Replaced regex-based "deep history" intent detection in `UserPromptSubmit` with the manifest approach above. Time reasoning is now done by Claude over the manifest, not by the shell hook.
- README updated to describe the manifest, live state, and the new env var.

### Added (config)
- `CODEX_CHRONICLE_MANIFEST_MAX` (default `500`) — cap on manifest table rows.
- `CODEX_CHRONICLE_LIVE_DIR` (default `$TMPDIR`) — root for Chronicle's ephemeral state.

### Removed (config)
- `CODEX_CHRONICLE_DEEP_DEFAULT_HOURS`, `CODEX_CHRONICLE_DEEP_MAX_HOURS`, `CODEX_CHRONICLE_DEEP_MAX_ENTRIES` — no longer needed; the manifest approach replaces deep-window expansion.

### Fixed
- README `Limitations` section incorrectly claimed `*-6h-*.md` rollups were skipped. They are not — corrected to describe the actual behaviour.
- `printf '- ...'` calls were being parsed as flags by the bash builtin in some cases; converted to `printf '%s\n' "..."` for safety.

## [0.1.0] — 2026-04-25

### Added
- Initial release.
- `SessionStart` hook injecting the 3 most recent `*-10min-*.md` Chronicle summaries (within the last 12 h) as a `systemMessage`.
- `UserPromptSubmit` hook injecting only **new** Chronicle entries since `last-seen`; silent when there is nothing new.
- Sections `## Recording summary` and `## Citations` are stripped from each injected entry.
- `last-seen.txt` cursor in `${CLAUDE_PLUGIN_ROOT}/.state/`.
- Config via env vars: `CODEX_CHRONICLE_DIR`, `CODEX_CHRONICLE_BOOTSTRAP_N`, `CODEX_CHRONICLE_MAX_AGE_HOURS`.
- Bash 3.2+ compatibility (no `mapfile`), cross-platform `stat` (BSD + GNU).
- Marketplace manifest at `.claude-plugin/marketplace.json` (single-plugin, `source: "./"`), MIT license.
