---
name: remind
description: Reminds the user what they were doing — by time reference, by topic / keyword, or both. Searches the Codex Chronicle archive. Trigger when the user invokes `/claude-chronicle:remind`, or asks things like "what was I doing 5 hours ago?", "co robiłem wczoraj wieczorem?", "kiedy ostatnio pracowałem nad raportami FLK?", "when did I last look at that React 418 error?", "remind me about the auth bug from earlier this week". The skill ALWAYS searches Chronicle immediately — it does not ask the user to confirm intermediate steps.
argument-hint: <time reference and/or topic> — e.g. "5 hours ago", "wczoraj wieczorem", "the auth bug", "Figma logo project last week", "React error 418"
allowed-tools: Read, Bash, Glob, Grep
---

# /claude-chronicle:remind — search Codex Chronicle

Search Codex Chronicle for what the user was doing, then summarise it concisely. Run autonomously — do not ask the user to confirm intermediate steps.

## Two modes (auto-detected from `$ARGUMENTS`)

| Mode | Trigger | Strategy |
|---|---|---|
| **Time** | Argument has a time reference but no clear topic. EN: "5 hours ago", "yesterday evening", "Tuesday afternoon", "this morning". PL: "5 godzin temu", "wczoraj wieczorem", "wtorek po południu", "dzisiaj rano". | Resolve to a UTC window, pick files whose filename timestamp falls inside it. |
| **Topic** | Argument names a thing the user wants to recall but does not say when. EN: "the auth bug", "React 418 error", "Figma logo project", "the SQL migration we discussed". PL: "ten bug z auth", "błąd Reacta 418", "projekt logo w Figmie", "ta migracja SQL". | `rg` over the Chronicle archive for the keyword(s); rank matches by recency; pick the top 1–5 distinct entries. |
| **Hybrid** | Argument has both: "the auth bug **yesterday**", "Figma logo **last week**", "the meeting **this morning** with John". | First narrow by time window, then `rg` inside that window's files. |

If `$ARGUMENTS` is empty, ask **once**: `"What should I remind you about? You can give me a time ('2 hours ago', 'wczoraj rano') or a topic ('the auth bug', 'projekt logo w Figmie') — or both."` and stop. Otherwise proceed without asking.

## Procedure

### 1. Establish "now"

```bash
date -u +%Y-%m-%dT%H:%M:%SZ      # current UTC (filenames are UTC)
date +%Y-%m-%d\ %H:%M\ %Z         # current local time + zone
```

### 2. Verify the archive exists

```bash
ARCHIVE=~/.codex/memories_extensions/chronicle/resources
ls -1 "$ARCHIVE"/*-10min-*.md "$ARCHIVE"/*-6h-*.md 2>/dev/null | head -5
```

If empty / missing: tell the user `"Codex Chronicle does not appear to be active on this machine — no archive at ~/.codex/memories_extensions/chronicle/resources/. Make sure Codex is installed and Chronicle is enabled."` and stop.

### 3. Classify `$ARGUMENTS`

- **Time tokens** (suggest time mode): `N (hours|hour|h|godzin|godziny|godzinę|min|minut|minuty|minutę|days?|dni|weeks?|tygodni)?`, `ago`, `temu`, `yesterday`, `wczoraj`, `today`, `dzisiaj`, `tonight`, `last (night|week|month|<weekday>)`, `this (morning|afternoon|evening|<weekday>)`, weekday names (PL+EN), `przedwczoraj`, `nad ranem`, `rano`, `wieczorem`, `po południu`.
- **Topic tokens**: anything else — proper nouns (project / app / file names), error codes, technical terms, person names, file paths.
- If both kinds appear → hybrid mode.
- If only topic tokens → topic mode.
- If only time tokens → time mode.

### 4a. TIME mode — resolve to a UTC window

| Phrasing | Suggested window (relative to "now", local time → convert to UTC) |
|---|---|
| `N hours ago` / `N godzin temu` | `now − N h` ± 30 min |
| `N minutes ago` / `N minut temu` (only if N ≥ 30) | `now − N min` ± 15 min |
| `yesterday evening` / `wczoraj wieczorem` | yesterday 18:00 → 23:00 |
| `yesterday morning` / `wczoraj rano` | yesterday 06:00 → 12:00 |
| `last night` / `wczoraj w nocy` | yesterday 22:00 → today 04:00 |
| `this morning` / `dzisiaj rano` | today 06:00 → 12:00 |
| `this afternoon` / `dzisiaj po południu` | today 12:00 → 18:00 |
| `this evening` / `dzisiaj wieczorem` | today 18:00 → now |
| `<weekday> afternoon` / `wtorek po południu` | most recent past `<weekday>` 12:00 → 18:00 |
| `last week` / `tydzień temu` | now − 7 days ± 12 h |
| `the day before yesterday` / `przedwczoraj` | 2 days ago, full day |

Then: keep files whose leading `YYYY-MM-DDTHH-MM-SS` (UTC) prefix falls in the window. Cap at 5 files; prefer 6h rollups when the window ≥ 6 h, otherwise 10-min entries.

### 4b. TOPIC mode — keyword search

Build the search expression from `$ARGUMENTS` (drop stop-words like `the`, `a`, `to`, `that`, `na`, `o`, `w`, `z`, `i`). Use case-insensitive, multi-word OR semantics.

```bash
# Primary: ripgrep with -l to get matching files, sorted by mtime desc
rg -l -i -e 'keyword1' -e 'keyword2' "$ARCHIVE"/*-10min-*.md "$ARCHIVE"/*-6h-*.md 2>/dev/null \
  | xargs -I{} stat -f '%m %N' {} 2>/dev/null \
  | sort -nr | head -5 | awk '{print $2}'

# If no matches, try fuzzy variants (drop diacritics, try English keys for PL terms etc.)
```

Notes:
- Always include both PL and EN forms of obvious terms (e.g. user says "logo Figma" → also try `Figma`, `logo`, English variants).
- Diacritics: try with **and** without (`żądanie` and `zadanie`, `błąd` and `blad`).
- If still nothing in `*.md`, fall back to `*.ocr.jsonl` in `$TMPDIR/chronicle/screen_recording/` for raw screen-text matches (mention "matched OCR text, may be approximate").

### 4c. HYBRID mode

Run 4a first to get the candidate file list, then `rg -l ...` over **only** those files.

### 5. Read the picked files

Use the **Read** tool on each absolute path. Skip the `## Recording summary` and `## Citations` sections (raw OCR detail / frame paths). The valuable content lives in `## Memory summary`, `### Context of everything that came before this recording`, and `### Important non-obvious context about the user`.

### 6. Synthesize

Reply in the user's language (PL → PL, EN → EN). Format:

```
At <local time / span> you were:
- <2–4 bullet points: apps used, files / projects touched, the goal of the work>

Source: <basename(s) of the Chronicle entries used>
```

For topic mode, lead with the **answer to "when?"** (the most recent matching timestamp) before the bullets:

```
You last worked on <topic> on <local datetime> (<X hours/days ago>):
- <bullets>

Earlier matches: <basename @ local datetime>, <basename @ local datetime>
Source: <basename(s)>
```

Keep the answer ≤ 8 lines unless the user asked for detail. Always end with the source filename(s) so the user can verify.

### 7. Optional follow-up

If the user's question implies an action ("…and continue what I was doing"), surface concrete next-step targets (file paths, error messages, PR URLs) extracted from the entries — but do not start executing the work without confirmation.

## Don'ts

- Do **not** trust OCR text in `## Citations` / `Recording summary` verbatim — those are noisy. If you need exact wording from the screen, look at the actual frame JPG referenced in the Chronicle live state section instead.
- Do **not** dump the full Chronicle file contents to the user — summarise.
- Do **not** ask the user "do you want me to read X?" — just read.
- Do **not** invent activity. If the matched window is sparse, the screen was locked, or no entry matches the topic, report that honestly and propose the closest alternative.
- Do **not** mix mode classification logic into the user-visible answer — keep the reply about *what they were doing*, not about *how you searched*.
