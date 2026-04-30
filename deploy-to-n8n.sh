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
VSA_WORKFLOW="$SCRIPT_DIR/villas-sempre-avanti-social-poster.json"
MP_WORKFLOW="$SCRIPT_DIR/moroccan-palace-social-poster.json"
LUX_WORKFLOW="$SCRIPT_DIR/lux-property-management-social-poster.json"

# ── Read credentials ─────────────────────────────────────────
N8N_BASE_URL="https://fullyo.app.n8n.cloud"
N8N_API_KEY=$(jq -r '.n8n.apiKey' "$CREDS_FILE")
FB_ACCESS_TOKEN=$(jq -r '.facebook.pages.skyhouse_sayulita.accessToken' "$CREDS_FILE")
FB_VSA_TOKEN=$(jq -r '.facebook.pages.casasempreavanti.accessToken' "$CREDS_FILE")
FB_MP_TOKEN=$(jq -r '.facebook.pages.moroccan_palace.accessToken' "$CREDS_FILE")
FB_LUX_TOKEN=$(jq -r '.facebook.pages.lux_property_management.accessToken' "$CREDS_FILE")
ANTHROPIC_API_KEY=$(jq -r '.anthropic.apiKey' "$CREDS_FILE")
BUNNY_SKYHOUSE_KEY=$(jq -r '.bunny.skyhouse.storageApiKey' "$CREDS_FILE")
BUNNY_SAYULITA_KEY=$(jq -r '.bunny.sayulita_shared.storageApiKey' "$CREDS_FILE")
BUNNY_CSA_KEY=$(jq -r '.bunny.casasempreavanti.storageApiKey' "$CREDS_FILE")
PEXELS_API_KEY=$(jq -r '.pexels.apiKey // empty' "$CREDS_FILE")
TELEGRAM_BOT_TOKEN=$(jq -r '.telegram.botToken' "$CREDS_FILE")

# Exchange user tokens for page tokens.
# Facebook requires page access tokens for /photos?published=false uploads.
# Falls back to the original token if exchange fails (e.g. already a page token).
get_page_token() {
  local token="$1"
  local page_id="$2"
  local result page_token
  result=$(curl -s "https://graph.facebook.com/v19.0/me/accounts?access_token=${token}&fields=id,access_token&limit=50" 2>/dev/null || echo '{}')
  page_token=$(echo "$result" | jq -r --arg pid "$page_id" '.data[]? | select(.id == $pid) | .access_token // empty' 2>/dev/null | head -1)
  if [ -n "$page_token" ]; then
    echo "  ✓ Exchanged page token for page $page_id" >&2
    echo "$page_token"
  else
    echo "  ⚠ Page token exchange failed for $page_id — using stored token as-is" >&2
    echo "$token"
  fi
}

echo "--- Exchanging user tokens for Facebook page tokens ---"
FB_ACCESS_TOKEN=$(get_page_token "$FB_ACCESS_TOKEN" "1004908006045909")
FB_VSA_TOKEN=$(get_page_token "$FB_VSA_TOKEN" "350547805544245")
FB_MP_TOKEN=$(get_page_token "$FB_MP_TOKEN" "954938847703306")
FB_LUX_TOKEN=$(get_page_token "$FB_LUX_TOKEN" "999599493240965")
echo ""

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

# Always updates credential data (handles type changes); creates if missing
upsert_cred() {
  local name="$1"
  local type="$2"
  local data="$3"

  local existing_id
  existing_id=$(echo "$EXISTING_CREDS" | jq -r --arg n "$name" '.data[] | select(.name == $n) | .id // empty' 2>/dev/null | head -1)

  if [ -n "$existing_id" ]; then
    api PATCH "/credentials/$existing_id" "{\"name\":\"$name\",\"type\":\"$type\",\"data\":$data}" > /dev/null
    echo "  ↺ $name updated: $existing_id" >&2
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

CRED_ID_FACEBOOK=$(upsert_cred \
  "SkyHouse Facebook Token" "httpQueryAuth" \
  "{\"name\":\"access_token\",\"value\":\"$FB_ACCESS_TOKEN\"}")

CRED_ID_ANTHROPIC=$(upsert_cred \
  "Anthropic API" "httpHeaderAuth" \
  "{\"name\":\"x-api-key\",\"value\":\"$ANTHROPIC_API_KEY\"}")

CRED_ID_BUNNY_SKYHOUSE=$(upsert_cred \
  "Bunny SkyHouse Storage" "httpHeaderAuth" \
  "{\"name\":\"AccessKey\",\"value\":\"$BUNNY_SKYHOUSE_KEY\"}")

CRED_ID_BUNNY_SAYULITA=$(upsert_cred \
  "Bunny Sayulita Shared" "httpHeaderAuth" \
  "{\"name\":\"AccessKey\",\"value\":\"$BUNNY_SAYULITA_KEY\"}")

CRED_ID_TELEGRAM=$(get_or_create_cred \
  "Fullyo Telegram Bot" "telegramApi" \
  "{\"accessToken\":\"$TELEGRAM_BOT_TOKEN\"}")

CRED_ID_FB_CASASEMPREAVANTI=$(upsert_cred \
  "Facebook VSA Page Token" "httpQueryAuth" \
  "{\"name\":\"access_token\",\"value\":\"$FB_VSA_TOKEN\"}")

CRED_ID_BUNNY_CASASEMPREAVANTI=$(upsert_cred \
  "Bunny VSA Storage" "httpHeaderAuth" \
  "{\"name\":\"AccessKey\",\"value\":\"$BUNNY_CSA_KEY\"}")

CRED_ID_FB_MOROCCANPALACE=$(upsert_cred \
  "Facebook Moroccan Palace Token" "httpQueryAuth" \
  "{\"name\":\"access_token\",\"value\":\"$FB_MP_TOKEN\"}")

CRED_ID_FB_LUX=$(upsert_cred \
  "Facebook LUX Token" "httpQueryAuth" \
  "{\"name\":\"access_token\",\"value\":\"$FB_LUX_TOKEN\"}")

CRED_ID_PEXELS=$(upsert_cred \
  "Pexels API" "httpHeaderAuth" \
  "{\"name\":\"Authorization\",\"value\":\"$PEXELS_API_KEY\"}")

echo ""

# ── Helper: deploy one workflow ───────────────────────────────
# UPDATE existing workflow if found (preserves published/active state + webhook)
# CREATE new only on first deploy, then user publishes once manually
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
    -e "s/CRED_ID_TELEGRAM/$CRED_ID_TELEGRAM/g" \
    -e "s/CRED_ID_FB_CASASEMPREAVANTI/$CRED_ID_FB_CASASEMPREAVANTI/g" \
    -e "s/CRED_ID_BUNNY_CASASEMPREAVANTI/$CRED_ID_BUNNY_CASASEMPREAVANTI/g" \
    -e "s/CRED_ID_FB_LUX/$CRED_ID_FB_LUX/g" \
    -e "s/CRED_ID_FB_MOROCCANPALACE/$CRED_ID_FB_MOROCCANPALACE/g" \
    -e "s/CRED_ID_PEXELS/$CRED_ID_PEXELS/g")

  # Remove 'active' field — managed separately
  json=$(echo "$json" | jq 'del(.active)')

  echo "--- Deploying: $label ---"

  # Find existing workflow by name (keep newest if multiple)
  local all_wf existing_id
  all_wf=$(api GET "/workflows?limit=100")
  existing_id=$(echo "$all_wf" | jq -r --arg name "$label" '[.data[] | select(.name == $name)] | sort_by(.createdAt) | last | .id // empty' 2>/dev/null)

  local wid response
  if [ -n "$existing_id" ]; then
    # Deactivate first — clears old schedule state so activate re-registers the cron fresh
    api POST "/workflows/$existing_id/deactivate" '{}' > /dev/null
    echo "  → Deactivated: $existing_id (will re-activate after update)"
    # UPDATE existing — preserves published state, no webhook re-registration needed
    echo "  → Updating existing workflow: $existing_id"
    response=$(api PUT "/workflows/$existing_id" "$json")
    wid=$(echo "$response" | jq -r '.id // empty')
    if [ -z "$wid" ]; then
      echo "ERROR updating $label: $response"
      exit 1
    fi
    echo "  ✓ Updated in place: $wid"
    # n8n Cloud Public API requires POST /workflows/:id/activate — PATCH active is ignored
    api POST "/workflows/$wid/activate" '{}' > /dev/null
    echo "  ✓ Activated (fresh cron registration)"

    # Delete any duplicate workflows with same name (keep the one we just updated)
    while IFS= read -r dup_id; do
      [ -z "$dup_id" ] || [ "$dup_id" = "$wid" ] && continue
      api POST "/workflows/$dup_id/deactivate" '{}' > /dev/null
      api DELETE "/workflows/$dup_id" > /dev/null
      echo "  → Removed duplicate: $dup_id" >&2
    done < <(echo "$all_wf" | jq -r --arg name "$label" '.data[] | select(.name == $name) | .id' 2>/dev/null || true)
  else
    # CREATE new — user must click Publish once in n8n UI after first deploy
    response=$(api POST /workflows "$json")
    wid=$(echo "$response" | jq -r '.id // empty')
    if [ -z "$wid" ]; then
      echo "ERROR creating $label: $response"
      exit 1
    fi
    echo "  ✓ Created: $wid"
    echo "  ⚠ ACTION NEEDED: Open n8n and click Publish on this workflow once."
    api POST "/workflows/$wid/activate" '{}' > /dev/null
  fi

  echo "  URL: $N8N_BASE_URL/workflow/$wid"
  echo "$wid"
}

# ── Step 2: Deploy workflows ──────────────────────────────────
# NOTE: Telegram workflow is intentionally NOT deployed here.
# It is deployed once manually and never touched by automation
# to prevent webhook deregistration on every push.
SKYHOUSE_ID=$(deploy_workflow "SkyHouse Sayulita — Daily Social Post" "$SKYHOUSE_WORKFLOW")
VSA_ID=$(deploy_workflow "Villas Sempre Avanti — Daily Social Post" "$VSA_WORKFLOW")
MP_ID=$(deploy_workflow "The Moroccan Palace — Daily Social Post" "$MP_WORKFLOW")
LUX_ID=$(deploy_workflow "LUX Property Management — Daily Social Post" "$LUX_WORKFLOW")
TELEGRAM_ID="(managed separately — not redeployed)"
echo ""

# ── Step 3: Save IDs ─────────────────────────────────────────
echo "--- Saving IDs to credentials.local.json ---"

UPDATED=$(jq \
  --arg wsky "$SKYHOUSE_ID" \
  --arg wvsa "$VSA_ID" \
  --arg wmp "$MP_ID" \
  --arg wlux "$LUX_ID" \
  --arg wtg "$TELEGRAM_ID" \
  --arg fb "$CRED_ID_FACEBOOK" \
  --arg fbvsa "$CRED_ID_FB_CASASEMPREAVANTI" \
  --arg fbmp "$CRED_ID_FB_MOROCCANPALACE" \
  --arg fblux "$CRED_ID_FB_LUX" \
  --arg ant "$CRED_ID_ANTHROPIC" \
  --arg bsky "$CRED_ID_BUNNY_SKYHOUSE" \
  --arg bsay "$CRED_ID_BUNNY_SAYULITA" \
  --arg bcsa "$CRED_ID_BUNNY_CASASEMPREAVANTI" \
  --arg pex "$CRED_ID_PEXELS" \
  --arg tg "$CRED_ID_TELEGRAM" \
  '.n8n.workflowIds.skyhouse = $wsky
   | .n8n.workflowIds.villasSempreAvanti = $wvsa
   | .n8n.workflowIds.moroccanPalace = $wmp
   | .n8n.workflowIds.lux = $wlux
   | .n8n.workflowIds.telegramAssistant = $wtg
   | .n8n.credentialIds.facebookSkyhouse = $fb
   | .n8n.credentialIds.facebookVSA = $fbvsa
   | .n8n.credentialIds.facebookMoroccanPalace = $fbmp
   | .n8n.credentialIds.facebookLux = $fblux
   | .n8n.credentialIds.anthropic = $ant
   | .n8n.credentialIds.bunnySkyhouse = $bsky
   | .n8n.credentialIds.bunnySayulita = $bsay
   | .n8n.credentialIds.bunnyCasaSempreAvanti = $bcsa
   | .n8n.credentialIds.pexels = $pex
   | .n8n.credentialIds.telegram = $tg' \
  "$CREDS_FILE")

echo "$UPDATED" > "$CREDS_FILE"
echo "  ✓ credentials.local.json updated"
echo ""

# ── Step 4: Register Telegram webhook explicitly ──────────────
echo "--- Registering Telegram webhook ---"
TG_WEBHOOK_URL="$N8N_BASE_URL/webhook/fullyo-telegram-assistant"
TG_RESP=$(curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/setWebhook?url=${TG_WEBHOOK_URL}")
if echo "$TG_RESP" | jq -e '.ok == true' > /dev/null 2>&1; then
  echo "  ✓ Telegram webhook registered: $TG_WEBHOOK_URL"
else
  echo "  ⚠ Telegram webhook registration failed: $TG_RESP"
fi
echo ""

echo "==================================================="
echo "DEPLOYMENT COMPLETE"
echo "  SkyHouse workflow       : $N8N_BASE_URL/workflow/$SKYHOUSE_ID"
echo "  Villas Sempre Avanti    : $N8N_BASE_URL/workflow/$VSA_ID"
echo "  Telegram assistant      : $N8N_BASE_URL/workflow/$TELEGRAM_ID"
echo ""
echo "Both workflows deployed and activated."
echo "==================================================="
