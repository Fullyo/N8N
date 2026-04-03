#!/usr/bin/env bash
# ============================================================
# SkyHouse Sayulita — n8n Cloud Deployment Script
# Run this from any machine with unrestricted internet access.
# Reads credentials from credentials.local.json in same directory.
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREDS_FILE="$SCRIPT_DIR/credentials.local.json"
WORKFLOW_FILE="$SCRIPT_DIR/skyhouse-sayulita-social-poster.json"

# ── Read credentials ─────────────────────────────────────────
N8N_BASE_URL="https://fullyo.app.n8n.cloud"
N8N_API_KEY=$(jq -r '.n8n.apiKey' "$CREDS_FILE")
FB_ACCESS_TOKEN=$(jq -r '.facebook.pages.skyhouse_sayulita.accessToken' "$CREDS_FILE")
ANTHROPIC_API_KEY=$(jq -r '.anthropic.apiKey' "$CREDS_FILE")
BUNNY_SKYHOUSE_KEY=$(jq -r '.bunny.skyhouse.storageApiKey' "$CREDS_FILE")
BUNNY_SAYULITA_KEY=$(jq -r '.bunny.sayulita_shared.storageApiKey' "$CREDS_FILE")

echo "=== SkyHouse Sayulita — n8n Cloud Deployment ==="
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

# ── Step 1: Create credentials ───────────────────────────────
echo "--- Creating credentials ---"

echo "Creating: SkyHouse Facebook Token..."
FB_CRED_RESPONSE=$(api POST /credentials "{
  \"name\": \"SkyHouse Facebook Token\",
  \"type\": \"httpHeaderAuth\",
  \"data\": {
    \"name\": \"Authorization\",
    \"value\": \"Bearer $FB_ACCESS_TOKEN\"
  }
}")
CRED_ID_FACEBOOK=$(echo "$FB_CRED_RESPONSE" | jq -r '.id // empty')
if [ -z "$CRED_ID_FACEBOOK" ]; then
  echo "ERROR creating Facebook credential: $FB_CRED_RESPONSE"
  exit 1
fi
echo "  ✓ SkyHouse Facebook Token: $CRED_ID_FACEBOOK"

echo "Creating: Anthropic API..."
ANTHROPIC_CRED_RESPONSE=$(api POST /credentials "{
  \"name\": \"Anthropic API\",
  \"type\": \"httpHeaderAuth\",
  \"data\": {
    \"name\": \"x-api-key\",
    \"value\": \"$ANTHROPIC_API_KEY\"
  }
}")
CRED_ID_ANTHROPIC=$(echo "$ANTHROPIC_CRED_RESPONSE" | jq -r '.id // empty')
if [ -z "$CRED_ID_ANTHROPIC" ]; then
  echo "ERROR creating Anthropic credential: $ANTHROPIC_CRED_RESPONSE"
  exit 1
fi
echo "  ✓ Anthropic API: $CRED_ID_ANTHROPIC"

echo "Creating: Bunny SkyHouse Storage..."
BUNNY_SKY_RESPONSE=$(api POST /credentials "{
  \"name\": \"Bunny SkyHouse Storage\",
  \"type\": \"httpHeaderAuth\",
  \"data\": {
    \"name\": \"AccessKey\",
    \"value\": \"$BUNNY_SKYHOUSE_KEY\"
  }
}")
CRED_ID_BUNNY_SKYHOUSE=$(echo "$BUNNY_SKY_RESPONSE" | jq -r '.id // empty')
if [ -z "$CRED_ID_BUNNY_SKYHOUSE" ]; then
  echo "ERROR creating Bunny SkyHouse credential: $BUNNY_SKY_RESPONSE"
  exit 1
fi
echo "  ✓ Bunny SkyHouse Storage: $CRED_ID_BUNNY_SKYHOUSE"

echo "Creating: Bunny Sayulita Shared..."
BUNNY_SAY_RESPONSE=$(api POST /credentials "{
  \"name\": \"Bunny Sayulita Shared\",
  \"type\": \"httpHeaderAuth\",
  \"data\": {
    \"name\": \"AccessKey\",
    \"value\": \"$BUNNY_SAYULITA_KEY\"
  }
}")
CRED_ID_BUNNY_SAYULITA=$(echo "$BUNNY_SAY_RESPONSE" | jq -r '.id // empty')
if [ -z "$CRED_ID_BUNNY_SAYULITA" ]; then
  echo "ERROR creating Bunny Sayulita credential: $BUNNY_SAY_RESPONSE"
  exit 1
fi
echo "  ✓ Bunny Sayulita Shared: $CRED_ID_BUNNY_SAYULITA"

echo ""

# ── Step 2: Inject credential IDs into workflow JSON ─────────
echo "--- Injecting credential IDs into workflow ---"

WORKFLOW_JSON=$(cat "$WORKFLOW_FILE")
WORKFLOW_JSON=$(echo "$WORKFLOW_JSON" | sed \
  -e "s/CRED_ID_FACEBOOK/$CRED_ID_FACEBOOK/g" \
  -e "s/CRED_ID_ANTHROPIC/$CRED_ID_ANTHROPIC/g" \
  -e "s/CRED_ID_BUNNY_SKYHOUSE/$CRED_ID_BUNNY_SKYHOUSE/g" \
  -e "s/CRED_ID_BUNNY_SAYULITA/$CRED_ID_BUNNY_SAYULITA/g")

echo "  ✓ Credential IDs substituted"

# ── Step 3: Deploy workflow ───────────────────────────────────
echo "--- Deploying workflow ---"

WORKFLOW_RESPONSE=$(api POST /workflows "$WORKFLOW_JSON")
WORKFLOW_ID=$(echo "$WORKFLOW_RESPONSE" | jq -r '.id // empty')

if [ -z "$WORKFLOW_ID" ]; then
  echo "ERROR deploying workflow: $WORKFLOW_RESPONSE"
  exit 1
fi
echo "  ✓ Workflow deployed: $WORKFLOW_ID"
echo ""

# ── Step 4: Update credentials.local.json ────────────────────
echo "--- Saving IDs to credentials.local.json ---"

UPDATED_CREDS=$(jq \
  --arg wid "$WORKFLOW_ID" \
  --arg fb "$CRED_ID_FACEBOOK" \
  --arg ant "$CRED_ID_ANTHROPIC" \
  --arg bsky "$CRED_ID_BUNNY_SKYHOUSE" \
  --arg bsay "$CRED_ID_BUNNY_SAYULITA" \
  '.n8n.workflowId = $wid
   | .n8n.credentialIds.facebookSkyhouse = $fb
   | .n8n.credentialIds.anthropic = $ant
   | .n8n.credentialIds.bunnySkyhouse = $bsky
   | .n8n.credentialIds.bunnySayulita = $bsay' \
  "$CREDS_FILE")

echo "$UPDATED_CREDS" > "$CREDS_FILE"
echo "  ✓ credentials.local.json updated"
echo ""

# ── Step 5: Summary ───────────────────────────────────────────
echo "==================================================="
echo "DEPLOYMENT COMPLETE"
echo "==================================================="
echo "Credential IDs:"
echo "  SkyHouse Facebook Token : $CRED_ID_FACEBOOK"
echo "  Anthropic API           : $CRED_ID_ANTHROPIC"
echo "  Bunny SkyHouse Storage  : $CRED_ID_BUNNY_SKYHOUSE"
echo "  Bunny Sayulita Shared   : $CRED_ID_BUNNY_SAYULITA"
echo ""
echo "Workflow ID: $WORKFLOW_ID"
echo "Workflow URL: $N8N_BASE_URL/workflow/$WORKFLOW_ID"
echo ""
echo "The workflow is INACTIVE. To activate or test manually:"
echo "  Activate : PATCH $N8N_BASE_URL/api/v1/workflows/$WORKFLOW_ID  {\"active\":true}"
echo "  Test run : POST  $N8N_BASE_URL/api/v1/workflows/$WORKFLOW_ID/run"
echo "==================================================="
