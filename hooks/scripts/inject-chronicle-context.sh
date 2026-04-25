#!/usr/bin/env bash
set -euo pipefail

# inject-chronicle-context.sh
# Injects Codex Chronicle activity summaries into Claude Code as a systemMessage.
#
# Modes:
#   SessionStart      - bootstrap: last N entries in full content + manifest of
#                       ALL files in the Chronicle directory (timestamps + paths)
#                       so Claude knows the full memory window and can Read any
#                       older entry on demand (e.g. "what was I doing 5h ago",
#                       "wczoraj wieczorem", "tydzień temu").
#   UserPromptSubmit  - delta only: entries newer than last-seen.

input="$(cat)"
event="$(printf '%s' "$input" | jq -r '.hook_event_name // ""')"

CHRONICLE_DIR="${CODEX_CHRONICLE_DIR:-$HOME/.codex/memories_extensions/chronicle/resources}"
BOOTSTRAP_N="${CODEX_CHRONICLE_BOOTSTRAP_N:-3}"
MAX_AGE_HOURS="${CODEX_CHRONICLE_MAX_AGE_HOURS:-12}"
MANIFEST_MAX="${CODEX_CHRONICLE_MANIFEST_MAX:-500}"
LIVE_DIR="${CODEX_CHRONICLE_LIVE_DIR:-${TMPDIR:-/tmp}}"
LIVE_DIR="${LIVE_DIR%/}"
PIDFILE="$LIVE_DIR/codex_chronicle/chronicle-started.pid"
RECORDINGS_DIR="$LIVE_DIR/chronicle/screen_recording"

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
STATE_DIR="$PLUGIN_ROOT/.state"
LAST_SEEN_FILE="$STATE_DIR/last-seen.txt"
mkdir -p "$STATE_DIR"

emit_silent() {
  printf '{"continue":true,"suppressOutput":true}\n'
  exit 0
}

[ -d "$CHRONICLE_DIR" ] || emit_silent

get_mtime() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0
}

# Format epoch as local datetime (e.g. "2026-04-25 04:58 CEST")
format_dt() {
  local epoch="$1"
  date -r "$epoch" "+%Y-%m-%d %H:%M %Z" 2>/dev/null \
    || date -d "@$epoch" "+%Y-%m-%d %H:%M %Z" 2>/dev/null \
    || echo "epoch:$epoch"
}

# Returns "running|<pid>" / "stale|<pid>" / "off|" describing Chronicle process state.
chronicle_proc_state() {
  if [ ! -f "$PIDFILE" ]; then
    printf 'off|\n'; return 0
  fi
  local pid
  pid="$(tr -d '[:space:]' < "$PIDFILE" 2>/dev/null || true)"
  if [ -z "$pid" ]; then
    printf 'off|\n'; return 0
  fi
  if kill -0 "$pid" 2>/dev/null; then
    printf 'running|%s\n' "$pid"
  else
    printf 'stale|%s\n' "$pid"
  fi
}

# Format epoch difference as a short relative age (e.g. "7h ago", "3d 4h ago")
format_age() {
  local epoch="$1"
  local now diff
  now="$(date +%s)"
  diff=$(( now - epoch ))
  if [ "$diff" -lt 0 ]; then diff=0; fi

  if   [ "$diff" -lt 60 ];     then printf '%ds ago'    "$diff"
  elif [ "$diff" -lt 3600 ];   then printf '%dm ago'    $(( diff / 60 ))
  elif [ "$diff" -lt 86400 ];  then
    local h=$(( diff / 3600 ))
    local m=$(( (diff % 3600) / 60 ))
    if [ "$m" -gt 0 ]; then printf '%dh %dm ago' "$h" "$m"
    else                    printf '%dh ago'      "$h"
    fi
  else
    local d=$(( diff / 86400 ))
    local h=$(( (diff % 86400) / 3600 ))
    if [ "$h" -gt 0 ]; then printf '%dd %dh ago' "$d" "$h"
    else                    printf '%dd ago'      "$d"
    fi
  fi
}

# Collect ALL Chronicle files (10min + any 6h rollups), sorted ascending by mtime.
all_pairs=()
while IFS= read -r line; do
  [ -n "$line" ] && all_pairs+=("$line")
done < <(
  find "$CHRONICLE_DIR" -maxdepth 1 -type f \
    \( -name '*-10min-*.md' -o -name '*-6h-*.md' \) 2>/dev/null \
    | while IFS= read -r f; do
        m="$(get_mtime "$f")"
        printf '%s\t%s\n' "$m" "$f"
      done \
    | sort -n
)

[ "${#all_pairs[@]}" -gt 0 ] || emit_silent

# 10-min only subset (used for the "latest in full content" section)
ten_pairs=()
for p in "${all_pairs[@]}"; do
  f="${p#*	}"
  case "$(basename "$f")" in
    *-10min-*) ten_pairs+=("$p") ;;
  esac
done

# Selection logic per event
last_seen=0
if [ -f "$LAST_SEEN_FILE" ]; then
  last_seen="$(cat "$LAST_SEEN_FILE" 2>/dev/null || echo 0)"
  case "$last_seen" in ''|*[!0-9]*) last_seen=0 ;; esac
fi

selected=()
include_manifest=0
case "$event" in
  SessionStart)
    # Last BOOTSTRAP_N 10-min entries within MAX_AGE_HOURS
    cutoff=$(( $(date +%s) - MAX_AGE_HOURS * 3600 ))
    recent=()
    for p in "${ten_pairs[@]}"; do
      m="${p%%	*}"
      if [ "$m" -ge "$cutoff" ]; then
        recent+=("$p")
      fi
    done
    n=${#recent[@]}
    start=$(( n > BOOTSTRAP_N ? n - BOOTSTRAP_N : 0 ))
    for ((i=start; i<n; i++)); do selected+=("${recent[i]}"); done
    include_manifest=1
    header="## Recent activity from Codex Chronicle"
    intro="The following are the most recent 10-minute summaries of what the user has been doing on their computer (passive screen recording analyzed by Codex Chronicle). Use this for current-context awareness, and consult the **Chronicle archive** at the end of this message for older entries."
    ;;
  UserPromptSubmit)
    for p in "${all_pairs[@]}"; do
      m="${p%%	*}"
      if [ "$m" -gt "$last_seen" ]; then
        selected+=("$p")
      fi
    done
    [ "${#selected[@]}" -gt 0 ] || emit_silent
    header="## New Chronicle update"
    intro="A new Chronicle summary appeared while we were working — here is what the user did most recently:"
    ;;
  *)
    emit_silent
    ;;
esac

body_file="$(mktemp)"
trap 'rm -f "$body_file"' EXIT

{
  printf '%s\n\n' "$header"
  printf '%s\n\n' "$intro"

  newest=0
  for p in "${selected[@]}"; do
    m="${p%%	*}"
    f="${p#*	}"
    if [ "$m" -gt "$newest" ]; then newest="$m"; fi

    base="$(basename "$f")"
    ts="$(printf '%s' "$base" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}' || printf '%s' "$base")"
    if printf '%s' "$base" | grep -q -- '-6h-'; then
      kind="6h rollup"
    else
      kind="10min"
    fi

    printf '### Chronicle entry: %s (%s, %s)\n\n' "$ts" "$kind" "$(format_age "$m")"
    awk '
      /^## Recording summary[[:space:]]*$/ { skip=1; next }
      /^## Citations[[:space:]]*$/         { skip=1; next }
      /^## / && !/^## (Recording summary|Citations)/ { skip=0 }
      !skip { print }
    ' "$f"
    printf '\n---\n\n'
  done

  # --- Manifest of all files (SessionStart only) ---
  if [ "$include_manifest" -eq 1 ] && [ "${#all_pairs[@]}" -gt 0 ]; then
    total="${#all_pairs[@]}"
    # If above MANIFEST_MAX, take the most recent MANIFEST_MAX entries
    m_start=0
    if [ "$total" -gt "$MANIFEST_MAX" ]; then
      m_start=$(( total - MANIFEST_MAX ))
    fi

    oldest_pair="${all_pairs[m_start]}"
    newest_pair="${all_pairs[$(( total - 1 ))]}"
    oldest_m="${oldest_pair%%	*}"
    newest_m="${newest_pair%%	*}"

    printf '## Chronicle archive (older entries available on demand)\n\n'
    if [ "$total" -gt "$MANIFEST_MAX" ]; then
      printf 'Listing the most recent %d of %d Chronicle entries.\n' "$MANIFEST_MAX" "$total"
    else
      printf '%d Chronicle entries on disk.\n' "$total"
    fi
    printf 'Range: **%s** → **%s**.\n' "$(format_dt "$oldest_m")" "$(format_dt "$newest_m")"
    printf 'Directory: `%s`\n\n' "$CHRONICLE_DIR"
    printf 'To answer questions about earlier activity (e.g. "5 hours ago", "yesterday evening", "wczoraj wieczorem", "tydzień temu"), pick the most relevant row(s) from the table by `Timestamp` / `Age` and use the **Read** tool with the absolute path shown in `File`.\n\n'

    printf '| Timestamp (local) | Age | Kind | File |\n'
    printf '|---|---|---|---|\n'
    # Newest first for easier scanning
    for ((i=total-1; i>=m_start; i--)); do
      p="${all_pairs[i]}"
      m="${p%%	*}"
      f="${p#*	}"
      base="$(basename "$f")"
      if printf '%s' "$base" | grep -q -- '-6h-'; then
        kind="6h"
      else
        kind="10min"
      fi
      printf '| %s | %s | %s | `%s` |\n' \
        "$(format_dt "$m")" "$(format_age "$m")" "$kind" "$f"
    done
    printf '\n'

    # --- Chronicle live state (pidfile + latest frames + OCR sidecars) ---
    proc_state="$(chronicle_proc_state)"
    proc_kind="${proc_state%%|*}"
    proc_pid="${proc_state##*|}"

    printf '## Chronicle live state\n\n'
    case "$proc_kind" in
      running)
        printf '%s\n' "- Process: **running** (pid \`$proc_pid\`) — recordings and summaries below are fresh."
        ;;
      stale)
        printf '%s\n' "- Process: **not running** (stale pidfile, was pid \`$proc_pid\`) — recordings and summaries may be stale; treat them as historical, not live."
        ;;
      off|*)
        printf '%s\n' "- Process: **not running** (no pidfile) — recordings and summaries may be stale; treat them as historical, not live."
        ;;
    esac

    if [ -d "$RECORDINGS_DIR" ]; then
      displays="$(find "$RECORDINGS_DIR" -maxdepth 1 -name '*-display-*-latest.jpg' 2>/dev/null \
        | sed -E 's|.*-display-([0-9]+)-latest\.jpg$|\1|' | sort -u)"
      if [ -n "$displays" ]; then
        printf '%s\n' "- Latest screen frames (overwritten on every capture; copy to a temp file before editing):"
        for d in $displays; do
          newest_frame="$(find "$RECORDINGS_DIR" -maxdepth 1 -name "*-display-${d}-latest.jpg" 2>/dev/null \
            | while IFS= read -r f; do
                m="$(get_mtime "$f")"
                printf '%s\t%s\n' "$m" "$f"
              done \
            | sort -n | tail -1)"
          if [ -n "$newest_frame" ]; then
            fm="${newest_frame%%	*}"
            ff="${newest_frame#*	}"
            printf '%s\n' "  - Display $d: \`$ff\` ($(format_age "$fm"))"
          fi
        done
      fi
      ocr_count="$(find "$RECORDINGS_DIR" -maxdepth 1 -name '*.ocr.jsonl' 2>/dev/null | wc -l | tr -d ' ')"
      if [ "${ocr_count:-0}" -gt 0 ]; then
        printf '%s\n' "- OCR text history: \`$ocr_count\` \`*.ocr.jsonl\` files in \`$RECORDINGS_DIR\`"
      fi
      if [ -d "$RECORDINGS_DIR/1min" ]; then
        printf '%s\n' "- Historical frame snapshots (1-minute buckets): \`$RECORDINGS_DIR/1min/\`"
      fi
    fi

    printf '\n### How to pick the right source for a question\n\n'
    printf '%s\n' '1. **"What is on my screen right now?"** → `Read` the relevant `Display N: latest.jpg` above. Note: the file is silently overwritten by the recorder, so copy it (`cp $orig /tmp/snapshot.jpg`) before doing anything else with it.'
    printf '%s\n' '2. **"Find the error/text I saw earlier"** → `rg <term>` over `*.ocr.jsonl` in the recordings dir to locate the timestamp, then inspect the matching frame from `1min/<segment>/frame-*.jpg`.'
    printf '%s\n' '3. **"What was I doing N hours/days ago?"** → use the **Chronicle archive** table above; pick the row whose `Timestamp`/`Age` matches and `Read` the file path.'
    printf '%s\n' '4. **OCR is noisy** — only use it for `rg`-style keyword search. When you need the actual text, OCR yourself from the JPG (do not trust the OCR sidecar text verbatim).'
    printf '%s\n' '5. **Upgrade to authoritative sources as soon as possible.** Once you have a doc/PR/file/ID from the screen, switch to the corresponding connector, MCP, or the file system. Do not try to reconstruct an entire document from frames.'
    printf '\n'
  fi
} > "$body_file"

# Persist newest mtime so UserPromptSubmit only sees fresh files next time.
# In SessionStart, set last-seen to the freshest file across the whole archive
# (not just the 3 we showed in full), so subsequent deltas are properly scoped.
if [ "$event" = "SessionStart" ]; then
  archive_newest="${all_pairs[$(( ${#all_pairs[@]} - 1 ))]%%	*}"
  printf '%s\n' "$archive_newest" > "$LAST_SEEN_FILE"
else
  printf '%s\n' "$newest" > "$LAST_SEEN_FILE"
fi

jq -Rs '{continue: true, suppressOutput: false, systemMessage: .}' < "$body_file"
