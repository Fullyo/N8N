#!/usr/bin/env bash
# ============================================================
# post-to-facebook.sh
#
# Multi-property Facebook poster.
# Supports: SkyHouse Sayulita, Villas Sempre Avanti (and future properties)
#
# Photo sourcing priority:
#   1. Bunny CDN (authentic photos — always checked first)
#   2. Pexels API fallback (stock photos for activity content)
#      → Downloads and SAVES to Bunny CDN for future reuse
#   3. Hard fail for property-specific folders (real photos required)
#
# pending-post JSON schema:
#   property      — "skyhouse" | "casasempreavanti" (default: skyhouse)
#   caption       — the post text
#   photo_folder  — logical category (e.g. "Surf", "Villa Luisa")
#   num_photos    — photos to attach (default: 3)
#   pexels_query  — optional: override auto Pexels search term
#
# PENDING_FILE env var overrides the default pending-post.json path.
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREDS_FILE="$SCRIPT_DIR/credentials.local.json"
PENDING_FILE="${PENDING_FILE:-$SCRIPT_DIR/pending-post.json}"

# ── Read post details ─────────────────────────────────────────
CAPTION=$(jq -r '.caption' "$PENDING_FILE")
PHOTO_FOLDER=$(jq -r '.photo_folder' "$PENDING_FILE")
NUM_PHOTOS=$(jq -r '.num_photos // 3' "$PENDING_FILE")
PEXELS_QUERY_OVERRIDE=$(jq -r '.pexels_query // empty' "$PENDING_FILE")
PROPERTY=$(jq -r '.property // "skyhouse"' "$PENDING_FILE")

if [ -z "$CAPTION" ] || [ "$CAPTION" = "null" ] || \
   [ -z "$PHOTO_FOLDER" ] || [ "$PHOTO_FOLDER" = "null" ]; then
  echo "ERROR: pending-post JSON is missing caption or photo_folder"
  exit 1
fi

echo "=== Facebook Post Creator ==="
echo "  Property:  $PROPERTY"
echo "  Category:  $PHOTO_FOLDER"
echo "  Photos:    $NUM_PHOTOS"
echo "  Caption:   ${CAPTION:0:80}..."
echo ""

FB_API="https://graph.facebook.com/v19.0"
BUNNY_STORAGE_API="https://la.storage.bunnycdn.com"

# ── Property routing ──────────────────────────────────────────
IS_SKYHOUSE=false
IS_PROPERTY_FOLDER=false

case "$PROPERTY" in

  "casasempreavanti"|"villas_sempre_avanti")
    FB_ACCESS_TOKEN=$(jq -r '.facebook.pages.casasempreavanti.accessToken' "$CREDS_FILE")
    FB_PAGE_ID=$(jq -r '.facebook.pages.casasempreavanti.pageId' "$CREDS_FILE")
    BUNNY_CSA_KEY=$(jq -r '.bunny.casasempreavanti.storageApiKey' "$CREDS_FILE")
    BUNNY_SAY_KEY=$(jq -r '.bunny.sayulita_shared.storageApiKey' "$CREDS_FILE")
    PEXELS_API_KEY=$(jq -r '.pexels.apiKey // empty' "$CREDS_FILE")

    # Villa-specific folders → use villassempreavanti zone; hard fail if empty
    # Activity folders → fall back to sayulitaandbeyond zone (same area, same activities)
    case "$PHOTO_FOLDER" in
      "Villa Luisa"|"Villa Pietro"|"Villas Sempre Avanti")
        IS_PROPERTY_FOLDER=true
        BUNNY_ZONE="villassempreavanti"
        BUNNY_KEY="$BUNNY_CSA_KEY"
        BUNNY_CDN_HOST="VillasSempreAvanti.b-cdn.net"
        BUNNY_SUBFOLDER="$PHOTO_FOLDER/"
        ;;
      *)
        # Activity categories — sayulitaandbeyond has same local photos
        BUNNY_ZONE="sayulitaandbeyond"
        BUNNY_KEY="$BUNNY_SAY_KEY"
        BUNNY_CDN_HOST="sayulitaandbeyond.b-cdn.net"
        BUNNY_SUBFOLDER="$PHOTO_FOLDER/"
        ;;
    esac
    BUNNY_SUBFOLDER_ENC="${BUNNY_SUBFOLDER// /%20}"
    ;;

  *)  # Default: SkyHouse Sayulita
    IS_SKYHOUSE=true
    FB_ACCESS_TOKEN=$(jq -r '.facebook.pages.skyhouse_sayulita.accessToken' "$CREDS_FILE")
    FB_PAGE_ID=$(jq -r '.facebook.pages.skyhouse_sayulita.pageId' "$CREDS_FILE")
    BUNNY_SKYHOUSE_KEY=$(jq -r '.bunny.skyhouse.storageApiKey' "$CREDS_FILE")
    BUNNY_SAYULITA_KEY=$(jq -r '.bunny.sayulita_shared.storageApiKey' "$CREDS_FILE")
    PEXELS_API_KEY=$(jq -r '.pexels.apiKey // empty' "$CREDS_FILE")

    if [ "$PHOTO_FOLDER" = "SkyHouse" ]; then
      BUNNY_ZONE="skyhousesayulita"
      BUNNY_KEY="$BUNNY_SKYHOUSE_KEY"
      BUNNY_CDN_HOST="SkyhouseSayulita.b-cdn.net"
      BUNNY_SUBFOLDER=""
      BUNNY_SUBFOLDER_ENC=""
      IS_PROPERTY_FOLDER=true
    else
      IS_SKYHOUSE=false
      BUNNY_ZONE="sayulitaandbeyond"
      BUNNY_KEY="$BUNNY_SAYULITA_KEY"
      BUNNY_CDN_HOST="sayulitaandbeyond.b-cdn.net"
      BUNNY_SUBFOLDER="$PHOTO_FOLDER/"
      BUNNY_SUBFOLDER_ENC="${BUNNY_SUBFOLDER// /%20}"
    fi
    ;;
esac

# ── Recursive Bunny scanner (up to 3 levels deep) ────────────
scan_bunny_dir() {
  local base_prefix="$1"
  local enc_prefix="$2"
  local depth="$3"
  [ "$depth" -gt 3 ] && return

  local resp
  resp=$(curl -s --max-time 10 \
    -H "AccessKey: $BUNNY_KEY" \
    "$BUNNY_STORAGE_API/$BUNNY_ZONE/$BUNNY_SUBFOLDER_ENC$enc_prefix")

  echo "$resp" | \
    jq -r --arg p "$base_prefix" \
      '.[] | select(.IsDirectory == false) | select(.ObjectName | test("\\.(jpg|jpeg|png|webp|heic|tiff|bmp)$"; "i")) | $p + .ObjectName' \
    2>/dev/null || true

  local subdirs
  subdirs=$(echo "$resp" | jq -r '.[] | select(.IsDirectory == true) | .ObjectName' 2>/dev/null || true)
  while IFS= read -r sd; do
    [ -z "$sd" ] && continue
    scan_bunny_dir "$base_prefix$sd/" "${sd// /%20}/" $(( depth + 1 ))
  done <<< "$subdirs"
}

# ── Step 1: Scan Bunny CDN ────────────────────────────────────
echo "--- Scanning Bunny CDN ($BUNNY_ZONE/$BUNNY_SUBFOLDER) ---"
IMAGE_FILES=$(scan_bunny_dir "" "" 1)

BUNNY_COUNT=0
[ -n "$IMAGE_FILES" ] && BUNNY_COUNT=$(printf '%s\n' "$IMAGE_FILES" | grep -c '[^[:space:]]' || true)
BUNNY_COUNT=${BUNNY_COUNT:-0}
echo "  Found $BUNNY_COUNT images in Bunny CDN"

# ── Step 2: Pexels fallback — fetch AND save to Bunny ─────────
PEXELS_USED=false
if [ "$BUNNY_COUNT" -eq 0 ]; then

  # Hard stop for property-specific folders — never use stock photos for actual villa
  if [ "$IS_PROPERTY_FOLDER" = "true" ]; then
    ZONE_DISPLAY="${BUNNY_ZONE}/${BUNNY_SUBFOLDER}"
    echo ""
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║  STOP: Property folder is empty.                    ║"
    echo "║  Folder: $ZONE_DISPLAY"
    echo "║  Stock photos cannot be used for property shots.    ║"
    echo "║  Upload real photos to Bunny CDN first.             ║"
    echo "╚══════════════════════════════════════════════════════╝"
    exit 1
  fi

  if [ -z "$PEXELS_API_KEY" ]; then
    echo "ERROR: Bunny CDN empty and PEXELS_API_KEY not set."
    echo "Add it to GitHub → Settings → Secrets → PEXELS_API_KEY"
    exit 1
  fi

  # Build search query
  if [ -n "$PEXELS_QUERY_OVERRIDE" ]; then
    PEXELS_QUERY="$PEXELS_QUERY_OVERRIDE"
  else
    case "$PHOTO_FOLDER" in
      # VSA-specific categories
      "Villa Luisa")           PEXELS_QUERY="luxury beachfront villa pool Mexico tropical" ;;
      "Villa Pietro")          PEXELS_QUERY="luxury villa ocean view Mexico intimate pool" ;;
      "Villas Sempre Avanti")  PEXELS_QUERY="luxury estate beachfront Mexico Riviera Nayarit" ;;
      # Shared Sayulita/Riviera Nayarit categories
      "Surf")                  PEXELS_QUERY="surfing Mexico Pacific waves beach" ;;
      "Yoga")                  PEXELS_QUERY="yoga beach sunrise Mexico tropical" ;;
      "Restaurants")           PEXELS_QUERY="Mexican food tacos street food" ;;
      "Marieta Islands")       PEXELS_QUERY="Marieta Islands hidden beach Mexico" ;;
      "Monkey Mountain")       PEXELS_QUERY="jungle hiking Mexico wildlife monkeys" ;;
      "Golf")                  PEXELS_QUERY="golf course tropical Mexico ocean" ;;
      "Fishing Charter")       PEXELS_QUERY="deep sea fishing Mexico Pacific" ;;
      "Whale Tours")           PEXELS_QUERY="humpback whale ocean Mexico Pacific" ;;
      "SUP")                   PEXELS_QUERY="stand up paddleboard ocean tropical" ;;
      "Ally Cat")              PEXELS_QUERY="sailing catamaran Mexico Pacific sunset" ;;
      "CachaSol")              PEXELS_QUERY="Mexico agave tequila distillery farm" ;;
      "Local Cultural")        PEXELS_QUERY="Mexico culture festival artisan market" ;;
      "Wellness")              PEXELS_QUERY="wellness yoga sound healing meditation beach" ;;
      "Boats")                 PEXELS_QUERY="boat sailing Mexico Pacific catamaran" ;;
      "Land Adventures")       PEXELS_QUERY="ATV adventure Mexico jungle coastal" ;;
      "Weddings")              PEXELS_QUERY="beach wedding ceremony Mexico tropical" ;;
      "Chef")                  PEXELS_QUERY="private chef cooking Mexican cuisine beachfront" ;;
      *)                       PEXELS_QUERY="$PHOTO_FOLDER Mexico travel Riviera Nayarit" ;;
    esac
  fi

  echo ""
  echo "--- Pexels fallback: \"$PEXELS_QUERY\" ---"
  ENCODED_QUERY=$(printf '%s' "$PEXELS_QUERY" | jq -Rr @uri)
  PEXELS_RESP=$(curl -s --max-time 15 \
    -H "Authorization: $PEXELS_API_KEY" \
    "https://api.pexels.com/v1/search?query=$ENCODED_QUERY&per_page=20&orientation=landscape")

  PEXELS_ITEMS=$(echo "$PEXELS_RESP" | \
    jq -r '.photos[] | (.id | tostring) + "|||" + (.src.large2x // .src.large)' \
    2>/dev/null || true)

  PEXELS_COUNT=$(printf '%s\n' "$PEXELS_ITEMS" | grep -c '|||' || true)
  PEXELS_COUNT=${PEXELS_COUNT:-0}
  echo "  Found $PEXELS_COUNT Pexels photos"

  if [ "$PEXELS_COUNT" -eq 0 ]; then
    echo "ERROR: No Pexels results for: $PEXELS_QUERY"
    echo "Set pexels_query in pending-post JSON to override."
    exit 1
  fi

  ACTUAL_COUNT=$(( NUM_PHOTOS < PEXELS_COUNT ? NUM_PHOTOS : PEXELS_COUNT ))
  SELECTED_PEXELS=$(printf '%s\n' "$PEXELS_ITEMS" | grep '|||' | shuf -n "$ACTUAL_COUNT")

  echo ""
  echo "--- Downloading from Pexels → saving to Bunny CDN ---"
  echo "  Zone: $BUNNY_ZONE/$BUNNY_SUBFOLDER"
  echo ""

  SAVED_FILENAMES=()
  while IFS= read -r item; do
    [ -z "$item" ] && continue
    PEXELS_ID="${item%%|||*}"
    PEXELS_URL="${item##*|||}"
    FILENAME="pexels-${PEXELS_ID}.jpg"

    echo "  Downloading pexels-$PEXELS_ID ..."
    HTTP_STATUS=$(curl -sL --max-time 30 "$PEXELS_URL" | \
      curl -s -X PUT \
        -H "AccessKey: $BUNNY_KEY" \
        -H "Content-Type: image/jpeg" \
        --data-binary @- \
        -w "%{http_code}" \
        -o /dev/null \
        "$BUNNY_STORAGE_API/$BUNNY_ZONE/$BUNNY_SUBFOLDER_ENC$FILENAME")

    if [ "$HTTP_STATUS" = "201" ] || [ "$HTTP_STATUS" = "200" ]; then
      echo "  ✓ Saved to Bunny: $BUNNY_SUBFOLDER$FILENAME (HTTP $HTTP_STATUS)"
      SAVED_FILENAMES+=("$FILENAME")
    else
      echo "  ✗ Bunny upload failed (HTTP $HTTP_STATUS) — using Pexels URL directly"
      SAVED_FILENAMES+=("__pexels_direct__$PEXELS_URL")
    fi
  done <<< "$SELECTED_PEXELS"

  PEXELS_USED=true
  IMAGE_FILES=$(printf '%s\n' "${SAVED_FILENAMES[@]}")
  ACTUAL_COUNT=${#SAVED_FILENAMES[@]}

else
  ACTUAL_COUNT=$(( NUM_PHOTOS < BUNNY_COUNT ? NUM_PHOTOS : BUNNY_COUNT ))
fi

# ── Step 3: Select from Bunny pool (if not already selected) ──
if [ "$PEXELS_USED" = "false" ]; then
  echo ""
  echo "--- Selecting $ACTUAL_COUNT photos from Bunny ---"
  IMAGE_FILES=$(printf '%s\n' "$IMAGE_FILES" | grep '[^[:space:]]' | shuf -n "$ACTUAL_COUNT")
fi

[ "$PEXELS_USED" = "true" ] && echo ""
[ "$PEXELS_USED" = "true" ] && echo "⚠️  Pexels used — photos now saved in Bunny for future reuse."

# ── Step 4: Upload each photo to Facebook (unpublished) ───────
echo ""
echo "--- Uploading to Facebook (page: $FB_PAGE_ID) ---"
PHOTO_IDS=()

while IFS= read -r item; do
  [ -z "$item" ] && continue

  if [[ "$item" == __pexels_direct__* ]]; then
    CDN_URL="${item#__pexels_direct__}"
  else
    ENCODED_ITEM="${item// /%20}"
    CDN_URL="https://$BUNNY_CDN_HOST/${BUNNY_SUBFOLDER_ENC}${ENCODED_ITEM}"
  fi

  echo "  → $(basename "$CDN_URL" | cut -c1-60)"

  UPLOAD_RESP=$(curl -s -X POST \
    "$FB_API/$FB_PAGE_ID/photos" \
    -F "url=$CDN_URL" \
    -F "published=false" \
    -F "access_token=$FB_ACCESS_TOKEN")

  PHOTO_ID=$(echo "$UPLOAD_RESP" | jq -r '.id // empty')
  if [ -z "$PHOTO_ID" ]; then
    echo "  ERROR: $UPLOAD_RESP"
    exit 1
  fi
  echo "  ✓ ID: $PHOTO_ID"
  PHOTO_IDS+=("$PHOTO_ID")
done <<< "$IMAGE_FILES"

# ── Step 5: Build attached_media JSON ─────────────────────────
MEDIA_JSON="["
for i in "${!PHOTO_IDS[@]}"; do
  [ "$i" -gt 0 ] && MEDIA_JSON+=","
  MEDIA_JSON+="{\"media_fbid\":\"${PHOTO_IDS[$i]}\"}"
done
MEDIA_JSON+="]"

# ── Step 6: Publish to Facebook ───────────────────────────────
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
[ "$PEXELS_USED" = "true" ] && echo "  📦 $ACTUAL_COUNT photos saved to $BUNNY_ZONE/$BUNNY_SUBFOLDER for reuse"
echo "=== DONE ==="
