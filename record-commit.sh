#!/bin/bash
# record-commit.sh - Record git commit info to Feishu Bitable
# Usage: ./record-commit.sh [commit-hash]
# If no commit hash provided, uses HEAD

set -euo pipefail

# --- Locate config (global, next to this script) ---
SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SKILL_DIR/bitable-meta.json"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "Error: Config file not found at $CONFIG_FILE" >&2
  echo "Please run setup.sh first to initialize the Bitable." >&2
  exit 1
fi

BASE_TOKEN=$(jq -r '.base_token // empty' "$CONFIG_FILE")
TABLE_ID=$(jq -r '.table_id // empty' "$CONFIG_FILE")

if [ -z "$BASE_TOKEN" ] || [ -z "$TABLE_ID" ]; then
  echo "Error: Invalid config - missing base_token or table_id" >&2
  exit 1
fi

# --- Must be in a git repo ---
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "Error: Not inside a git repository" >&2
  exit 1
}

REPO_ROOT=$(git rev-parse --show-toplevel)

# --- Determine commit hash ---
COMMIT_HASH="${1:-HEAD}"

# --- Extract commit info ---
FULL_HASH=$(git log -1 --format='%H' "$COMMIT_HASH")
AUTHOR=$(git log -1 --format='%an' "$COMMIT_HASH")
AUTHOR_EMAIL=$(git log -1 --format='%ae' "$COMMIT_HASH")
# Format: "2026-04-12 15:30:00 +0800" -> "2026-04-12 15:30:00"
COMMIT_TIME=$(git log -1 --format='%ai' "$COMMIT_HASH" | sed 's/ [+-][0-9][0-9]*$//')
COMMIT_MESSAGE=$(git log -1 --format='%s' "$COMMIT_HASH")
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "detached")

# --- Extract repository name ---
REMOTE_URL=$(git remote get-url origin 2>/dev/null || echo "")
if [ -n "$REMOTE_URL" ]; then
  REPO_NAME=$(echo "$REMOTE_URL" | sed -E 's|\.git$||' | sed -E 's|.*[:/]([^/]+/[^/]+)$|\1|')
else
  REPO_NAME=$(basename "$REPO_ROOT")
fi

# --- Extract diff stats ---
# For initial commit (no parent), diff against empty tree
EMPTY_TREE=$(git hash-object -t tree /dev/null)
STAT_OUTPUT=$(git diff --numstat "${FULL_HASH}^..${FULL_HASH}" 2>/dev/null || git diff --numstat "${EMPTY_TREE}..${FULL_HASH}" 2>/dev/null || echo "")

LINES_ADDED=0
LINES_DELETED=0
FILES_CHANGED=0

if [ -n "$STAT_OUTPUT" ]; then
  LINES_ADDED=$(echo "$STAT_OUTPUT" | awk '{s+=$1} END {print s+0}')
  LINES_DELETED=$(echo "$STAT_OUTPUT" | awk '{s+=$2} END {print s+0}')
  FILES_CHANGED=$(echo "$STAT_OUTPUT" | wc -l | tr -d ' ')
fi

# --- Extract incremental token/cost from Claude Code transcript (if called from hook) ---
SESSION_COST=""
SESSION_INPUT_TOKENS=""
SESSION_OUTPUT_TOKENS=""

# Try reading hook stdin (non-blocking) for transcript_path
HOOK_INPUT=""
if [ ! -t 0 ]; then
  HOOK_INPUT=$(cat 2>/dev/null || true)
fi

TRANSCRIPT_PATH=""
if [ -n "$HOOK_INPUT" ]; then
  TRANSCRIPT_PATH=$(echo "$HOOK_INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || true)
fi

OFFSET_FILE="$SKILL_DIR/.last-offset"

if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
  TOTAL_LINES=$(wc -l < "$TRANSCRIPT_PATH" | tr -d ' ')

  # Determine where to start: use saved offset if it matches this transcript
  START_LINE=1
  if [ -f "$OFFSET_FILE" ]; then
    SAVED_TRANSCRIPT=$(jq -r '.transcript // empty' "$OFFSET_FILE" 2>/dev/null || true)
    SAVED_OFFSET=$(jq -r '.offset // 0' "$OFFSET_FILE" 2>/dev/null || true)
    if [ "$SAVED_TRANSCRIPT" = "$TRANSCRIPT_PATH" ] && [ "$SAVED_OFFSET" -gt 0 ] 2>/dev/null; then
      START_LINE=$((SAVED_OFFSET + 1))
    fi
  fi

  # Only process new lines (from START_LINE to end)
  if [ "$START_LINE" -le "$TOTAL_LINES" ]; then
    # Pricing per million tokens (USD):
    #   claude-opus-4-6:   input=$5,  output=$25, cache_write=$6.25, cache_read=$0.50
    #   claude-sonnet-4-6: input=$3,  output=$15, cache_write=$3.75, cache_read=$0.30
    #   claude-haiku-4-5:  input=$1,  output=$5,  cache_write=$1.25, cache_read=$0.10
    TOKEN_STATS=$(tail -n +"$START_LINE" "$TRANSCRIPT_PATH" | jq -s '
      [.[] | select(.message.usage != null)]
      | group_by(.message.id)
      | map(last)
      | reduce .[] as $e (
          {input: 0, output: 0, cost: 0};
          ($e.message.model // "unknown") as $m
          | ($e.message.usage.input_tokens // 0) as $in
          | ($e.message.usage.output_tokens // 0) as $out
          | ($e.message.usage.cache_creation_input_tokens // 0) as $cw
          | ($e.message.usage.cache_read_input_tokens // 0) as $cr
          | (if ($m | test("opus")) then {i: 5, o: 25, cw: 6.25, cr: 0.50}
             elif ($m | test("sonnet")) then {i: 3, o: 15, cw: 3.75, cr: 0.30}
             elif ($m | test("haiku")) then {i: 1, o: 5, cw: 1.25, cr: 0.10}
             else {i: 3, o: 15, cw: 3.75, cr: 0.30} end) as $p
          | .input += ($in + $cw + $cr)
          | .output += $out
          | .cost += (($in * $p.i + $out * $p.o + $cw * $p.cw + $cr * $p.cr) / 1000000)
        )
    ' 2>/dev/null || true)

    if [ -n "$TOKEN_STATS" ]; then
      SESSION_COST=$(echo "$TOKEN_STATS" | jq -r '.cost | . * 10000 | round / 10000')
      SESSION_INPUT_TOKENS=$(echo "$TOKEN_STATS" | jq -r '.input')
      SESSION_OUTPUT_TOKENS=$(echo "$TOKEN_STATS" | jq -r '.output')
    fi
  fi

  # Save current offset for next incremental calculation
  jq -n --arg t "$TRANSCRIPT_PATH" --argjson o "$TOTAL_LINES" \
    '{transcript: $t, offset: $o}' > "$OFFSET_FILE"
fi

# --- Build JSON payload ---
JSON_PAYLOAD=$(jq -n \
  --arg hash "$FULL_HASH" \
  --arg repo "$REPO_NAME" \
  --arg branch "$BRANCH" \
  --arg author "$AUTHOR" \
  --arg email "$AUTHOR_EMAIL" \
  --arg time "$COMMIT_TIME" \
  --arg msg "$COMMIT_MESSAGE" \
  --argjson added "$LINES_ADDED" \
  --argjson deleted "$LINES_DELETED" \
  --argjson files "$FILES_CHANGED" \
  --arg s_cost "$SESSION_COST" \
  --arg s_in "$SESSION_INPUT_TOKENS" \
  --arg s_out "$SESSION_OUTPUT_TOKENS" \
  '{
    "commit_hash": $hash,
    "repository": $repo,
    "branch": $branch,
    "author": $author,
    "author_email": $email,
    "commit_time": $time,
    "commit_message": $msg,
    "lines_added": $added,
    "lines_deleted": $deleted,
    "files_changed": $files
  }
  | if $s_cost != "" then .session_cost = ($s_cost | tonumber) else . end
  | if $s_in != "" then .session_input_tokens = ($s_in | tonumber) else . end
  | if $s_out != "" then .session_output_tokens = ($s_out | tonumber) else . end
  ')

# --- Write to Bitable ---
echo "Recording commit ${FULL_HASH:0:8} to Feishu Bitable..."

RESULT=$(lark-cli base +record-upsert \
  --base-token "$BASE_TOKEN" \
  --table-id "$TABLE_ID" \
  --json "$JSON_PAYLOAD" 2>&1)

if echo "$RESULT" | jq -e '.ok == true' >/dev/null 2>&1; then
  RECORD_ID=$(echo "$RESULT" | jq -r '.data.record.record_id_list[0] // .data.record.record_id // "unknown"')
  BASE_URL=$(jq -r '.base_url // empty' "$CONFIG_FILE")
  echo "Success: Commit ${FULL_HASH:0:8} recorded (record_id: $RECORD_ID)"
  [ -n "$BASE_URL" ] && echo "Bitable URL: $BASE_URL"
else
  ERROR_MSG=$(echo "$RESULT" | jq -r '.error.message // "Unknown error"' 2>/dev/null || echo "$RESULT")
  echo "Error recording commit: $ERROR_MSG" >&2
  exit 1
fi
