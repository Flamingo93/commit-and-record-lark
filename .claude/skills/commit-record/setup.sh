#!/bin/bash
# setup.sh - Initialize Feishu Bitable for commit recording
# Creates a new Bitable with proper fields and saves config to .commit-record.json

set -euo pipefail

# --- Locate git repo root ---
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "Error: Not inside a git repository" >&2
  exit 1
}

CONFIG_FILE="$REPO_ROOT/.commit-record.json"

# --- Check if already configured ---
if [ -f "$CONFIG_FILE" ]; then
  BASE_TOKEN=$(jq -r '.base_token // empty' "$CONFIG_FILE" 2>/dev/null)
  TABLE_ID=$(jq -r '.table_id // empty' "$CONFIG_FILE" 2>/dev/null)
  if [ -n "$BASE_TOKEN" ] && [ -n "$TABLE_ID" ]; then
    echo "Already configured. Config file: $CONFIG_FILE"
    jq '.' "$CONFIG_FILE"
    echo ""
    echo "To re-initialize, delete $CONFIG_FILE and run this script again."
    exit 0
  fi
fi

# --- Determine repo name for Bitable title ---
REMOTE_URL=$(git remote get-url origin 2>/dev/null || echo "")
if [ -n "$REMOTE_URL" ]; then
  REPO_NAME=$(echo "$REMOTE_URL" | sed -E 's|\.git$||' | sed -E 's|.*[:/]([^/]+/[^/]+)$|\1|')
else
  REPO_NAME=$(basename "$REPO_ROOT")
fi

BASE_NAME="Commit Records - $REPO_NAME"

echo "=== Commit Record Setup ==="
echo "Repository: $REPO_NAME"
echo "Bitable name: $BASE_NAME"
echo ""

# --- Step 1: Create Bitable ---
echo "[1/5] Creating Bitable..."
CREATE_RESULT=$(lark-cli base +base-create --name "$BASE_NAME" 2>&1)

if ! echo "$CREATE_RESULT" | jq -e '.ok == true' >/dev/null 2>&1; then
  echo "Error: Failed to create Bitable" >&2
  echo "$CREATE_RESULT" >&2
  exit 1
fi

BASE_TOKEN=$(echo "$CREATE_RESULT" | jq -r '.data.base.base_token')
BASE_URL=$(echo "$CREATE_RESULT" | jq -r '.data.base.url // empty')
echo "  Base Token: $BASE_TOKEN"
[ -n "$BASE_URL" ] && echo "  URL: $BASE_URL"

# --- Step 2: Get default table ---
echo "[2/5] Getting default table..."
TABLE_RESULT=$(lark-cli base +table-list --base-token "$BASE_TOKEN" 2>&1)

if ! echo "$TABLE_RESULT" | jq -e '.ok == true' >/dev/null 2>&1; then
  echo "Error: Failed to list tables" >&2
  echo "$TABLE_RESULT" >&2
  exit 1
fi

TABLE_ID=$(echo "$TABLE_RESULT" | jq -r '.data.tables[0].id // .data.items[0].table_id // empty')
echo "  Table ID: $TABLE_ID"

# --- Step 3: Get default field IDs for later deletion ---
echo "[3/5] Setting up fields..."
FIELD_RESULT=$(lark-cli base +field-list --base-token "$BASE_TOKEN" --table-id "$TABLE_ID" 2>&1)
DEFAULT_FIELD_IDS=$(echo "$FIELD_RESULT" | jq -r '(.data.fields // .data.items)[] | (.id // .field_id)')

# Create new fields first (so table always has at least one field)
FIELDS=(
  '{"type":"text","name":"commit_hash","description":"Git commit SHA hash"}'
  '{"type":"text","name":"repository","description":"Repository name (owner/repo)"}'
  '{"type":"text","name":"branch","description":"Git branch name"}'
  '{"type":"text","name":"author","description":"Commit author name"}'
  '{"type":"text","name":"author_email","style":{"type":"email"},"description":"Commit author email"}'
  '{"type":"datetime","name":"commit_time","style":{"format":"yyyy/MM/dd HH:mm"},"description":"Commit timestamp"}'
  '{"type":"text","name":"commit_message","description":"Commit message"}'
  '{"type":"number","name":"lines_added","style":{"type":"plain","precision":0},"description":"Lines added"}'
  '{"type":"number","name":"lines_deleted","style":{"type":"plain","precision":0},"description":"Lines deleted"}'
  '{"type":"number","name":"files_changed","style":{"type":"plain","precision":0},"description":"Files changed"}'
)

for field_json in "${FIELDS[@]}"; do
  FIELD_NAME=$(echo "$field_json" | jq -r '.name')
  RESULT=$(lark-cli base +field-create --base-token "$BASE_TOKEN" --table-id "$TABLE_ID" --json "$field_json" 2>&1)
  if echo "$RESULT" | jq -e '.ok == true' >/dev/null 2>&1; then
    echo "  Created field: $FIELD_NAME"
  else
    echo "  Warning: Failed to create field $FIELD_NAME" >&2
    echo "  $RESULT" >&2
  fi
done

# Delete default fields
for fid in $DEFAULT_FIELD_IDS; do
  lark-cli base +field-delete --base-token "$BASE_TOKEN" --table-id "$TABLE_ID" --field-id "$fid" --yes >/dev/null 2>&1 || true
done
echo "  Cleaned up default fields"

# --- Step 4: Rename table ---
echo "[4/5] Renaming table..."
lark-cli base +table-update --base-token "$BASE_TOKEN" --table-id "$TABLE_ID" --name "Commit Records" >/dev/null 2>&1 || true

# --- Step 5: Save config ---
echo "[5/5] Saving config..."
jq -n \
  --arg base_token "$BASE_TOKEN" \
  --arg table_id "$TABLE_ID" \
  --arg base_url "$BASE_URL" \
  --arg repo_name "$REPO_NAME" \
  '{
    base_token: $base_token,
    table_id: $table_id,
    base_url: $base_url,
    repo_name: $repo_name
  }' > "$CONFIG_FILE"

echo ""
echo "=== Setup Complete ==="
echo "Config saved to: $CONFIG_FILE"
[ -n "$BASE_URL" ] && echo "Bitable URL: $BASE_URL"
echo ""
echo "IMPORTANT: Add .commit-record.json to your .gitignore:"
echo "  echo '.commit-record.json' >> $REPO_ROOT/.gitignore"
