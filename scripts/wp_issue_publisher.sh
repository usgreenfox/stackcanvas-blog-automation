#!/usr/bin/env bash
set -euo pipefail

basic="$(printf '%s:%s' "$WP_USER" "$WP_APP_PASSWORD" | base64)"

# fetch issue
curl -s -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/${GITHUB_REPOSITORY}/issues/${ISSUE}" > issue.json

title=$(jq -r '.title' issue.json)
body=$(jq -r '.body // ""' issue.json)
wp_post_id=$(printf '%s\n' "$body" | awk -F: '/^WP_POST_ID/ {gsub(/ /,"",$2); print $2}' | head -n1)

get_issue_comments() {
  curl -s -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${GITHUB_REPOSITORY}/issues/${ISSUE}/comments?per_page=1&sort=created&direction=desc"
}

update_issue_body() {
  local newbody="$1"
  curl -s -X PATCH -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" \
    -d "$(jq -n --arg body "$newbody" '{body:$body}')" \
    "https://api.github.com/repos/${GITHUB_REPOSITORY}/issues/${ISSUE}" > /dev/null
}

comment_issue() {
  local text="$1"
  curl -s -X POST -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" \
    -d "$(jq -n --arg body "$text" '{body:$body}')" \
    "https://api.github.com/repos/${GITHUB_REPOSITORY}/issues/${ISSUE}/comments" > /dev/null
}

set_labels() {
  local add="$1" remove="$2"
  if [ -n "$add" ]; then
    curl -s -X POST -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" \
      -d "$(jq -n --arg add "$add" '{labels:[$add]}')" \
      "https://api.github.com/repos/${GITHUB_REPOSITORY}/issues/${ISSUE}/labels" > /dev/null
  fi
  if [ -n "$remove" ]; then
    curl -s -X DELETE -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" \
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

  prompt=$(
cat <<'PROMPT'
You are assisting with an issue-driven workflow for an IT technical blog. Based on the issue TITLE and BODY below, produce an SEO-friendly article in Japanese, suitable for publishing on WordPress via the REST API. Keep it concise and practical. Output must be raw HTML only (no markdown). The content must include exactly these manual insertion placeholders and you must NOT delete or move them:

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

  content=$( 
    curl -s https://api.openai.com/v1/chat/completions \
      -H "Authorization: Bearer $OPENAI_API_KEY" \
      -H "Content-Type: application/json" \
      -d "$(jq -n \
        --arg model "gpt-4o-mini" \
        --arg sys "You are a helpful assistant." \
        --arg usr "$(cat prompt.txt)" \
        '{model:$model,messages:[{role:"system",content:$sys},{role:"user",content:$usr}],temperature:0.3}')" \
      | jq -r '.choices[0].message.content'
  )

  post_id=$( 
    curl -s -X POST "$WP_URL/wp-json/wp/v2/posts" \
      -H "Authorization: Basic $basic" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg title "$title" --arg content "$content" --arg status "draft" '{title:$title,content:$content,status:$status}')" \
      | jq -r '.id'
  )

  newbody="$body"
  newbody="$newbody"$'\n''WP_POST_ID: '$post_id''
  update_issue_body "$newbody"

  comment_issue "draft created: WP_POST_ID=$post_id"
  set_labels drafted approved

elif [ "$ACTION" = "publish_ok" ]; then
  if [ -z "$wp_post_id" ]; then
    echo "No WP_POST_ID in issue body."
    exit 1
  fi

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
print(json.dumps({"date_jst": dt.isoformat(timespec="seconds"), "date_gmt": dt.astimezone(timezone.utc).isoformat(timespec="seconds")}))
PY

  date_jst=$(jq -r '.date_jst' schedule.json)
  date_gmt=$(jq -r '.date_gmt' schedule.json)

  curl -s -X PUT "$WP_URL/wp-json/wp/v2/posts/$wp_post_id" \
    -H "Authorization: Basic $basic" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg status "future" --arg date "$date_jst" --arg date_gmt "$date_gmt" '{status:$status,date:$date,date_gmt:$date_gmt}')" > /dev/null

  comment_issue "scheduled for ${date_jst} JST"
  set_labels scheduled publish_ok

else
  echo "ACTION=$ACTION not supported in script"
  exit 1
fi
