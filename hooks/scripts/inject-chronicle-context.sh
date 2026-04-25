#!/usr/bin/env bash
set -euo pipefail

# inject-chronicle-context.sh
# Reads Codex Chronicle 10-minute screen-recording summaries and injects them
# into Claude Code as a systemMessage. Runs from two hooks:
#   SessionStart      - bootstrap with last N entries
#   UserPromptSubmit  - delta only (entries newer than last-seen)

input="$(cat)"
event="$(printf '%s' "$input" | jq -r '.hook_event_name // ""')"

CHRONICLE_DIR="${CODEX_CHRONICLE_DIR:-$HOME/.codex/memories_extensions/chronicle/resources}"
BOOTSTRAP_N="${CODEX_CHRONICLE_BOOTSTRAP_N:-3}"
MAX_AGE_HOURS="${CODEX_CHRONICLE_MAX_AGE_HOURS:-12}"

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

cutoff=$(( $(date +%s) - MAX_AGE_HOURS * 3600 ))
last_seen=0
if [ -f "$LAST_SEEN_FILE" ]; then
  last_seen="$(cat "$LAST_SEEN_FILE" 2>/dev/null || echo 0)"
  case "$last_seen" in ''|*[!0-9]*) last_seen=0 ;; esac
fi

pairs=()
while IFS= read -r line; do
  [ -n "$line" ] && pairs+=("$line")
done < <(
  find "$CHRONICLE_DIR" -maxdepth 1 -type f -name '*-10min-*.md' 2>/dev/null \
    | while IFS= read -r f; do
        m="$(get_mtime "$f")"
        if [ "$m" -ge "$cutoff" ]; then
          printf '%s\t%s\n' "$m" "$f"
        fi
      done \
    | sort -n
)

[ "${#pairs[@]}" -gt 0 ] || emit_silent

selected=()
case "$event" in
  SessionStart)
    n=${#pairs[@]}
    start=$(( n > BOOTSTRAP_N ? n - BOOTSTRAP_N : 0 ))
    for ((i=start; i<n; i++)); do
      selected+=("${pairs[i]}")
    done
    header="## Recent activity from Codex Chronicle"
    intro="The following are 10-minute summaries of what the user has been doing on their computer recently (passive screen recording analyzed by Codex Chronicle). Use this for context about the user's current focus and the broader work they have been doing across their applications."
    ;;
  UserPromptSubmit)
    for p in "${pairs[@]}"; do
      m="${p%%	*}"
      if [ "$m" -gt "$last_seen" ]; then
        selected+=("$p")
      fi
    done
    [ "${#selected[@]}" -gt 0 ] || emit_silent
    header="## New Chronicle update"
    intro="A new 10-minute Chronicle summary appeared while we were working — here is what the user did most recently:"
    ;;
  *)
    emit_silent
    ;;
esac

[ "${#selected[@]}" -gt 0 ] || emit_silent

body_file="$(mktemp)"
trap 'rm -f "$body_file"' EXIT

{
  printf '%s\n\n' "$header"
  printf '%s\n\n' "$intro"

  newest=0
  for p in "${selected[@]}"; do
    m="${p%%	*}"
    f="${p#*	}"
    if [ "$m" -gt "$newest" ]; then
      newest="$m"
    fi

    base="$(basename "$f")"
    ts="$(printf '%s' "$base" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}' || printf '%s' "$base")"

    printf '### Chronicle entry: %s\n\n' "$ts"
    awk '
      /^## Recording summary[[:space:]]*$/ { skip=1; next }
      /^## Citations[[:space:]]*$/         { skip=1; next }
      /^## / && !/^## (Recording summary|Citations)/ { skip=0 }
      !skip { print }
    ' "$f"
    printf '\n---\n\n'
  done
} > "$body_file"

printf '%s\n' "$newest" > "$LAST_SEEN_FILE"

jq -Rs '{continue: true, suppressOutput: false, systemMessage: .}' < "$body_file"
