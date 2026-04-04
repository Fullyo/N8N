#!/usr/bin/env bash
# ============================================================
# Fullyo — n8n Cloud Deployment Script
# Deploys all workflows: SkyHouse social poster + Telegram assistant
# Reads credentials from credentials.local.json in same directory.
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREDS_FILE="$SCRIPT_DIR/credentials.local.json"
SKYHOUSE_WORKFLOW="$SCRIPT_DIR/skyhouse-sayulita-social-poster.json"
TELEGRAM_WORKFLOW="$SCRIPT_DIR/telegram-assistant.json"

# ── Read credentials ─────────────────────────────────────────
N8N_BASE_URL="https://fullyo.app.n8n.cloud"
N8N_API_KEY=$(jq -r '.n8n.apiKey' "$CREDS_FILE")
FB_ACCESS_TOKEN=$(jq -r '.facebook.pages.skyhouse_sayulita.accessToken' "$CREDS_FILE")
ANTHROPIC_API_KEY=$(jq -r '.anthropic.apiKey' "$CREDS_FILE")
BUNNY_SKYHOUSE_KEY=$(jq -r '.bunny.skyhouse.storageApiKey' "$CREDS_FILE")
BUNNY_SAYULITA_KEY=$(jq -r '.bunny.sayulita_shared.storageApiKey' "$CREDS_FILE")
TELEGRAM_BOT_TOKEN=$(jq -r '.telegram.botToken' "$CREDS_FILE")

echo "=== Fullyo — n8n Cloud Deployment ==="
echo "Instance: $N8N_BASE_URL"
echo ""

api() {
  local method="$1"
  local path="$2"
  local data="${3:-}"
  if [ -n "$data" ]; then
    curl -s -X "$method" "$N8N_BASE_URL/api/v1$path" \
      -H "X-N8N-API-KEY: $N8N_API_KEY" \
      -H "Content-Type: application/json" \
      -d "$data"
  else
    curl -s -X "$method" "$N8N_BASE_URL/api/v1$path" \
      -H "X-N8N-API-KEY: $N8N_API_KEY"
  fi
}

# ── Step 1: Create or reuse credentials ──────────────────────
echo "--- Creating credentials (skipping if already exist) ---"

EXISTING_CREDS=$(api GET /credentials)

get_or_create_cred() {
  local name="$1"
  local type="$2"
  local data="$3"

  local existing_id
  existing_id=$(echo "$EXISTING_CREDS" | jq -r --arg n "$name" '.data[] | select(.name == $n) | .id // empty' 2>/dev/null | head -1)

  if [ -n "$existing_id" ]; then
    echo "  ↩ $name already exists: $existing_id" >&2
    echo "$existing_id"
    return
  fi

  local response
  response=$(api POST /credentials "{\"name\":\"$name\",\"type\":\"$type\",\"data\":$data}")
  local new_id
  new_id=$(echo "$response" | jq -r '.id // empty')

  if [ -z "$new_id" ]; then
    echo "ERROR creating credential '$name': $response" >&2
    exit 1
  fi
  echo "  ✓ $name: $new_id" >&2
  echo "$new_id"
}

CRED_ID_FACEBOOK=$(get_or_create_cred \
  "SkyHouse Facebook Token" "httpHeaderAuth" \
  "{\"name\":\"Authorization\",\"value\":\"Bearer $FB_ACCESS_TOKEN\"}")

CRED_ID_ANTHROPIC=$(get_or_create_cred \
  "Anthropic API" "httpHeaderAuth" \
  "{\"name\":\"x-api-key\",\"value\":\"$ANTHROPIC_API_KEY\"}")

CRED_ID_BUNNY_SKYHOUSE=$(get_or_create_cred \
  "Bunny SkyHouse Storage" "httpHeaderAuth" \
  "{\"name\":\"AccessKey\",\"value\":\"$BUNNY_SKYHOUSE_KEY\"}")

CRED_ID_BUNNY_SAYULITA=$(get_or_create_cred \
  "Bunny Sayulita Shared" "httpHeaderAuth" \
  "{\"name\":\"AccessKey\",\"value\":\"$BUNNY_SAYULITA_KEY\"}")

CRED_ID_TELEGRAM=$(get_or_create_cred \
  "Fullyo Telegram Bot" "telegramApi" \
  "{\"accessToken\":\"$TELEGRAM_BOT_TOKEN\"}")

echo ""

# ── Helper: deploy one workflow ───────────────────────────────
deploy_workflow() {
  local label="$1"
  local file="$2"
  local json
  json=$(cat "$file")

  # Substitute credential IDs
  json=$(echo "$json" | sed \
    -e "s/CRED_ID_FACEBOOK/$CRED_ID_FACEBOOK/g" \
    -e "s/CRED_ID_ANTHROPIC/$CRED_ID_ANTHROPIC/g" \
    -e "s/CRED_ID_BUNNY_SKYHOUSE/$CRED_ID_BUNNY_SKYHOUSE/g" \
    -e "s/CRED_ID_BUNNY_SAYULITA/$CRED_ID_BUNNY_SAYULITA/g" \
    -e "s/CRED_ID_TELEGRAM/$CRED_ID_TELEGRAM/g")

  # Remove 'active' field — n8n API rejects it on POST
  json=$(echo "$json" | jq 'del(.active)')

  # Deactivate and delete any existing workflows with same name
  while IFS= read -r old_id; do
    [ -z "$old_id" ] && continue
    api PATCH "/workflows/$old_id" '{"active":false}' > /dev/null
    api DELETE "/workflows/$old_id" > /dev/null
    echo "  → Deleted old: $old_id" >&2
  done < <(api GET "/workflows?limit=100" | jq -r --arg name "$label" '.data[] | select(.name == $name) | .id' 2>/dev/null || true)

  echo "--- Deploying: $label ---"
  local response
  response=$(api POST /workflows "$json")
  local wid
  wid=$(echo "$response" | jq -r '.id // empty')

  if [ -z "$wid" ]; then
    echo "ERROR deploying $label: $response"
    exit 1
  fi
  echo "  ✓ $label deployed: $wid"
  echo "  URL: $N8N_BASE_URL/workflow/$wid"

  # Activate the new workflow
  activate_resp=$(api PATCH "/workflows/$wid" '{"active":true}')
  if echo "$activate_resp" | jq -e '.active == true' > /dev/null 2>&1; then
    echo "  ✓ Activated!"
  else
    echo "  ⚠ Check n8n to activate manually"
  fi

  echo "$wid"
}

# ── Step 2: Deploy workflows ──────────────────────────────────
SKYHOUSE_ID=$(deploy_workflow "SkyHouse Sayulita — Daily Social Post" "$SKYHOUSE_WORKFLOW")
echo ""
TELEGRAM_ID=$(deploy_workflow "Fullyo — Telegram AI Assistant" "$TELEGRAM_WORKFLOW")
echo ""

# ── Step 3: Save IDs ─────────────────────────────────────────
echo "--- Saving IDs to credentials.local.json ---"

UPDATED=$(jq \
  --arg wsky "$SKYHOUSE_ID" \
  --arg wtg "$TELEGRAM_ID" \
  --arg fb "$CRED_ID_FACEBOOK" \
  --arg ant "$CRED_ID_ANTHROPIC" \
  --arg bsky "$CRED_ID_BUNNY_SKYHOUSE" \
  --arg bsay "$CRED_ID_BUNNY_SAYULITA" \
  --arg tg "$CRED_ID_TELEGRAM" \
  '.n8n.workflowIds.skyhouse = $wsky
   | .n8n.workflowIds.telegramAssistant = $wtg
   | .n8n.credentialIds.facebookSkyhouse = $fb
   | .n8n.credentialIds.anthropic = $ant
   | .n8n.credentialIds.bunnySkyhouse = $bsky
   | .n8n.credentialIds.bunnySayulita = $bsay
   | .n8n.credentialIds.telegram = $tg' \
  "$CREDS_FILE")

echo "$UPDATED" > "$CREDS_FILE"
echo "  ✓ credentials.local.json updated"
echo ""
echo "==================================================="
echo "DEPLOYMENT COMPLETE"
echo "  SkyHouse workflow : $N8N_BASE_URL/workflow/$SKYHOUSE_ID"
echo "  Telegram assistant: $N8N_BASE_URL/workflow/$TELEGRAM_ID"
echo ""
echo "Both workflows deployed and activated."
echo "==================================================="
