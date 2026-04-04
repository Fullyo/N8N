#!/usr/bin/env bash
# ============================================================
# post-to-facebook.sh
# Posts to Facebook with photos from Bunny CDN.
# Reads caption/folder from pending-post.json.
# Called automatically when pending-post.json is pushed.
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREDS_FILE="$SCRIPT_DIR/credentials.local.json"
PENDING_FILE="$SCRIPT_DIR/pending-post.json"

# ── Read post details from pending-post.json ─────────────────
CAPTION=$(jq -r '.caption' "$PENDING_FILE")
PHOTO_FOLDER=$(jq -r '.photo_folder' "$PENDING_FILE")
NUM_PHOTOS=$(jq -r '.num_photos // 3' "$PENDING_FILE")

if [ -z "$CAPTION" ] || [ "$CAPTION" = "null" ] || [ -z "$PHOTO_FOLDER" ] || [ "$PHOTO_FOLDER" = "null" ]; then
  echo "ERROR: pending-post.json is missing caption or photo_folder"
  cat "$PENDING_FILE"
  exit 1
fi

echo "=== Facebook Post Creator ==="
echo "  Caption preview: ${CAPTION:0:80}..."
echo "  Folder:          $PHOTO_FOLDER"
echo "  Photos:          $NUM_PHOTOS"
echo ""

# ── Credentials ───────────────────────────────────────────────
FB_ACCESS_TOKEN=$(jq -r '.facebook.pages.skyhouse_sayulita.accessToken' "$CREDS_FILE")
FB_PAGE_ID=$(jq -r '.facebook.pages.skyhouse_sayulita.pageId' "$CREDS_FILE")
BUNNY_SAYULITA_KEY=$(jq -r '.bunny.sayulita_shared.storageApiKey' "$CREDS_FILE")
BUNNY_SKYHOUSE_KEY=$(jq -r '.bunny.skyhouse.storageApiKey' "$CREDS_FILE")

FB_API="https://graph.facebook.com/v19.0"
BUNNY_STORAGE_API="https://la.storage.bunnycdn.com"

# ── Determine Bunny zone ──────────────────────────────────────
if [ "$PHOTO_FOLDER" = "SkyHouse" ]; then
  BUNNY_ZONE="skyhousesayulita"
  BUNNY_KEY="$BUNNY_SKYHOUSE_KEY"
  BUNNY_CDN_HOST="SkyhouseSayulita.b-cdn.net"
  BUNNY_SUBFOLDER=""
else
  BUNNY_ZONE="sayulitaandbeyond"
  BUNNY_KEY="$BUNNY_SAYULITA_KEY"
  BUNNY_CDN_HOST="sayulitaandbeyond.b-cdn.net"
  BUNNY_SUBFOLDER="$PHOTO_FOLDER/"
fi

# ── List images from Bunny storage ────────────────────────────
echo "--- Fetching photo list from Bunny CDN ---"
LIST_RESP=$(curl -s \
  -H "AccessKey: $BUNNY_KEY" \
  "$BUNNY_STORAGE_API/$BUNNY_ZONE/$BUNNY_SUBFOLDER")

IMAGE_FILES=$(echo "$LIST_RESP" | \
  jq -r '.[] | select(.IsDirectory == false) | select(.ObjectName | test("\\.(jpg|jpeg|png|webp)$"; "i")) | .ObjectName' \
  2>/dev/null || true)

FILE_COUNT=$(echo "$IMAGE_FILES" | grep -c '[^[:space:]]' || echo 0)
echo "  Found $FILE_COUNT images"

if [ "$FILE_COUNT" -eq 0 ]; then
  echo "ERROR: No images found in $BUNNY_ZONE/$BUNNY_SUBFOLDER"
  echo "Raw response: $LIST_RESP"
  exit 1
fi

# ── Pick random photos ────────────────────────────────────────
ACTUAL_COUNT=$(( NUM_PHOTOS < FILE_COUNT ? NUM_PHOTOS : FILE_COUNT ))
echo "--- Selecting $ACTUAL_COUNT random photos ---"
SELECTED=$(echo "$IMAGE_FILES" | shuf -n "$ACTUAL_COUNT")

# ── Upload each photo to Facebook as unpublished ──────────────
echo "--- Uploading photos to Facebook ---"
PHOTO_IDS=()

while IFS= read -r filename; do
  [ -z "$filename" ] && continue
  CDN_URL="https://$BUNNY_CDN_HOST/${BUNNY_SUBFOLDER}${filename}"
  echo "  → $filename"

  UPLOAD_RESP=$(curl -s -X POST \
    "$FB_API/$FB_PAGE_ID/photos" \
    -F "url=$CDN_URL" \
    -F "published=false" \
    -F "access_token=$FB_ACCESS_TOKEN")

  PHOTO_ID=$(echo "$UPLOAD_RESP" | jq -r '.id // empty')
  if [ -z "$PHOTO_ID" ]; then
    echo "  ERROR uploading $filename: $UPLOAD_RESP"
    exit 1
  fi
  echo "  ✓ Photo ID: $PHOTO_ID"
  PHOTO_IDS+=("$PHOTO_ID")
done <<< "$SELECTED"

# ── Build attached_media JSON ─────────────────────────────────
MEDIA_JSON="["
for i in "${!PHOTO_IDS[@]}"; do
  [ "$i" -gt 0 ] && MEDIA_JSON+=","
  MEDIA_JSON+="{\"media_fbid\":\"${PHOTO_IDS[$i]}\"}"
done
MEDIA_JSON+="]"

# ── Create the Facebook post ──────────────────────────────────
echo ""
echo "--- Publishing Facebook post ---"

POST_RESP=$(curl -s -X POST \
  "$FB_API/$FB_PAGE_ID/feed" \
  -F "message=$CAPTION" \
  -F "attached_media=$MEDIA_JSON" \
  -F "access_token=$FB_ACCESS_TOKEN")

POST_ID=$(echo "$POST_RESP" | jq -r '.id // empty')
if [ -z "$POST_ID" ]; then
  echo "ERROR creating post: $POST_RESP"
  exit 1
fi

echo ""
echo "✓ Post published! ID: $POST_ID"
echo "=== DONE ==="
