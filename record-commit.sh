#!/bin/bash
# record-commit.sh - Record git commit info to Feishu Bitable
# Usage: ./record-commit.sh [commit-hash]
# If no commit hash provided, uses HEAD

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SKILL_DIR/bitable-meta.json"
OFFSET_FILE="$SKILL_DIR/.last-offset"

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

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "Error: Not inside a git repository" >&2
  exit 1
}

normalize_repo_slug() {
  echo "$1" | sed -E 's|\.git$||' | sed -E 's|.*[:/]([^/]+/[^/]+)$|\1|'
}

normalize_model_name() {
  echo "$1" | sed -E 's|^[^/]+/||'
}

get_file_mtime() {
  stat -f '%m' "$1" 2>/dev/null || stat -c '%Y' "$1" 2>/dev/null || echo 0
}

sum_decimal() {
  awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN {printf "%.10f", a + b}'
}

round_currency() {
  jq -nr --arg value "$1" '$value | tonumber | . * 10000 | round / 10000'
}

get_codex_model_rates() {
  case "$1" in
    gpt-5.4)
      echo "2.50 0.25 15.00"
      ;;
    gpt-5.4-mini)
      echo "0.75 0.075 4.50"
      ;;
    gpt-5.4-nano)
      echo "0.20 0.02 1.25"
      ;;
    gpt-5.4-pro)
      echo "30.00 unsupported 180.00"
      ;;
    gpt-5.3-codex|gpt-5.2|gpt-5.2-codex)
      echo "1.75 0.175 14.00"
      ;;
    gpt-5.1|gpt-5.1-codex|gpt-5.1-codex-max|gpt-5|gpt-5-codex)
      echo "1.25 0.125 10.00"
      ;;
    gpt-5-mini|gpt-5.1-codex-mini)
      echo "0.25 0.025 2.00"
      ;;
    gpt-5-nano)
      echo "0.05 0.005 0.40"
      ;;
    codex-mini-latest)
      echo "1.50 0.375 6.00"
      ;;
    *)
      return 1
      ;;
  esac
}

find_latest_claude_transcript() {
  local repo_root="$1"
  local project_dir_name
  local claude_project_dir

  project_dir_name=$(echo "$repo_root" | tr '/' '-')
  claude_project_dir="$HOME/.claude/projects/$project_dir_name"

  if [ -d "$claude_project_dir" ]; then
    ls -t "$claude_project_dir"/*.jsonl 2>/dev/null | head -1 || true
  fi
}

find_best_codex_session() {
  local repo_root="$1"
  local repo_slug="$2"
  local best_path=""
  local best_score=0
  local best_mtime=0

  [ -d "$HOME/.codex/sessions" ] || return 0

  while IFS= read -r path; do
    [ -n "$path" ] || continue

    local meta
    local cwd
    local git_url
    local git_slug=""
    local score=0
    local mtime

    meta=$(head -n 1 "$path" 2>/dev/null | jq -c 'select(.type == "session_meta") | .payload' 2>/dev/null || true)
    [ -n "$meta" ] || continue

    cwd=$(echo "$meta" | jq -r '.cwd // empty' 2>/dev/null || true)
    git_url=$(echo "$meta" | jq -r '.git.repository_url // empty' 2>/dev/null || true)

    if [ -n "$cwd" ]; then
      if [ "$cwd" = "$repo_root" ]; then
        score=$((score + 100))
      elif [[ "$cwd" == "$repo_root/"* ]]; then
        score=$((score + 80))
      fi
    fi

    if [ -n "$repo_slug" ] && [ -n "$git_url" ]; then
      git_slug=$(normalize_repo_slug "$git_url")
      if [ "$git_slug" = "$repo_slug" ]; then
        score=$((score + 200))
      fi
    fi

    [ "$score" -gt 0 ] || continue

    mtime=$(get_file_mtime "$path")
    if [ "$score" -gt "$best_score" ] || { [ "$score" -eq "$best_score" ] && [ "$mtime" -gt "$best_mtime" ]; }; then
      best_path="$path"
      best_score="$score"
      best_mtime="$mtime"
    fi
  done < <(find "$HOME/.codex/sessions" -type f -name '*.jsonl' 2>/dev/null)

  printf '%s' "$best_path"
}

save_offset_state() {
  local provider="$1"
  local source_path="$2"
  local offset="$3"
  local current_model="${4:-}"
  local totals_json="${5:-null}"

  jq -n \
    --arg provider "$provider" \
    --arg source_path "$source_path" \
    --arg current_model "$current_model" \
    --argjson offset "$offset" \
    --argjson totals "$totals_json" \
    '{
      provider: $provider,
      source_path: $source_path,
      offset: $offset
    }
    | if $current_model != "" then .current_model = $current_model else . end
    | if $totals != null then .totals = $totals else . end' > "$OFFSET_FILE"
}

REPO_ROOT=$(git rev-parse --show-toplevel)
COMMIT_HASH="${1:-HEAD}"

FULL_HASH=$(git log -1 --format='%H' "$COMMIT_HASH")
AUTHOR=$(git log -1 --format='%an' "$COMMIT_HASH")
AUTHOR_EMAIL=$(git log -1 --format='%ae' "$COMMIT_HASH")
COMMIT_TIME=$(git log -1 --format='%ai' "$COMMIT_HASH" | sed 's/ [+-][0-9][0-9]*$//')
COMMIT_MESSAGE=$(git log -1 --format='%s' "$COMMIT_HASH")
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "detached")

REMOTE_URL=$(git remote get-url origin 2>/dev/null || echo "")
REPO_SLUG=""
if [ -n "$REMOTE_URL" ]; then
  REPO_SLUG=$(normalize_repo_slug "$REMOTE_URL")
  REPO_NAME="$REPO_SLUG"
else
  REPO_NAME=$(basename "$REPO_ROOT")
fi

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

SESSION_COST=""
SESSION_INPUT_TOKENS=""
SESSION_OUTPUT_TOKENS=""
SESSION_MODEL=""

SAVED_PROVIDER=""
SAVED_SOURCE=""
SAVED_OFFSET=0
SAVED_CURRENT_MODEL=""
SAVED_TOTALS="null"

if [ -f "$OFFSET_FILE" ]; then
  SAVED_PROVIDER=$(jq -r 'if .provider then .provider elif has("transcript") then "claude" else empty end' "$OFFSET_FILE" 2>/dev/null || true)
  SAVED_SOURCE=$(jq -r '.source_path // .transcript // empty' "$OFFSET_FILE" 2>/dev/null || true)
  SAVED_OFFSET=$(jq -r '.offset // 0' "$OFFSET_FILE" 2>/dev/null || true)
  SAVED_CURRENT_MODEL=$(jq -r '.current_model // empty' "$OFFSET_FILE" 2>/dev/null || true)
  SAVED_TOTALS=$(jq -c '.totals // null' "$OFFSET_FILE" 2>/dev/null || echo "null")
fi

HOOK_INPUT=""
if [ ! -t 0 ]; then
  HOOK_INPUT=$(cat 2>/dev/null || true)
fi

HOOK_TRANSCRIPT_PATH=""
if [ -n "$HOOK_INPUT" ]; then
  HOOK_TRANSCRIPT_PATH=$(echo "$HOOK_INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || true)
fi

SESSION_PROVIDER=""
SESSION_SOURCE=""

if [ -n "$HOOK_TRANSCRIPT_PATH" ] && [ -f "$HOOK_TRANSCRIPT_PATH" ]; then
  SESSION_PROVIDER="claude"
  SESSION_SOURCE="$HOOK_TRANSCRIPT_PATH"
else
  CLAUDE_TRANSCRIPT_PATH=$(find_latest_claude_transcript "$REPO_ROOT")
  CODEX_SESSION_PATH=$(find_best_codex_session "$REPO_ROOT" "$REPO_SLUG")
  CLAUDE_MTIME=0
  CODEX_MTIME=0

  if [ -n "$CLAUDE_TRANSCRIPT_PATH" ] && [ -f "$CLAUDE_TRANSCRIPT_PATH" ]; then
    CLAUDE_MTIME=$(get_file_mtime "$CLAUDE_TRANSCRIPT_PATH")
  fi

  if [ -n "$CODEX_SESSION_PATH" ] && [ -f "$CODEX_SESSION_PATH" ]; then
    CODEX_MTIME=$(get_file_mtime "$CODEX_SESSION_PATH")
  fi

  if [ "$CODEX_MTIME" -gt "$CLAUDE_MTIME" ]; then
    SESSION_PROVIDER="codex"
    SESSION_SOURCE="$CODEX_SESSION_PATH"
  elif [ "$CLAUDE_MTIME" -gt 0 ]; then
    SESSION_PROVIDER="claude"
    SESSION_SOURCE="$CLAUDE_TRANSCRIPT_PATH"
  elif [ "$CODEX_MTIME" -gt 0 ]; then
    SESSION_PROVIDER="codex"
    SESSION_SOURCE="$CODEX_SESSION_PATH"
  fi
fi

if [ "$SESSION_PROVIDER" = "claude" ] && [ -n "$SESSION_SOURCE" ] && [ -f "$SESSION_SOURCE" ]; then
  TOTAL_LINES=$(wc -l < "$SESSION_SOURCE" | tr -d ' ')
  START_LINE=1

  if [ "$SAVED_PROVIDER" = "claude" ] && [ "$SAVED_SOURCE" = "$SESSION_SOURCE" ] && [ "$SAVED_OFFSET" -gt 0 ] 2>/dev/null; then
    START_LINE=$((SAVED_OFFSET + 1))
  fi

  if [ "$START_LINE" -le "$TOTAL_LINES" ]; then
    CLAUDE_STATS=$(tail -n +"$START_LINE" "$SESSION_SOURCE" | jq -s '
      [.[] | select(.message.usage != null)]
      | group_by(.message.id)
      | map(last)
      | reduce .[] as $e (
          {input: 0, output: 0, cost: 0, last_model: ""};
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
          | .last_model = $m
        )
    ' 2>/dev/null || true)

    if [ -n "$CLAUDE_STATS" ]; then
      SESSION_INPUT_TOKENS=$(echo "$CLAUDE_STATS" | jq -r '.input')
      SESSION_OUTPUT_TOKENS=$(echo "$CLAUDE_STATS" | jq -r '.output')
      if [ "$SESSION_INPUT_TOKENS" -gt 0 ] || [ "$SESSION_OUTPUT_TOKENS" -gt 0 ]; then
        SESSION_COST=$(echo "$CLAUDE_STATS" | jq -r '.cost | . * 10000 | round / 10000')
        SESSION_MODEL=$(echo "$CLAUDE_STATS" | jq -r '.last_model // empty')
      else
        SESSION_INPUT_TOKENS=""
        SESSION_OUTPUT_TOKENS=""
      fi
    fi
  fi

  save_offset_state "claude" "$SESSION_SOURCE" "$TOTAL_LINES"
fi

if [ "$SESSION_PROVIDER" = "codex" ] && [ -n "$SESSION_SOURCE" ] && [ -f "$SESSION_SOURCE" ]; then
  TOTAL_LINES=$(wc -l < "$SESSION_SOURCE" | tr -d ' ')
  START_LINE=1
  INITIAL_MODEL=""
  INITIAL_TOTALS="null"

  if [ "$SAVED_PROVIDER" = "codex" ] && [ "$SAVED_SOURCE" = "$SESSION_SOURCE" ] && [ "$SAVED_OFFSET" -gt 0 ] 2>/dev/null; then
    START_LINE=$((SAVED_OFFSET + 1))
    INITIAL_MODEL="$SAVED_CURRENT_MODEL"
    INITIAL_TOTALS="$SAVED_TOTALS"
  fi

  CODEX_STATS=$(jq -n \
    --arg initial_model "$(normalize_model_name "$INITIAL_MODEL")" \
    --argjson prev_totals "$INITIAL_TOTALS" \
    '{
      current_model: $initial_model,
      prev_totals: $prev_totals,
      last_totals: $prev_totals,
      last_model: "",
      models: {}
    }')

  if [ "$START_LINE" -le "$TOTAL_LINES" ]; then
    CODEX_STATS=$(tail -n +"$START_LINE" "$SESSION_SOURCE" | jq -s \
      --arg initial_model "$(normalize_model_name "$INITIAL_MODEL")" \
      --argjson prev_totals "$INITIAL_TOTALS" '
      def norm_model:
        if . == null or . == "" then ""
        else tostring | sub("^[^/]+/"; "") end;

      def totals_for($info):
        {
          input_tokens: ($info.total_token_usage.input_tokens // 0),
          cached_input_tokens: ($info.total_token_usage.cached_input_tokens // 0),
          output_tokens: ($info.total_token_usage.output_tokens // 0),
          reasoning_output_tokens: ($info.total_token_usage.reasoning_output_tokens // 0),
          total_tokens: ($info.total_token_usage.total_tokens // 0)
        };

      reduce .[] as $e (
        {
          current_model: ($initial_model | norm_model),
          prev_totals: $prev_totals,
          last_totals: $prev_totals,
          last_model: "",
          models: {}
        };
        if $e.type == "turn_context" then
          .current_model = (($e.payload.model // .current_model) | norm_model)
        elif $e.type == "event_msg" and $e.payload.type == "token_count" and ($e.payload.info != null) then
          (totals_for($e.payload.info)) as $totals
          | .last_totals = $totals
          | if .prev_totals == null then
              .prev_totals = $totals
            elif .prev_totals == $totals then
              .
            else
              ($totals.input_tokens - .prev_totals.input_tokens) as $d_in
              | ($totals.cached_input_tokens - .prev_totals.cached_input_tokens) as $d_cached
              | ($totals.output_tokens - .prev_totals.output_tokens) as $d_out
              | ($totals.reasoning_output_tokens - .prev_totals.reasoning_output_tokens) as $d_reason
              | .prev_totals = $totals
              | if (.current_model | length) == 0 then
                  .
                else
                  .models[.current_model] = (.models[.current_model] // {
                    input_tokens: 0,
                    cached_input_tokens: 0,
                    output_tokens: 0,
                    reasoning_output_tokens: 0
                  })
                  | .models[.current_model].input_tokens += (if $d_in > 0 then $d_in else 0 end)
                  | .models[.current_model].cached_input_tokens += (if $d_cached > 0 then $d_cached else 0 end)
                  | .models[.current_model].output_tokens += (if $d_out > 0 then $d_out else 0 end)
                  | .models[.current_model].reasoning_output_tokens += (if $d_reason > 0 then $d_reason else 0 end)
                  | .last_model = .current_model
                end
            end
        else
          .
        end
      )
      | .session_input_tokens = ([.models[]? | .input_tokens] | add // 0)
      | .session_output_tokens = ([.models[]? | .output_tokens] | add // 0)
      ' 2>/dev/null || true)
  fi

  CODEX_INPUT_TOKENS=$(echo "$CODEX_STATS" | jq -r '.session_input_tokens // 0')
  CODEX_OUTPUT_TOKENS=$(echo "$CODEX_STATS" | jq -r '.session_output_tokens // 0')

  if [ "$CODEX_INPUT_TOKENS" -gt 0 ] || [ "$CODEX_OUTPUT_TOKENS" -gt 0 ]; then
    UNKNOWN_MODELS=()
    TOTAL_SESSION_COST="0"

    # OpenAI reports cached_input_tokens as a subset of input_tokens.
    while IFS=$'\t' read -r model input_tokens cached_input_tokens output_tokens; do
      [ -n "$model" ] || continue

      if ! RATES=$(get_codex_model_rates "$model"); then
        UNKNOWN_MODELS+=("$model")
        continue
      fi

      read -r INPUT_RATE CACHED_RATE OUTPUT_RATE <<< "$RATES"

      if [ "$CACHED_RATE" = "unsupported" ] && [ "$cached_input_tokens" -gt 0 ]; then
        UNKNOWN_MODELS+=("$model")
        continue
      fi

      UNCACHED_INPUT_TOKENS=$((input_tokens - cached_input_tokens))
      if [ "$UNCACHED_INPUT_TOKENS" -lt 0 ]; then
        UNCACHED_INPUT_TOKENS=0
      fi

      MODEL_COST=$(awk \
        -v input_tokens="$UNCACHED_INPUT_TOKENS" \
        -v cached_tokens="$cached_input_tokens" \
        -v output_tokens="$output_tokens" \
        -v input_rate="$INPUT_RATE" \
        -v cached_rate="$CACHED_RATE" \
        -v output_rate="$OUTPUT_RATE" \
        'BEGIN {printf "%.10f", ((input_tokens * input_rate) + (cached_tokens * cached_rate) + (output_tokens * output_rate)) / 1000000}')

      TOTAL_SESSION_COST=$(sum_decimal "$TOTAL_SESSION_COST" "$MODEL_COST")
    done < <(echo "$CODEX_STATS" | jq -r '.models | to_entries[]? | [.key, .value.input_tokens, .value.cached_input_tokens, .value.output_tokens] | @tsv')

    if [ "${#UNKNOWN_MODELS[@]}" -eq 0 ]; then
      SESSION_COST=$(round_currency "$TOTAL_SESSION_COST")
    else
      echo "Warning: Skipping session_cost because pricing is unknown for model(s): ${UNKNOWN_MODELS[*]}" >&2
    fi

    SESSION_INPUT_TOKENS="$CODEX_INPUT_TOKENS"
    SESSION_OUTPUT_TOKENS="$CODEX_OUTPUT_TOKENS"
    SESSION_MODEL=$(echo "$CODEX_STATS" | jq -r '.last_model // empty')
  fi

  CURRENT_MODEL_TO_SAVE=$(echo "$CODEX_STATS" | jq -r '.current_model // empty')
  LAST_TOTALS_TO_SAVE=$(echo "$CODEX_STATS" | jq -c '.last_totals // null')
  save_offset_state "codex" "$SESSION_SOURCE" "$TOTAL_LINES" "$CURRENT_MODEL_TO_SAVE" "$LAST_TOTALS_TO_SAVE"
fi

HAS_SESSION_MODEL=false
FIELD_LIST_RESULT=$(lark-cli base +field-list --base-token "$BASE_TOKEN" --table-id "$TABLE_ID" 2>/dev/null || true)
if echo "$FIELD_LIST_RESULT" | jq -e '.ok == true' >/dev/null 2>&1; then
  if echo "$FIELD_LIST_RESULT" | jq -e '(.data.fields // .data.items) | map(.name) | index("session_model") != null' >/dev/null 2>&1; then
    HAS_SESSION_MODEL=true
  fi
fi

JSON_PAYLOAD=$(jq -n \
  --arg hash "$FULL_HASH" \
  --arg repo "$REPO_NAME" \
  --arg branch "$BRANCH" \
  --arg author "$AUTHOR" \
  --arg email "$AUTHOR_EMAIL" \
  --arg time "$COMMIT_TIME" \
  --arg msg "$COMMIT_MESSAGE" \
  --arg model "$SESSION_MODEL" \
  --argjson added "$LINES_ADDED" \
  --argjson deleted "$LINES_DELETED" \
  --argjson files "$FILES_CHANGED" \
  --arg s_cost "$SESSION_COST" \
  --arg s_in "$SESSION_INPUT_TOKENS" \
  --arg s_out "$SESSION_OUTPUT_TOKENS" \
  --argjson has_session_model "$HAS_SESSION_MODEL" \
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
  | if $has_session_model and $model != "" then .session_model = $model else . end')

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
