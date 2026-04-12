#!/bin/bash
# record-commit.sh - Record git commit info to Feishu Bitable
# Usage: ./record-commit.sh [commit-hash]
# If no commit hash provided, uses HEAD

set -euo pipefail

# --- Locate git repo root and config ---
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "Error: Not inside a git repository" >&2
  exit 1
}

CONFIG_FILE="$REPO_ROOT/.commit-record.json"

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
  }')

# --- Write to Bitable ---
echo "Recording commit ${FULL_HASH:0:8} to Feishu Bitable..."

RESULT=$(lark-cli base +record-upsert \
  --base-token "$BASE_TOKEN" \
  --table-id "$TABLE_ID" \
  --json "$JSON_PAYLOAD" 2>&1)

if echo "$RESULT" | jq -e '.ok == true' >/dev/null 2>&1; then
  RECORD_ID=$(echo "$RESULT" | jq -r '.data.record.record_id // "unknown"')
  echo "Success: Commit ${FULL_HASH:0:8} recorded (record_id: $RECORD_ID)"
else
  ERROR_MSG=$(echo "$RESULT" | jq -r '.error.message // "Unknown error"' 2>/dev/null || echo "$RESULT")
  echo "Error recording commit: $ERROR_MSG" >&2
  exit 1
fi
