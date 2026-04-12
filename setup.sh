#!/bin/bash
# setup.sh - Initialize Feishu Bitable for commit recording
# Creates a new Bitable with proper fields and saves config to bitable-meta.json

set -euo pipefail

# --- Config path: global, shared across all repos ---
SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SKILL_DIR/bitable-meta.json"

# --- Handle --force flag ---
FORCE=false
if [ "${1:-}" = "--force" ]; then
  FORCE=true
fi

# --- Check if already configured ---
if [ -f "$CONFIG_FILE" ]; then
  BASE_TOKEN=$(jq -r '.base_token // empty' "$CONFIG_FILE" 2>/dev/null)
  TABLE_ID=$(jq -r '.table_id // empty' "$CONFIG_FILE" 2>/dev/null)
  if [ -n "$BASE_TOKEN" ] && [ -n "$TABLE_ID" ] && [ "$FORCE" = false ]; then
    echo "Already configured. Config file: $CONFIG_FILE"
    jq '.' "$CONFIG_FILE"
    echo ""
    echo "To re-initialize, run: bash setup.sh --force"
    exit 0
  fi
  if [ "$FORCE" = true ]; then
    echo "Force mode: removing old config and creating new Bitable..."
    rm -f "$CONFIG_FILE"
  fi
fi

echo "=== Commit Record Setup ==="
echo ""

# --- Step 1: Create Bitable ---
echo "[1/8] Creating Bitable..."
CREATE_RESULT=$(lark-cli base +base-create --name "Commit Records" 2>&1)

if ! echo "$CREATE_RESULT" | jq -e '.ok == true' >/dev/null 2>&1; then
  echo "Error: Failed to create Bitable" >&2
  echo "$CREATE_RESULT" >&2
  exit 1
fi

BASE_TOKEN=$(echo "$CREATE_RESULT" | jq -r '.data.base.base_token')
BASE_URL=$(echo "$CREATE_RESULT" | jq -r '.data.base.url // empty')
echo "  Base Token: $BASE_TOKEN"
[ -n "$BASE_URL" ] && echo "  URL: $BASE_URL"

# --- Step 2: Grant current user full_access permission ---
echo "[2/8] Granting user permission..."
USER_RESULT=$(lark-cli contact +get-user --as user 2>&1 || true)
USER_OPEN_ID=$(echo "$USER_RESULT" | jq -r '.data.open_id // empty' 2>/dev/null || true)

if [ -n "$USER_OPEN_ID" ]; then
  PERM_RESULT=$(lark-cli drive permission.members create \
    --params "{\"token\":\"$BASE_TOKEN\",\"type\":\"bitable\"}" \
    --data "{\"member_type\":\"openid\",\"member_id\":\"$USER_OPEN_ID\",\"perm\":\"full_access\"}" \
    --as bot 2>&1)
  if echo "$PERM_RESULT" | jq -e '.code == 0' >/dev/null 2>&1; then
    echo "  Granted full_access to current user"
  else
    echo "  Warning: Failed to grant permission. You may need to request access manually." >&2
    echo "  $PERM_RESULT" >&2
  fi
else
  # Try extracting open_id from error message (e.g. "need_user_authorization (user: ou_xxx)")
  FALLBACK_ID=$(echo "$USER_RESULT" | grep -oE 'ou_[a-f0-9]+' | head -1 || true)
  if [ -n "$FALLBACK_ID" ]; then
    PERM_RESULT=$(lark-cli drive permission.members create \
      --params "{\"token\":\"$BASE_TOKEN\",\"type\":\"bitable\"}" \
      --data "{\"member_type\":\"openid\",\"member_id\":\"$FALLBACK_ID\",\"perm\":\"full_access\"}" \
      --as bot 2>&1)
    if echo "$PERM_RESULT" | jq -e '.code == 0' >/dev/null 2>&1; then
      echo "  Granted full_access to current user"
    else
      echo "  Warning: Failed to grant permission." >&2
    fi
  else
    echo "  Warning: No user identity available. Bitable created with bot-only access." >&2
    echo "  You can grant yourself access later via the Bitable sharing settings." >&2
  fi
fi

# --- Step 3: Get default table ---
echo "[3/8] Getting default table..."
TABLE_RESULT=$(lark-cli base +table-list --base-token "$BASE_TOKEN" 2>&1)

if ! echo "$TABLE_RESULT" | jq -e '.ok == true' >/dev/null 2>&1; then
  echo "Error: Failed to list tables" >&2
  echo "$TABLE_RESULT" >&2
  exit 1
fi

TABLE_ID=$(echo "$TABLE_RESULT" | jq -r '.data.tables[0].id // .data.items[0].table_id // empty')
echo "  Table ID: $TABLE_ID"

# --- Step 4: Set up fields ---
echo "[4/8] Setting up fields..."

# Get default fields
FIELD_RESULT=$(lark-cli base +field-list --base-token "$BASE_TOKEN" --table-id "$TABLE_ID" 2>&1)
FIELDS_JSON=$(echo "$FIELD_RESULT" | jq '(.data.fields // .data.items)')

# Find the primary field (default name "文本" in Chinese Feishu) and repurpose it as repository
# The primary field cannot be deleted, so we rename it — it becomes the first column
PRIMARY_FIELD_ID=$(echo "$FIELDS_JSON" | jq -r '.[] | select(.name == "文本") | (.id // .field_id)' | head -1)
if [ -z "$PRIMARY_FIELD_ID" ]; then
  # Fallback: use the first text field as primary
  PRIMARY_FIELD_ID=$(echo "$FIELDS_JSON" | jq -r '.[] | select(.type == "text") | (.id // .field_id)' | head -1)
fi

echo "  Updating primary field ($PRIMARY_FIELD_ID) to repository..."
lark-cli base +field-update --base-token "$BASE_TOKEN" --table-id "$TABLE_ID" \
  --field-id "$PRIMARY_FIELD_ID" \
  --json '{"type":"text","name":"repository","description":"Repository name (owner/repo)"}' >/dev/null 2>&1 || true
echo "  Updated primary field: repository"

# Delete all other default fields (skip the primary field we just updated)
OTHER_FIELD_IDS=$(echo "$FIELDS_JSON" | jq -r --arg pid "$PRIMARY_FIELD_ID" '.[] | select((.id // .field_id) != $pid) | (.id // .field_id)')
for fid in $OTHER_FIELD_IDS; do
  DEL_RESULT=$(lark-cli base +field-delete --base-token "$BASE_TOKEN" --table-id "$TABLE_ID" --field-id "$fid" --yes 2>&1 || true)
  if echo "$DEL_RESULT" | jq -e '.ok == true' >/dev/null 2>&1; then
    echo "  Deleted default field: $fid"
  else
    echo "  Warning: Failed to delete field $fid" >&2
  fi
done

# Create the remaining 9 fields (order matters: commit_message first for 2nd column)
NEW_FIELDS=(
  '{"type":"text","name":"commit_message","description":"Commit message"}'
  '{"type":"text","name":"commit_hash","description":"Git commit SHA hash"}'
  '{"type":"text","name":"branch","description":"Git branch name"}'
  '{"type":"text","name":"author","description":"Commit author name"}'
  '{"type":"text","name":"author_email","style":{"type":"email"},"description":"Commit author email"}'
  '{"type":"datetime","name":"commit_time","style":{"format":"yyyy/MM/dd HH:mm"},"description":"Commit timestamp"}'
  '{"type":"number","name":"lines_added","style":{"type":"plain","precision":0},"description":"Lines added"}'
  '{"type":"number","name":"lines_deleted","style":{"type":"plain","precision":0},"description":"Lines deleted"}'
  '{"type":"number","name":"files_changed","style":{"type":"plain","precision":0},"description":"Files changed"}'
)

for field_json in "${NEW_FIELDS[@]}"; do
  FIELD_NAME=$(echo "$field_json" | jq -r '.name')
  RESULT=$(lark-cli base +field-create --base-token "$BASE_TOKEN" --table-id "$TABLE_ID" --json "$field_json" 2>&1)
  if echo "$RESULT" | jq -e '.ok == true' >/dev/null 2>&1; then
    echo "  Created field: $FIELD_NAME"
  else
    echo "  Warning: Failed to create field $FIELD_NAME" >&2
    echo "  $RESULT" >&2
  fi
done

# --- Step 5: Rename table ---
echo "[5/8] Renaming table..."
lark-cli base +table-update --base-token "$BASE_TOKEN" --table-id "$TABLE_ID" --name "Commit Records" >/dev/null 2>&1 || echo "  Warning: Failed to rename table" >&2
echo "  Table renamed to: Commit Records"

# --- Step 6: Configure view - field order ---
echo "[6/8] Configuring view field order..."
VIEW_RESULT=$(lark-cli base +view-list --base-token "$BASE_TOKEN" --table-id "$TABLE_ID" 2>&1)
VIEW_ID=$(echo "$VIEW_RESULT" | jq -r '.data.views[0].id // .data.items[0].view_id // empty' 2>/dev/null)

if [ -n "$VIEW_ID" ]; then
  # Get all field IDs in the desired order
  FIELD_LIST_RESULT=$(lark-cli base +field-list --base-token "$BASE_TOKEN" --table-id "$TABLE_ID" 2>&1)
  ALL_FIELDS_JSON=$(echo "$FIELD_LIST_RESULT" | jq '(.data.fields // .data.items)')

  # Build visible_fields array: repository, commit_message, commit_hash, branch, author, author_email, commit_time, lines_added, lines_deleted, files_changed
  FIELD_ORDER='["repository","commit_message","commit_hash","branch","author","author_email","commit_time","lines_added","lines_deleted","files_changed"]'
  VISIBLE_FIELDS=$(echo "$ALL_FIELDS_JSON" | jq --argjson order "$FIELD_ORDER" '
    [($order[] as $name | . as $fields | $fields[] | select(.name == $name) | (.id // .field_id))]
  ')

  VF_JSON=$(jq -n --argjson vf "$VISIBLE_FIELDS" '{"visible_fields": $vf}')
  SET_VF_RESULT=$(lark-cli base +view-set-visible-fields --base-token "$BASE_TOKEN" --table-id "$TABLE_ID" \
    --view-id "$VIEW_ID" --json "$VF_JSON" 2>&1)
  if echo "$SET_VF_RESULT" | jq -e '.ok == true' >/dev/null 2>&1; then
    echo "  Field order configured"
  else
    echo "  Warning: Failed to set field order" >&2
    echo "  $SET_VF_RESULT" >&2
  fi

  # --- Step 7: Configure view - group by repository ---
  echo "[7/8] Configuring group by repository..."
  REPO_FIELD_ID=$(echo "$ALL_FIELDS_JSON" | jq -r '.[] | select(.name == "repository") | (.id // .field_id)')
  GROUP_JSON=$(jq -n --arg fid "$REPO_FIELD_ID" '{"group_config": [{"field": $fid, "desc": false}]}')
  SET_GROUP_RESULT=$(lark-cli base +view-set-group --base-token "$BASE_TOKEN" --table-id "$TABLE_ID" \
    --view-id "$VIEW_ID" --json "$GROUP_JSON" 2>&1)
  if echo "$SET_GROUP_RESULT" | jq -e '.ok == true' >/dev/null 2>&1; then
    echo "  Grouped by repository"
  else
    echo "  Warning: Failed to set group" >&2
    echo "  $SET_GROUP_RESULT" >&2
  fi
else
  echo "  Warning: No view found, skipping view configuration" >&2
fi

# --- Step 8: Save config ---
echo "[8/8] Saving config..."
jq -n \
  --arg base_token "$BASE_TOKEN" \
  --arg table_id "$TABLE_ID" \
  --arg base_url "$BASE_URL" \
  '{
    base_token: $base_token,
    table_id: $table_id,
    base_url: $base_url
  }' > "$CONFIG_FILE"

echo ""
echo "=== Setup Complete ==="
echo "Config saved to: $CONFIG_FILE"
[ -n "$BASE_URL" ] && echo "Bitable URL: $BASE_URL"
