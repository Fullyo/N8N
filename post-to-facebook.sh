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
  BUNNY_SUBFOLDER_ENC=""
else
  BUNNY_ZONE="sayulitaandbeyond"
  BUNNY_KEY="$BUNNY_SAYULITA_KEY"
  BUNNY_CDN_HOST="sayulitaandbeyond.b-cdn.net"
  BUNNY_SUBFOLDER="$PHOTO_FOLDER/"
  BUNNY_SUBFOLDER_ENC="${BUNNY_SUBFOLDER// /%20}"
fi

# ── List images from Bunny storage (handles 1 or 2 levels deep) ──
echo "--- Fetching photo list from Bunny CDN ---"
LIST_RESP=$(curl -s \
  -H "AccessKey: $BUNNY_KEY" \
  "$BUNNY_STORAGE_API/$BUNNY_ZONE/$BUNNY_SUBFOLDER_ENC")

# Try to get images directly from this folder
IMAGE_FILES=$(echo "$LIST_RESP" | \
  jq -r '.[] | select(.IsDirectory == false) | select(.ObjectName | test("\\.(jpg|jpeg|png|webp)$"; "i")) | .ObjectName' \
  2>/dev/null || true)

# scan_dir: recursively list images up to 3 levels deep
scan_dir() {
  local base_prefix="$1"   # path prefix for CDN URL (e.g. "Surf/Surf Breaks/")
  local enc_prefix="$2"    # URL-encoded prefix for API (e.g. "Surf/Surf%20Breaks/")
  local depth="$3"         # current depth (max 3)
  [ "$depth" -gt 3 ] && return

  local resp enc_name
  resp=$(curl -s -H "AccessKey: $BUNNY_KEY" "$BUNNY_STORAGE_API/$BUNNY_ZONE/$BUNNY_SUBFOLDER_ENC$enc_prefix")

  # Collect image files at this level
  echo "$resp" | \
    jq -r --arg p "$base_prefix" \
      '.[] | select(.IsDirectory == false) | select(.ObjectName | test("\\.(jpg|jpeg|png|webp)$"; "i")) | $p + .ObjectName' \
    2>/dev/null || true

  # Recurse into subdirectories
  local subdirs
  subdirs=$(echo "$resp" | jq -r '.[] | select(.IsDirectory == true) | .ObjectName' 2>/dev/null || true)
  while IFS= read -r sd; do
    [ -z "$sd" ] && continue
    enc_name="${sd// /%20}"
    scan_dir "$base_prefix$sd/" "$enc_prefix$enc_name/" $(( depth + 1 ))
  done <<< "$subdirs"
}

# If no images found directly, scan recursively
if [ -z "$IMAGE_FILES" ]; then
  echo "  No images at top level — scanning recursively (up to 3 levels)..."
  IMAGE_FILES=$(scan_dir "" "" 1)
fi

# Count safely
if [ -z "$IMAGE_FILES" ]; then
  FILE_COUNT=0
else
  FILE_COUNT=$(printf '%s' "$IMAGE_FILES" | grep -c '[^[:space:]]' || true)
  FILE_COUNT=${FILE_COUNT:-0}
fi
echo "  Found $FILE_COUNT images total"

if [ "$FILE_COUNT" -eq 0 ]; then
  echo "ERROR: No images found in $BUNNY_ZONE/$BUNNY_SUBFOLDER"
  echo "--- Fetching all root folders in $BUNNY_ZONE ---"
  ROOT_RESP=$(curl -s -H "AccessKey: $BUNNY_KEY" "$BUNNY_STORAGE_API/$BUNNY_ZONE/")
  FOLDER_NAMES=$(echo "$ROOT_RESP" | jq -r '.[] | .ObjectName' 2>/dev/null || echo "jq_failed: $ROOT_RESP")
  echo "$FOLDER_NAMES"
  # Write to repo file so it can be read back
  echo "$FOLDER_NAMES" > bunny-folders.txt
  git config user.name "github-actions[bot]"
  git config user.email "github-actions[bot]@users.noreply.github.com"
  git add bunny-folders.txt
  git commit -m "debug: actual Bunny folder names" || true
  git push origin HEAD:claude/n8n-social-media-automation-XpSkG || true
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
  ENCODED_FILENAME="${filename// /%20}"
  CDN_URL="https://$BUNNY_CDN_HOST/${BUNNY_SUBFOLDER_ENC}${ENCODED_FILENAME}"
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
