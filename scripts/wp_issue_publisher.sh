#!/usr/bin/env bash
set -euo pipefail

basic="$(printf '%s:%s' "$WP_USER" "$WP_APP_PASSWORD" | base64)"

echo "Fetching issue..."

issue_response=$(curl -s -w "\n%{http_code}" \
  -H "Authorization: Bearer $GH_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/${GITHUB_REPOSITORY}/issues/${ISSUE}")

issue_body=$(echo "$issue_response" | sed '$d')
issue_status=$(echo "$issue_response" | tail -n1)

if [ "$issue_status" != "200" ]; then
  echo "GitHub API error:"
  echo "$issue_body"
  exit 1
fi

echo "$issue_body" > issue.json

title=$(jq -r '.title' issue.json)
body=$(jq -r '.body // ""' issue.json)
wp_post_id=$(printf '%s\n' "$body" | awk -F: '/^WP_POST_ID/ {gsub(/ /,"",$2); print $2}' | head -n1)

update_issue_body() {
  local newbody="$1"
  curl -s -X PATCH \
    -H "Authorization: Bearer $GH_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -d "$(jq -n --arg body "$newbody" '{body:$body}')" \
    "https://api.github.com/repos/${GITHUB_REPOSITORY}/issues/${ISSUE}" > /dev/null
}

comment_issue() {
  local text="$1"
  curl -s -X POST \
    -H "Authorization: Bearer $GH_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -d "$(jq -n --arg body "$text" '{body:$body}')" \
    "https://api.github.com/repos/${GITHUB_REPOSITORY}/issues/${ISSUE}/comments" > /dev/null
}

set_labels() {
  local add="$1" remove="$2"

  if [ -n "$add" ]; then
    curl -s -X POST \
      -H "Authorization: Bearer $GH_TOKEN" \
      -H "Accept: application/vnd.github+json" \
      -d "$(jq -n --arg add "$add" '{labels:[$add]}')" \
      "https://api.github.com/repos/${GITHUB_REPOSITORY}/issues/${ISSUE}/labels" > /dev/null
  fi

  if [ -n "$remove" ]; then
    curl -s -X DELETE \
      -H "Authorization: Bearer $GH_TOKEN" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/${GITHUB_REPOSITORY}/issues/${ISSUE}/labels/$remove" > /dev/null || true
  fi
}

if [ "$ACTION" = "approved" ]; then

  if [ -n "$wp_post_id" ]; then
    echo "Already has WP_POST_ID=$wp_post_id"
    exit 0
  fi

  if [ -z "${OPENAI_API_KEY:-}" ]; then
    echo "OPENAI_API_KEY not set"
    exit 1
  fi

  echo "Generating article via OpenAI..."

  prompt=$(
cat <<'PROMPT'
You are assisting with an issue-driven workflow for an IT technical blog. Based on the issue TITLE and BODY below, produce an SEO-friendly article in Japanese, suitable for publishing on WordPress via the REST API.

Output must be raw HTML only (no markdown).

The content must include exactly these placeholders and must NOT remove or move them:

<!-- MANUAL_1_START --><!-- MANUAL_1_END -->
<!-- MANUAL_2_START --><!-- MANUAL_2_END -->
<!-- MANUAL_3_START --><!-- MANUAL_3_END -->

TITLE:
PROMPT
)

  echo "$prompt" > prompt.txt
  echo "$title" >> prompt.txt
  echo "BODY:" >> prompt.txt
  echo "$body" >> prompt.txt

  openai_response=$(curl -s -w "\n%{http_code}" https://api.openai.com/v1/responses \
    -H "Authorization: Bearer $OPENAI_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$(jq -n \
      --arg model "gpt-4.1-mini" \
      --arg input "$(cat prompt.txt)" \
      '{model:$model,input:$input,temperature:0.3}')")

  openai_body=$(echo "$openai_response" | sed '$d')
  openai_status=$(echo "$openai_response" | tail -n1)

  if [ "$openai_status" != "200" ]; then
    echo "OpenAI API error:"
    echo "$openai_body"
    exit 1
  fi

  content=$(echo "$openai_body" | jq -r '.output[0].content[0].text')

  echo "Creating WordPress draft..."

  # wp_response=$(curl -s -w "\n%{http_code}" \
  #   -X POST "$WP_URL/wp-json/wp/v2/posts" \
  #   --user "$WP_USER:$WP_APP_PASSWORD" \
  #   -H "Content-Type: application/json" \
  #   -d "$(jq -n \
  #     --arg title "$title" \
  #     --arg content "$content" \
  #     --arg status "draft" \
  #     '{title:$title,content:$content,status:$status}')")

# まず到達性チェック（wp-jsonがリダイレクトしてないか確認）
if [ "${DEBUG_WP:-}" = "1" ]; then
  curl -sv -I "$WP_URL/wp-json/" 1>/dev/null 2>&1 | sed -e 's/^/[wp-json] /' >&2 || true
fi

# bodyをファイルに退避して、curlの出力を混ぜない
wp_body_file="$(mktemp)"
wp_status=$(
  curl -sS -o "$wp_body_file" -w "%{http_code}" \
    -X POST "$WP_URL/wp-json/wp/v2/posts" \
    --user "$WP_USER:$WP_APP_PASSWORD" \
    -H "User-Agent: stackcanvas-bot/1.0" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    -d "$(jq -n \
      --arg title "$title" \
      --arg content "$content" \
      --arg status "draft" \
      '{title:$title,content:$content,status:$status}')"
)

wp_body="$(cat "$wp_body_file")"
rm -f "$wp_body_file"

# 失敗時だけレスポンスを見やすく出す
if [ "$wp_status" != "201" ]; then
  echo "WordPress API error: status=$wp_status"
  echo "$wp_body"
  exit 1
fi
  post_id=$(echo "$wp_body" | jq -r '.id')

  newbody="$body"$'\n'"WP_POST_ID: $post_id"
  update_issue_body "$newbody"

  comment_issue "Draft created: WP_POST_ID=$post_id"
  set_labels drafted approved

elif [ "$ACTION" = "needs_changes" ]; then

  if [ -z "$wp_post_id" ]; then
    echo "WP_POST_ID not found. Cannot update."
    exit 1
  fi

  if [ -z "${OPENAI_API_KEY:-}" ]; then
    echo "OPENAI_API_KEY not set"
    exit 1
  fi

  echo "Regenerating article via OpenAI (update mode)..."

  prompt=$(
cat <<'PROMPT'
You are assisting with an issue-driven workflow for an IT technical blog.
Regenerate the article based on the TITLE and BODY below.

Output must be raw HTML only (no markdown).

The content must include exactly these placeholders and must NOT remove or move them:

<!-- MANUAL_1_START --><!-- MANUAL_1_END -->
<!-- MANUAL_2_START --><!-- MANUAL_2_END -->
<!-- MANUAL_3_START --><!-- MANUAL_3_END -->

TITLE:
PROMPT
)

  echo "$prompt" > prompt.txt
  echo "$title" >> prompt.txt
  echo "BODY:" >> prompt.txt
  echo "$body" >> prompt.txt

  openai_response=$(curl -s -w "\n%{http_code}" https://api.openai.com/v1/responses \
    -H "Authorization: Bearer $OPENAI_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$(jq -n \
      --arg model "gpt-4.1-mini" \
      --arg input "$(cat prompt.txt)" \
      '{model:$model,input:$input,temperature:0.3}')")

  openai_body=$(echo "$openai_response" | sed '$d')
  openai_status=$(echo "$openai_response" | tail -n1)

  if [ "$openai_status" != "200" ]; then
    echo "OpenAI API error:"
    echo "$openai_body"
    exit 1
  fi

  content=$(echo "$openai_body" | jq -r '.output[0].content[0].text')

  echo "Updating existing WordPress draft (ID=$wp_post_id)..."

  wp_body_file="$(mktemp)"
  wp_status=$(
    curl -sS -o "$wp_body_file" -w "%{http_code}" \
      -X POST "$WP_URL/wp-json/wp/v2/posts/$wp_post_id" \
      --user "$WP_USER:$WP_APP_PASSWORD" \
      -H "User-Agent: stackcanvas-bot/1.0" \
      -H "Accept: application/json" \
      -H "Content-Type: application/json" \
      -d "$(jq -n \
        --arg title "$title" \
        --arg content "$content" \
        '{title:$title,content:$content}')"
  )

  wp_body="$(cat "$wp_body_file")"
  rm -f "$wp_body_file"

  if [ "$wp_status" != "200" ]; then
    echo "WordPress update error: status=$wp_status"
    echo "$wp_body"
    exit 1
  fi

  comment_issue "Draft updated: WP_POST_ID=$wp_post_id"
  set_labels drafted needs_changes
  
elif [ "$ACTION" = "publish_ok" ]; then

  if [ -z "$wp_post_id" ]; then
    echo "No WP_POST_ID in issue body."
    exit 1
  fi

  echo "Scheduling publish..."

  python - <<'PY' > schedule.json
from datetime import datetime, time, timedelta, timezone
import json
JST = timezone(timedelta(hours=9))
now = datetime.now(JST)
target_time = time(19, 0)

def next_occurrence(now):
    for offset in range(8):
        d = now.date() + timedelta(days=offset)
        dt = datetime.combine(d, target_time, JST)
        if dt <= now:
            continue
        if dt.weekday() in (1, 4):
            return dt
    return now + timedelta(days=1)

dt = next_occurrence(now)
print(json.dumps({
    "date_jst": dt.isoformat(timespec="seconds"),
    "date_gmt": dt.astimezone(timezone.utc).isoformat(timespec="seconds")
}))
PY

  date_jst=$(jq -r '.date_jst' schedule.json)
  date_gmt=$(jq -r '.date_gmt' schedule.json)

  curl -s -X POST "$WP_URL/wp-json/wp/v2/posts/$wp_post_id" \
    --user "$WP_USER:$WP_APP_PASSWORD" \
    -H "User-Agent: stackcanvas-bot/1.0" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    -d "$(jq -n \
      --arg status "future" \
      --arg date "$date_jst" \
      --arg date_gmt "$date_gmt" \
      '{status:$status,date:$date,date_gmt:$date_gmt}')" > /dev/null
      
  comment_issue "Scheduled for ${date_jst} JST"
  set_labels scheduled publish_ok

else
  echo "ACTION=$ACTION not supported"
  exit 1
fi

echo "Done."
