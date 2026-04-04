#!/usr/bin/env bash
# ============================================================
# One-time Telegram workflow deploy.
# Run this ONCE. After publishing in n8n, never run again
# unless you intentionally want to redeploy Telegram.
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREDS_FILE="$SCRIPT_DIR/credentials.local.json"
TELEGRAM_WORKFLOW="$SCRIPT_DIR/telegram-assistant.json"

N8N_BASE_URL="https://fullyo.app.n8n.cloud"
N8N_API_KEY=$(jq -r '.n8n.apiKey' "$CREDS_FILE")
FB_ACCESS_TOKEN=$(jq -r '.facebook.pages.skyhouse_sayulita.accessToken' "$CREDS_FILE")
ANTHROPIC_API_KEY=$(jq -r '.anthropic.apiKey' "$CREDS_FILE")
BUNNY_SKYHOUSE_KEY=$(jq -r '.bunny.skyhouse.storageApiKey' "$CREDS_FILE")
BUNNY_SAYULITA_KEY=$(jq -r '.bunny.sayulita_shared.storageApiKey' "$CREDS_FILE")
TELEGRAM_BOT_TOKEN=$(jq -r '.telegram.botToken' "$CREDS_FILE")

api() {
  local method="$1" path="$2" data="${3:-}"
  if [ -n "$data" ]; then
    curl -s -X "$method" "$N8N_BASE_URL/api/v1$path" \
      -H "X-N8N-API-KEY: $N8N_API_KEY" -H "Content-Type: application/json" -d "$data"
  else
    curl -s -X "$method" "$N8N_BASE_URL/api/v1$path" -H "X-N8N-API-KEY: $N8N_API_KEY"
  fi
}

echo "=== Telegram Workflow — One-Time Deploy ==="

# Get or create credentials
EXISTING_CREDS=$(api GET /credentials)
get_cred_id() {
  echo "$EXISTING_CREDS" | jq -r --arg n "$1" '.data[] | select(.name == $n) | .id // empty' | head -1
}

CRED_ID_FACEBOOK=$(get_cred_id "SkyHouse Facebook Token")
CRED_ID_ANTHROPIC=$(get_cred_id "Anthropic API")
CRED_ID_BUNNY_SKYHOUSE=$(get_cred_id "Bunny SkyHouse Storage")
CRED_ID_BUNNY_SAYULITA=$(get_cred_id "Bunny Sayulita Shared")
CRED_ID_TELEGRAM=$(get_cred_id "Fullyo Telegram Bot")

echo "Using existing credentials:"
echo "  Facebook:      $CRED_ID_FACEBOOK"
echo "  Anthropic:     $CRED_ID_ANTHROPIC"
echo "  Bunny SkyHouse: $CRED_ID_BUNNY_SKYHOUSE"
echo "  Bunny Sayulita: $CRED_ID_BUNNY_SAYULITA"
echo "  Telegram:      $CRED_ID_TELEGRAM"

# Build workflow JSON with real credential IDs
json=$(cat "$TELEGRAM_WORKFLOW" | sed \
  -e "s/CRED_ID_FACEBOOK/$CRED_ID_FACEBOOK/g" \
  -e "s/CRED_ID_ANTHROPIC/$CRED_ID_ANTHROPIC/g" \
  -e "s/CRED_ID_BUNNY_SKYHOUSE/$CRED_ID_BUNNY_SKYHOUSE/g" \
  -e "s/CRED_ID_BUNNY_SAYULITA/$CRED_ID_BUNNY_SAYULITA/g" \
  -e "s/CRED_ID_TELEGRAM/$CRED_ID_TELEGRAM/g")
json=$(echo "$json" | jq 'del(.active)')

# Delete any existing Telegram workflows
echo ""
echo "--- Removing old Telegram workflows ---"
while IFS= read -r old_id; do
  [ -z "$old_id" ] && continue
  api PATCH "/workflows/$old_id" '{"active":false}' > /dev/null
  api DELETE "/workflows/$old_id" > /dev/null
  echo "  → Deleted: $old_id"
done < <(api GET "/workflows?limit=100" | jq -r '.data[] | select(.name == "Fullyo — Telegram AI Assistant") | .id' 2>/dev/null || true)

# Create fresh
echo ""
echo "--- Creating Telegram workflow ---"
response=$(api POST /workflows "$json")
wid=$(echo "$response" | jq -r '.id // empty')

if [ -z "$wid" ]; then
  echo "ERROR: $response"
  exit 1
fi

echo "  ✓ Created: $wid"
echo "  URL: $N8N_BASE_URL/workflow/$wid"

# Register Telegram webhook
TG_WEBHOOK="$N8N_BASE_URL/webhook/fullyo-telegram-assistant"
TG_RESP=$(curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/setWebhook?url=${TG_WEBHOOK}")
echo "  Webhook: $TG_RESP"

echo ""
echo "==================================================="
echo "DONE. Now go to n8n and click PUBLISH on:"
echo "  $N8N_BASE_URL/workflow/$wid"
echo ""
echo "After publishing ONCE, this workflow is permanent."
echo "The main GitHub Action will NOT touch it again."
echo "==================================================="
