#!/usr/bin/env bash
# Quick one-shot diagnostic: dump Marieta Islands folder structure to marieta-contents.txt
set -euo pipefail

CREDS_FILE="$(dirname "$0")/credentials.local.json"
BUNNY_KEY=$(jq -r '.bunny.sayulita_shared.storageApiKey' "$CREDS_FILE")
BUNNY_API="https://la.storage.bunnycdn.com"
ZONE="sayulitaandbeyond"
FOLDER="Marieta%20Islands"

echo "=== Level 1: Marieta Islands/ ===" | tee marieta-contents.txt
curl -s -H "AccessKey: $BUNNY_KEY" "$BUNNY_API/$ZONE/$FOLDER/" | \
  jq -r '.[] | (.IsDirectory | tostring) + "  " + .ObjectName' 2>/dev/null | tee -a marieta-contents.txt

# Get subdirs and list each
SUBDIRS=$(curl -s -H "AccessKey: $BUNNY_KEY" "$BUNNY_API/$ZONE/$FOLDER/" | \
  jq -r '.[] | select(.IsDirectory == true) | .ObjectName' 2>/dev/null || true)

while IFS= read -r sd; do
  [ -z "$sd" ] && continue
  ENC="${sd// /%20}"
  echo "" | tee -a marieta-contents.txt
  echo "=== Level 2: Marieta Islands/$sd/ ===" | tee -a marieta-contents.txt
  curl -s -H "AccessKey: $BUNNY_KEY" "$BUNNY_API/$ZONE/$FOLDER/$ENC/" | \
    jq -r '.[] | (.IsDirectory | tostring) + "  " + .ObjectName' 2>/dev/null | tee -a marieta-contents.txt
done <<< "$SUBDIRS"

echo ""
echo "Done. See marieta-contents.txt"
