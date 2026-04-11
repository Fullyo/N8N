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

# ── Exchange user token for page token ───────────────────────
# If the stored token is a long-lived USER token, /me/accounts returns
# permanent PAGE tokens. Page tokens are required for published=false uploads.
exchange_for_page_token() {
  local user_token="$1"
  local page_id="$2"
  local resp
  resp=$(curl -s --max-time 10 \
    "$FB_API/me/accounts?access_token=$user_token")
  local page_token
  page_token=$(echo "$resp" | jq -r --arg id "$page_id" \
    '.data[]? | select(.id == $id) | .access_token // empty' 2>/dev/null || true)
  echo "$page_token"
}

# ── Property routing ──────────────────────────────────────────
IS_SKYHOUSE=false
IS_PROPERTY_FOLDER=false

case "$PROPERTY" in

  "casasempreavanti"|"villas_sempre_avanti")
    FB_ACCESS_TOKEN=$(jq -r '.facebook.pages.casasempreavanti.accessToken' "$CREDS_FILE")
    FB_PAGE_ID=$(jq -r '.facebook.pages.casasempreavanti.pageId' "$CREDS_FILE")
    BUNNY_CSA_KEY=$(jq -r '.bunny.casasempreavanti.storageApiKey' "$CREDS_FILE")
    BUNNY_SAY_KEY=$(jq -r '.bunny.sayulita_shared.storageApiKey' "$CREDS_FILE")
    # Auto-exchange user token → page token (required for unpublished photo uploads)
    PAGE_TOKEN=$(exchange_for_page_token "$FB_ACCESS_TOKEN" "$FB_PAGE_ID")
    if [ -n "$PAGE_TOKEN" ]; then
      echo "  ✓ Exchanged user token for page token"
      FB_ACCESS_TOKEN="$PAGE_TOKEN"
    else
      echo "  ⚠ Could not get page token — using stored token as-is"
    fi
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

  "moroccan_palace"|"the_moroccan_palace")
    FB_ACCESS_TOKEN=$(jq -r '.facebook.pages.moroccan_palace.accessToken' "$CREDS_FILE")
    FB_PAGE_ID=$(jq -r '.facebook.pages.moroccan_palace.pageId' "$CREDS_FILE")
    BUNNY_MP_KEY=$(jq -r '.bunny.themoroccanpalace.storageApiKey // empty' "$CREDS_FILE")
    PEXELS_API_KEY=$(jq -r '.pexels.apiKey // empty' "$CREDS_FILE")
    PAGE_TOKEN=$(exchange_for_page_token "$FB_ACCESS_TOKEN" "$FB_PAGE_ID")
    if [ -n "$PAGE_TOKEN" ]; then
      echo "  ✓ Exchanged user token for page token"
      FB_ACCESS_TOKEN="$PAGE_TOKEN"
    else
      echo "  ⚠ Could not get page token — using stored token as-is"
    fi
    # Property folders → themoroccanpalace zone, direct subfolder
    # La Ventana / Baja activity folders → themoroccanpalace zone, under "La Ventana/" subfolder
    case "$PHOTO_FOLDER" in
      "Riad"|"Pool"|"Rooftop"|"Interiors"|"The Moroccan Palace"|"Glamping"|"Villa")
        IS_PROPERTY_FOLDER=true
        BUNNY_ZONE="themoroccanpalace"
        BUNNY_KEY="$BUNNY_MP_KEY"
        BUNNY_CDN_HOST="themoroccanpalace.b-cdn.net"
        BUNNY_SUBFOLDER="$PHOTO_FOLDER/"
        ;;
      *)
        # Baja/La Ventana activities — cached under La Ventana/ subfolder
        BUNNY_ZONE="themoroccanpalace"
        BUNNY_KEY="$BUNNY_MP_KEY"
        BUNNY_CDN_HOST="themoroccanpalace.b-cdn.net"
        BUNNY_SUBFOLDER="La Ventana/$PHOTO_FOLDER/"
        ;;
    esac
    BUNNY_SUBFOLDER_ENC="${BUNNY_SUBFOLDER// /%20}"
    # themoroccanpalace zone is in the default region (Frankfurt), not LA
    BUNNY_STORAGE_API="https://storage.bunnycdn.com"
    ;;

  "lux"|"lux_property_management")
    FB_ACCESS_TOKEN=$(jq -r '.facebook.pages.lux_property_management.accessToken' "$CREDS_FILE")
    FB_PAGE_ID=$(jq -r '.facebook.pages.lux_property_management.pageId' "$CREDS_FILE")
    BUNNY_LUX_KEY=$(jq -r '.bunny.lux.storageApiKey // empty' "$CREDS_FILE")
    BUNNY_SAY_KEY=$(jq -r '.bunny.sayulita_shared.storageApiKey' "$CREDS_FILE")
    PEXELS_API_KEY=$(jq -r '.pexels.apiKey // empty' "$CREDS_FILE")
    PAGE_TOKEN=$(exchange_for_page_token "$FB_ACCESS_TOKEN" "$FB_PAGE_ID")
    if [ -n "$PAGE_TOKEN" ]; then
      echo "  ✓ Exchanged user token for page token"
      FB_ACCESS_TOKEN="$PAGE_TOKEN"
    else
      echo "  ⚠ Could not get page token — using stored token as-is"
    fi
    # LUX is B2B/owner-facing — stock photos are fine for all categories
    # Use sayulitaandbeyond zone to cache Pexels photos, lux/ subfolder
    BUNNY_ZONE="sayulitaandbeyond"
    BUNNY_KEY="$BUNNY_SAY_KEY"
    BUNNY_CDN_HOST="sayulitaandbeyond.b-cdn.net"
    BUNNY_SUBFOLDER="lux/$PHOTO_FOLDER/"
    BUNNY_SUBFOLDER_ENC="${BUNNY_SUBFOLDER// /%20}"
    ;;

  *)  # Default: SkyHouse Sayulita
    IS_SKYHOUSE=true
    FB_ACCESS_TOKEN=$(jq -r '.facebook.pages.skyhouse_sayulita.accessToken' "$CREDS_FILE")
    FB_PAGE_ID=$(jq -r '.facebook.pages.skyhouse_sayulita.pageId' "$CREDS_FILE")
    BUNNY_SKYHOUSE_KEY=$(jq -r '.bunny.skyhouse.storageApiKey' "$CREDS_FILE")
    BUNNY_SAYULITA_KEY=$(jq -r '.bunny.sayulita_shared.storageApiKey' "$CREDS_FILE")
    PEXELS_API_KEY=$(jq -r '.pexels.apiKey // empty' "$CREDS_FILE")
    # Auto-exchange user token → page token
    PAGE_TOKEN=$(exchange_for_page_token "$FB_ACCESS_TOKEN" "$FB_PAGE_ID")
    if [ -n "$PAGE_TOKEN" ]; then
      echo "  ✓ Exchanged user token for page token"
      FB_ACCESS_TOKEN="$PAGE_TOKEN"
    else
      echo "  ⚠ Could not get page token — using stored token as-is"
    fi

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

# ── Step 2: Internet fallback (Google Images → Pexels) ───────────
INTERNET_USED=false
SOURCE_LABEL=""

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

  # ── Build search query ──────────────────────────────────────────
  if [ -n "$PEXELS_QUERY_OVERRIDE" ]; then
    SEARCH_QUERY="$PEXELS_QUERY_OVERRIDE"
  else
    case "$PHOTO_FOLDER" in
      # VSA-specific categories
      "Villa Luisa")           SEARCH_QUERY="luxury beachfront villa pool Mexico tropical" ;;
      "Villa Pietro")          SEARCH_QUERY="luxury villa ocean view Mexico intimate pool" ;;
      "Villas Sempre Avanti")  SEARCH_QUERY="luxury estate beachfront Mexico Riviera Nayarit" ;;
      # Shared Sayulita/Riviera Nayarit categories
      "Surf")                  SEARCH_QUERY="surfing Mexico Pacific waves beach" ;;
      "Yoga")                  SEARCH_QUERY="yoga beach sunrise Mexico tropical" ;;
      "Restaurants")           SEARCH_QUERY="Mexican food tacos street food" ;;
      "Marieta Islands")       SEARCH_QUERY="Marieta Islands hidden beach Mexico" ;;
      "Monkey Mountain")       SEARCH_QUERY="jungle hiking Mexico wildlife monkeys" ;;
      "Golf")                  SEARCH_QUERY="golf course tropical Mexico ocean" ;;
      "Fishing Charter")       SEARCH_QUERY="deep sea fishing Mexico Pacific" ;;
      "Whale Tours")           SEARCH_QUERY="humpback whale ocean Mexico Pacific" ;;
      "SUP")                   SEARCH_QUERY="stand up paddleboard ocean tropical" ;;
      "Ally Cat")              SEARCH_QUERY="sailing catamaran Mexico Pacific sunset" ;;
      "CachaSol")              SEARCH_QUERY="Mexico agave tequila distillery farm" ;;
      "Local Cultural")        SEARCH_QUERY="Mexico culture festival artisan market" ;;
      "Wellness")              SEARCH_QUERY="wellness yoga sound healing meditation beach" ;;
      "Boats")                 SEARCH_QUERY="boat sailing Mexico Pacific catamaran" ;;
      "Land Adventures")       SEARCH_QUERY="ATV adventure Mexico jungle coastal" ;;
      "Weddings")              SEARCH_QUERY="beach wedding ceremony Mexico tropical" ;;
      "Chef")                  SEARCH_QUERY="private chef cooking Mexican cuisine beachfront" ;;
      # Moroccan Palace / La Ventana / Baja California Sur — location-specific
      "Kite Surfing"|"Kite & Adventure") SEARCH_QUERY="kite surfing La Ventana Baja California Sea of Cortez Mexico" ;;
      "Diving")                SEARCH_QUERY="scuba diving Sea of Cortez Baja California whale sharks manta rays" ;;
      "Snorkeling")            SEARCH_QUERY="snorkeling Sea of Cortez Baja California sea lions clear water" ;;
      "Whale Sharks")          SEARCH_QUERY="whale shark Sea of Cortez Espiritu Santo Baja California Mexico" ;;
      "Sea Lions")             SEARCH_QUERY="sea lions Los Islotes La Paz Baja California Sea of Cortez" ;;
      "Beaches")               SEARCH_QUERY="La Ventana El Sargento beach Baja California Sur Mexico" ;;
      "The Villa")             SEARCH_QUERY="luxury villa rooftop pool Sea of Cortez Baja California Mexico" ;;
      "Glamping")              SEARCH_QUERY="glamping tent Baja California desert Mexico stars outdoor" ;;
      "Baja & Destination")    SEARCH_QUERY="El Sargento La Ventana Baja California Sur Sea of Cortez landscape" ;;
      "Events & Celebrations") SEARCH_QUERY="outdoor event celebration Sea of Cortez Baja Mexico rooftop" ;;
      # LUX Property Management
      "Portfolio")             SEARCH_QUERY="luxury villa portfolio property management ocean" ;;
      "Brand")                 SEARCH_QUERY="luxury property management lifestyle concierge" ;;
      *)                       SEARCH_QUERY="$PHOTO_FOLDER luxury travel lifestyle Mexico" ;;
    esac
  fi

  INTERNET_URLS=()

  # ── Try Google Custom Search first ──────────────────────────────
  GOOGLE_API_KEY=$(jq -r '.google.searchApiKey // empty' "$CREDS_FILE")
  GOOGLE_CX="56a321af92e894e8c"
  if [ -n "$GOOGLE_API_KEY" ]; then
    echo ""
    echo "--- Google Image Search: \"$SEARCH_QUERY\" ---"
    ENCODED_QUERY=$(printf '%s' "$SEARCH_QUERY" | jq -Rr @uri)
    GOOGLE_RESP=$(curl -s --max-time 15 \
      "https://www.googleapis.com/customsearch/v1?q=${ENCODED_QUERY}&cx=${GOOGLE_CX}&searchType=image&num=10&key=${GOOGLE_API_KEY}")

    mapfile -t GOOGLE_URLS < <(echo "$GOOGLE_RESP" | jq -r '.items[]? | .link' 2>/dev/null | grep '^http')
    GOOGLE_COUNT=${#GOOGLE_URLS[@]}
    echo "  Found $GOOGLE_COUNT Google images"

    if [ "$GOOGLE_COUNT" -gt 0 ]; then
      INTERNET_URLS=("${GOOGLE_URLS[@]}")
      SOURCE_LABEL="Google"
    fi
  fi

  # ── Pexels fallback if Google unavailable or returned nothing ───
  if [ "${#INTERNET_URLS[@]}" -eq 0 ]; then
    if [ -z "$PEXELS_API_KEY" ]; then
      echo "ERROR: Bunny empty, Google unavailable, and PEXELS_API_KEY not set."
      exit 1
    fi
    echo ""
    echo "--- Pexels fallback: \"$SEARCH_QUERY\" ---"
    ENCODED_QUERY=$(printf '%s' "$SEARCH_QUERY" | jq -Rr @uri)
    PEXELS_RESP=$(curl -s --max-time 15 \
      -H "Authorization: $PEXELS_API_KEY" \
      "https://api.pexels.com/v1/search?query=$ENCODED_QUERY&per_page=20&orientation=landscape")

    mapfile -t PEXELS_URLS < <(echo "$PEXELS_RESP" | \
      jq -r '.photos[] | (.id | tostring) + "|||" + (.src.large2x // .src.large)' \
      2>/dev/null | grep '|||')
    PEXELS_COUNT=${#PEXELS_URLS[@]}
    echo "  Found $PEXELS_COUNT Pexels photos"

    if [ "$PEXELS_COUNT" -eq 0 ]; then
      echo "ERROR: No results from Pexels for: $SEARCH_QUERY"
      exit 1
    fi
    INTERNET_URLS=("${PEXELS_URLS[@]}")
    SOURCE_LABEL="Pexels"
  fi

  # ── Download and save to Bunny CDN ──────────────────────────────
  ACTUAL_COUNT=$(( NUM_PHOTOS < ${#INTERNET_URLS[@]} ? NUM_PHOTOS : ${#INTERNET_URLS[@]} ))
  mapfile -t SELECTED < <(printf '%s\n' "${INTERNET_URLS[@]}" | shuf -n "$ACTUAL_COUNT")

  echo ""
  echo "--- Downloading from $SOURCE_LABEL → saving to Bunny CDN ---"
  echo "  Zone: $BUNNY_ZONE/$BUNNY_SUBFOLDER"
  echo ""

  SAVED_FILENAMES=()
  IDX=0
  for item in "${SELECTED[@]}"; do
    [ -z "$item" ] && continue
    IDX=$(( IDX + 1 ))

    if [[ "$item" == *"|||"* ]]; then
      # Pexels format: id|||url
      PEXELS_ID="${item%%|||*}"
      IMG_URL="${item##*|||}"
      FILENAME="pexels-${PEXELS_ID}.jpg"
    else
      # Google or other direct URL
      IMG_URL="$item"
      RAW_EXT="${IMG_URL##*.}"
      EXT="${RAW_EXT%%\?*}"
      [[ "$EXT" =~ ^(jpg|jpeg|png|webp)$ ]] || EXT="jpg"
      FILENAME="google-$(date +%s)-${IDX}.${EXT}"
    fi

    echo "  Downloading $(basename "$IMG_URL" | cut -c1-50) ..."
    HTTP_STATUS=$(curl -sL --max-time 30 "$IMG_URL" | \
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
      echo "  ✗ Bunny upload failed (HTTP $HTTP_STATUS) — using direct URL"
      SAVED_FILENAMES+=("__direct__$IMG_URL")
    fi
  done

  INTERNET_USED=true
  IMAGE_FILES=$(printf '%s\n' "${SAVED_FILENAMES[@]}")
  ACTUAL_COUNT=${#SAVED_FILENAMES[@]}

else
  ACTUAL_COUNT=$(( NUM_PHOTOS < BUNNY_COUNT ? NUM_PHOTOS : BUNNY_COUNT ))
fi

# ── Step 3: Select from Bunny pool (if not already selected) ──
if [ "$INTERNET_USED" = "false" ]; then
  echo ""
  echo "--- Selecting $ACTUAL_COUNT photos from Bunny ---"
  IMAGE_FILES=$(printf '%s\n' "$IMAGE_FILES" | grep '[^[:space:]]' | shuf -n "$ACTUAL_COUNT")
fi

[ "$INTERNET_USED" = "true" ] && echo ""
[ "$INTERNET_USED" = "true" ] && echo "⚠️  $SOURCE_LABEL used — photos now saved in Bunny for future reuse."

# ── Step 4: Upload each photo to Facebook (unpublished) ───────
echo ""
echo "--- Uploading to Facebook (page: $FB_PAGE_ID) ---"
PHOTO_IDS=()

while IFS= read -r item; do
  [ -z "$item" ] && continue

  if [[ "$item" == __direct__* ]]; then
    CDN_URL="${item#__direct__}"
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
[ "${INTERNET_USED:-false}" = "true" ] && echo "  📦 $ACTUAL_COUNT photos saved to $BUNNY_ZONE/$BUNNY_SUBFOLDER for reuse"
echo "=== DONE ==="
