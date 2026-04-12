#!/bin/bash
# attach.sh - Attach to an existing Feishu Bitable by URL
# Usage: ./attach.sh <bitable-url>
# URL format: https://my.feishu.cn/base/<base_token>?table=<table_id>&view=<view_id>

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SKILL_DIR/bitable-meta.json"
OFFSET_FILE="$SKILL_DIR/.last-offset"

URL="${1:-}"
if [ -z "$URL" ]; then
  echo "Usage: bash attach.sh <bitable-url>" >&2
  echo "Example: bash attach.sh 'https://my.feishu.cn/base/xxx?table=yyy&view=zzz'" >&2
  exit 1
fi

# --- Parse URL ---
# Extract base_token from path: /base/<base_token>
BASE_TOKEN=$(echo "$URL" | sed -E 's|.*[/]base[/]([^/?]+).*|\1|')
if [ -z "$BASE_TOKEN" ] || [ "$BASE_TOKEN" = "$URL" ]; then
  echo "Error: Cannot extract base_token from URL" >&2
  echo "Expected format: https://my.feishu.cn/base/<base_token>?table=<table_id>" >&2
  exit 1
fi

# Extract table_id from query string: table=<table_id>
TABLE_ID=$(echo "$URL" | sed -E 's|.*[?&]table=([^&]+).*|\1|')
if [ -z "$TABLE_ID" ] || [ "$TABLE_ID" = "$URL" ]; then
  echo "Error: Cannot extract table_id from URL (missing ?table= parameter)" >&2
  exit 1
fi

# Build base_url (strip query string)
BASE_URL=$(echo "$URL" | sed -E 's|[?].*||')

echo "=== Attach to Existing Bitable ==="
echo "  Base Token: $BASE_TOKEN"
echo "  Table ID:   $TABLE_ID"
echo "  Base URL:   $BASE_URL"
echo ""

# --- Verify connectivity ---
echo "Verifying connection..."
VERIFY_RESULT=$(lark-cli base +table-list --base-token "$BASE_TOKEN" 2>&1)
if echo "$VERIFY_RESULT" | jq -e '.ok == true' >/dev/null 2>&1; then
  TABLE_NAME=$(echo "$VERIFY_RESULT" | jq -r --arg tid "$TABLE_ID" '
    (.data.tables // .data.items)[] | select((.id // .table_id) == $tid) | .name // "unknown"
  ' 2>/dev/null || echo "unknown")
  echo "  Connected! Table name: $TABLE_NAME"
else
  echo "Error: Cannot access this Bitable. Check the URL and permissions." >&2
  echo "$VERIFY_RESULT" >&2
  exit 1
fi

# --- Save config ---
jq -n \
  --arg base_token "$BASE_TOKEN" \
  --arg table_id "$TABLE_ID" \
  --arg base_url "$BASE_URL" \
  '{
    base_token: $base_token,
    table_id: $table_id,
    base_url: $base_url
  }' > "$CONFIG_FILE"

# Clear offset (new table has no history)
rm -f "$OFFSET_FILE"

echo ""
echo "=== Attached ==="
echo "Config saved to: $CONFIG_FILE"
echo "Bitable URL: $BASE_URL"
