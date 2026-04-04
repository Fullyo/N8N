#!/usr/bin/env bash
# ============================================================
# post-to-facebook.sh
#
# Posts an approved caption + photos to the SkyHouse Facebook page.
# Photo sourcing priority:
#   1. Bunny CDN (authentic, property/location photos)
#   2. Pexels API (stock fallback for activity/experience content)
#   3. Hard fail with clear message (SkyHouse property posts only)
#
# Reads from pending-post.json:
#   caption       - the post text
#   photo_folder  - logical category (e.g. "Surf", "Whale Tours")
#   num_photos    - how many to attach (default 3)
#   pexels_query  - optional: override auto search term for Pexels
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREDS_FILE="$SCRIPT_DIR/credentials.local.json"
PENDING_FILE="$SCRIPT_DIR/pending-post.json"

# ── Read post details ─────────────────────────────────────────
CAPTION=$(jq -r '.caption' "$PENDING_FILE")
PHOTO_FOLDER=$(jq -r '.photo_folder' "$PENDING_FILE")
NUM_PHOTOS=$(jq -r '.num_photos // 3' "$PENDING_FILE")
PEXELS_QUERY_OVERRIDE=$(jq -r '.pexels_query // empty' "$PENDING_FILE")

if [ -z "$CAPTION" ] || [ "$CAPTION" = "null" ] || [ -z "$PHOTO_FOLDER" ] || [ "$PHOTO_FOLDER" = "null" ]; then
  echo "ERROR: pending-post.json is missing caption or photo_folder"
  exit 1
fi

echo "=== Facebook Post Creator ==="
echo "  Category:  $PHOTO_FOLDER"
echo "  Photos:    $NUM_PHOTOS"
echo "  Caption:   ${CAPTION:0:80}..."
echo ""

# ── Credentials ───────────────────────────────────────────────
FB_ACCESS_TOKEN=$(jq -r '.facebook.pages.skyhouse_sayulita.accessToken' "$CREDS_FILE")
FB_PAGE_ID=$(jq -r '.facebook.pages.skyhouse_sayulita.pageId' "$CREDS_FILE")
BUNNY_SAYULITA_KEY=$(jq -r '.bunny.sayulita_shared.storageApiKey' "$CREDS_FILE")
BUNNY_SKYHOUSE_KEY=$(jq -r '.bunny.skyhouse.storageApiKey' "$CREDS_FILE")
PEXELS_API_KEY=$(jq -r '.pexels.apiKey // empty' "$CREDS_FILE")

FB_API="https://graph.facebook.com/v19.0"
BUNNY_STORAGE_API="https://la.storage.bunnycdn.com"

# ── Determine Bunny zone ──────────────────────────────────────
IS_SKYHOUSE=false
if [ "$PHOTO_FOLDER" = "SkyHouse" ]; then
  IS_SKYHOUSE=true
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

# ── Recursive image scanner (up to 3 levels deep) ────────────
# Outputs one "subpath/filename.jpg" per line
scan_bunny_dir() {
  local base_prefix="$1"   # path prefix for CDN URL construction
  local enc_prefix="$2"    # URL-encoded prefix for API calls
  local depth="$3"
  [ "$depth" -gt 3 ] && return

  local resp
  resp=$(curl -s --max-time 10 \
    -H "AccessKey: $BUNNY_KEY" \
    "$BUNNY_STORAGE_API/$BUNNY_ZONE/$BUNNY_SUBFOLDER_ENC$enc_prefix")

  # Emit image files at this level
  echo "$resp" | \
    jq -r --arg p "$base_prefix" \
      '.[] | select(.IsDirectory == false) | select(.ObjectName | test("\\.(jpg|jpeg|png|webp|heic|tiff|bmp)$"; "i")) | $p + .ObjectName' \
    2>/dev/null || true

  # Recurse into subdirectories
  local subdirs
  subdirs=$(echo "$resp" | jq -r '.[] | select(.IsDirectory == true) | .ObjectName' 2>/dev/null || true)
  while IFS= read -r sd; do
    [ -z "$sd" ] && continue
    local enc_sd="${sd// /%20}"
    scan_bunny_dir "$base_prefix$sd/" "$enc_prefix$enc_sd/" $(( depth + 1 ))
  done <<< "$subdirs"
}

# ── Step 1: Try Bunny CDN ─────────────────────────────────────
echo "--- Checking Bunny CDN ---"
IMAGE_SOURCE="bunny"
IMAGE_FILES=$(scan_bunny_dir "" "" 1)

# Count
if [ -z "$IMAGE_FILES" ]; then
  BUNNY_COUNT=0
else
  BUNNY_COUNT=$(printf '%s\n' "$IMAGE_FILES" | grep -c '[^[:space:]]' || true)
  BUNNY_COUNT=${BUNNY_COUNT:-0}
fi
echo "  Found $BUNNY_COUNT images in Bunny CDN"

# ── Step 2: Pexels fallback (non-SkyHouse only) ───────────────
if [ "$BUNNY_COUNT" -eq 0 ]; then
  if [ "$IS_SKYHOUSE" = "true" ]; then
    echo ""
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║  STOP: SkyHouse folder is empty in Bunny CDN.       ║"
    echo "║  External stock photos cannot be used for the        ║"
    echo "║  property itself. Please upload real SkyHouse        ║"
    echo "║  photos to Bunny CDN and retry.                      ║"
    echo "╚══════════════════════════════════════════════════════╝"
    exit 1
  fi

  if [ -z "$PEXELS_API_KEY" ]; then
    echo "ERROR: Bunny CDN empty and no PEXELS_API_KEY configured."
    echo "Add the PEXELS_API_KEY secret in GitHub → Settings → Secrets."
    exit 1
  fi

  # Build Pexels search query
  if [ -n "$PEXELS_QUERY_OVERRIDE" ]; then
    PEXELS_QUERY="$PEXELS_QUERY_OVERRIDE"
    echo "  Using custom Pexels query: $PEXELS_QUERY"
  else
    # Auto keyword map — folder name → search terms
    case "$PHOTO_FOLDER" in
      "Surf")              PEXELS_QUERY="surfing Mexico Pacific waves beach" ;;
      "Yoga")              PEXELS_QUERY="yoga beach sunrise Mexico tropical" ;;
      "Restaurants")       PEXELS_QUERY="Mexican food tacos street food market" ;;
      "Marieta Islands")   PEXELS_QUERY="Marieta Islands hidden beach Mexico snorkeling" ;;
      "Monkey Mountain")   PEXELS_QUERY="jungle hiking Mexico wildlife tropical" ;;
      "Golf")              PEXELS_QUERY="golf course tropical Mexico ocean view" ;;
      "Fishing Charter")   PEXELS_QUERY="deep sea fishing Mexico Pacific sailfish" ;;
      "Whale Tours")       PEXELS_QUERY="humpback whale ocean Mexico Pacific" ;;
      "SUP")               PEXELS_QUERY="stand up paddleboard ocean tropical" ;;
      "Ally Cat")          PEXELS_QUERY="sailing catamaran Mexico Pacific sunset" ;;
      "CachaSol")          PEXELS_QUERY="Mexico beach sunset cocktails bar" ;;
      "Local Cultural")    PEXELS_QUERY="Mexico culture festival traditional local" ;;
      *)                   PEXELS_QUERY="$PHOTO_FOLDER Mexico travel" ;;
    esac
    echo "  Auto Pexels query: $PEXELS_QUERY"
  fi

  echo "--- Searching Pexels (fallback) ---"
  PEXELS_RESP=$(curl -s --max-time 15 \
    -H "Authorization: $PEXELS_API_KEY" \
    "https://api.pexels.com/v1/search?query=$(printf '%s' "$PEXELS_QUERY" | jq -Rr @uri)&per_page=20&orientation=landscape")

  PEXELS_URLS=$(echo "$PEXELS_RESP" | \
    jq -r '.photos[].src.large2x // .photos[].src.large' 2>/dev/null || true)

  PEXELS_COUNT=$(printf '%s\n' "$PEXELS_URLS" | grep -c 'http' || true)
  PEXELS_COUNT=${PEXELS_COUNT:-0}
  echo "  Found $PEXELS_COUNT Pexels photos"

  if [ "$PEXELS_COUNT" -eq 0 ]; then
    echo "ERROR: No photos found on Pexels either. Query: $PEXELS_QUERY"
    echo "Try setting pexels_query in pending-post.json with a more specific term."
    exit 1
  fi

  IMAGE_SOURCE="pexels"
  IMAGE_FILES="$PEXELS_URLS"
  BUNNY_COUNT="$PEXELS_COUNT"
fi

# ── Step 3: Select photos ─────────────────────────────────────
ACTUAL_COUNT=$(( NUM_PHOTOS < BUNNY_COUNT ? NUM_PHOTOS : BUNNY_COUNT ))
echo ""
echo "--- Selecting $ACTUAL_COUNT photos (source: $IMAGE_SOURCE) ---"
SELECTED=$(printf '%s\n' "$IMAGE_FILES" | grep '[^[:space:]]' | shuf -n "$ACTUAL_COUNT")

if [ "$IMAGE_SOURCE" = "pexels" ]; then
  echo "⚠️  Using Pexels stock photos — add real photos to Bunny CDN/$PHOTO_FOLDER/ to use authentic images in future."
fi

# ── Step 4: Upload each photo to Facebook as unpublished ──────
echo ""
echo "--- Uploading to Facebook ---"
PHOTO_IDS=()

while IFS= read -r item; do
  [ -z "$item" ] && continue

  if [ "$IMAGE_SOURCE" = "pexels" ]; then
    CDN_URL="$item"
  else
    ENCODED_ITEM="${item// /%20}"
    CDN_URL="https://$BUNNY_CDN_HOST/${BUNNY_SUBFOLDER_ENC}${ENCODED_ITEM}"
  fi

  echo "  → $(basename "$CDN_URL")"

  UPLOAD_RESP=$(curl -s -X POST \
    "$FB_API/$FB_PAGE_ID/photos" \
    -F "url=$CDN_URL" \
    -F "published=false" \
    -F "access_token=$FB_ACCESS_TOKEN")

  PHOTO_ID=$(echo "$UPLOAD_RESP" | jq -r '.id // empty')
  if [ -z "$PHOTO_ID" ]; then
    echo "  ERROR uploading: $UPLOAD_RESP"
    exit 1
  fi
  echo "  ✓ ID: $PHOTO_ID"
  PHOTO_IDS+=("$PHOTO_ID")
done <<< "$SELECTED"

# ── Step 5: Build attached_media JSON ────────────────────────
MEDIA_JSON="["
for i in "${!PHOTO_IDS[@]}"; do
  [ "$i" -gt 0 ] && MEDIA_JSON+=","
  MEDIA_JSON+="{\"media_fbid\":\"${PHOTO_IDS[$i]}\"}"
done
MEDIA_JSON+="]"

# ── Step 6: Publish post ──────────────────────────────────────
echo ""
echo "--- Publishing post ---"
POST_RESP=$(curl -s -X POST \
  "$FB_API/$FB_PAGE_ID/feed" \
  -F "message=$CAPTION" \
  -F "attached_media=$MEDIA_JSON" \
  -F "access_token=$FB_ACCESS_TOKEN")

POST_ID=$(echo "$POST_RESP" | jq -r '.id // empty')
if [ -z "$POST_ID" ]; then
  echo "ERROR: $POST_RESP"
  exit 1
fi

echo ""
echo "✓ Published! Post ID: $POST_ID"
echo "=== DONE ==="
