#!/usr/bin/env bash
# ============================================================
# generate-reel.sh — Ken Burns slideshow Reel from Bunny CDN
# Pulls property photos → FFmpeg Ken Burns → Bunny CDN → Facebook video post
#
# Environment variables:
#   PROPERTY        — skyhouse | vsa | moroccanpalace | lux (required)
#   CREDS_FILE      — path to credentials.local.json
#   NUM_PHOTOS      — number of photos in the reel (default: 6)
#   CAPTION         — override caption (if empty, Claude generates one)
#   PHOTO_FOLDER    — override Bunny subfolder (optional)
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREDS_FILE="${CREDS_FILE:-$SCRIPT_DIR/credentials.local.json}"
PROPERTY="${PROPERTY:-skyhouse}"
NUM_PHOTOS="${NUM_PHOTOS:-6}"
CAPTION="${CAPTION:-}"
PHOTO_FOLDER_OVERRIDE="${PHOTO_FOLDER:-}"

# Video settings
PHOTO_DURATION=5          # seconds each photo is shown
CROSSFADE_DUR=0.5         # seconds for crossfade transition between photos
MUSIC_VOLUME=0.22         # 0.0–1.0 (quiet enough not to compete with content)
TARGET_FPS=25
RESOLUTION="1920x1080"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

LOG_FILE="${SCRIPT_DIR}/_reel-debug-${PROPERTY}.log"
exec > >(tee "$LOG_FILE") 2>&1

echo "=== Reel Generator ==="
echo "  Property: $PROPERTY"
echo "  Photos:   $NUM_PHOTOS × ${PHOTO_DURATION}s = $((NUM_PHOTOS * PHOTO_DURATION))s raw"
echo ""

# ── Property config ──────────────────────────────────────────────────
case "$PROPERTY" in
  skyhouse|skyhouse_sayulita)
    BUNNY_ZONE="skyhousesayulita"
    BUNNY_KEY=$(jq -r '.bunny.skyhouse.storageApiKey' "$CREDS_FILE")
    BUNNY_CDN="SkyhouseSayulita.b-cdn.net"
    BUNNY_STORAGE="https://la.storage.bunnycdn.com"
    DEFAULT_SUBFOLDER=""
    FB_PAGE_ID="1004908006045909"
    FB_TOKEN=$(jq -r '.facebook.pages.skyhouse_sayulita.accessToken' "$CREDS_FILE")
    PROPERTY_NAME="SkyHouse Sayulita"
    LOCATION="Sayulita, Nayarit, Mexico"
    BRAND_VOICE="luxury surf lifestyle, relaxed and aspirational"
    ;;
  vsa|casasempreavanti|villas_sempre_avanti)
    BUNNY_ZONE="villassempreavanti"
    BUNNY_KEY=$(jq -r '.bunny.casasempreavanti.storageApiKey' "$CREDS_FILE")
    BUNNY_CDN="VillasSempreAvanti.b-cdn.net"
    BUNNY_STORAGE="https://la.storage.bunnycdn.com"
    DEFAULT_SUBFOLDER="Villa Luisa/"
    FB_PAGE_ID="350547805544245"
    FB_TOKEN=$(jq -r '.facebook.pages.casasempreavanti.accessToken' "$CREDS_FILE")
    PROPERTY_NAME="Villas Sempre Avanti"
    LOCATION="Sayulita, Nayarit, Mexico"
    BRAND_VOICE="Italian-Mexican villa character, warm and welcoming for groups"
    ;;
  moroccanpalace|moroccan_palace)
    BUNNY_ZONE="themoroccanpalace"
    BUNNY_KEY=$(jq -r '.bunny.themoroccanpalace.storageApiKey // empty' "$CREDS_FILE")
    if [ -z "$BUNNY_KEY" ] && [ -f "$SCRIPT_DIR/fb-tokens.json" ]; then
      BUNNY_KEY=$(jq -r '.bunny.themoroccanpalace.storageApiKey // empty' "$SCRIPT_DIR/fb-tokens.json")
    fi
    BUNNY_CDN="themoroccanpalace.b-cdn.net"
    BUNNY_STORAGE="https://storage.bunnycdn.com"   # Frankfurt zone
    DEFAULT_SUBFOLDER="Pool/"
    FB_PAGE_ID="954938847703306"
    FB_TOKEN=$(jq -r '.facebook.pages.moroccan_palace.accessToken // empty' "$CREDS_FILE")
    if [ -z "$FB_TOKEN" ] && [ -f "$SCRIPT_DIR/fb-tokens.json" ]; then
      FB_TOKEN=$(jq -r '.facebook.moroccan_palace.accessToken' "$SCRIPT_DIR/fb-tokens.json")
    fi
    PROPERTY_NAME="The Moroccan Palace"
    LOCATION="El Sargento, Baja California Sur, Mexico"
    BRAND_VOICE="exotic architecture meets Sea of Cortez adventure, unique and memorable"
    ;;
  lux|lux_property_management)
    BUNNY_ZONE="villassempreavanti"
    BUNNY_KEY=$(jq -r '.bunny.casasempreavanti.storageApiKey' "$CREDS_FILE")
    BUNNY_CDN="VillasSempreAvanti.b-cdn.net"
    BUNNY_STORAGE="https://la.storage.bunnycdn.com"
    DEFAULT_SUBFOLDER="Villa Luisa/"
    FB_PAGE_ID="999599493240965"
    FB_TOKEN=$(jq -r '.facebook.pages.lux_property_management.accessToken // empty' "$CREDS_FILE")
    if [ -z "$FB_TOKEN" ] && [ -f "$SCRIPT_DIR/fb-tokens.json" ]; then
      FB_TOKEN=$(jq -r '.facebook.lux_property_management.accessToken' "$SCRIPT_DIR/fb-tokens.json")
    fi
    PROPERTY_NAME="LUX Property Management"
    LOCATION="Riviera Nayarit, Mexico"
    BRAND_VOICE="professional luxury property management, owner-facing and results-focused"
    ;;
  *)
    echo "ERROR: Unknown property: $PROPERTY" >&2
    exit 1
    ;;
esac

BUNNY_SUBFOLDER="${PHOTO_FOLDER_OVERRIDE:-$DEFAULT_SUBFOLDER}"

# ── Exchange user token for page token ───────────────────────────────
echo "--- Getting page token ---"
PAGE_ACCOUNTS=$(curl -s "https://graph.facebook.com/v19.0/me/accounts?access_token=${FB_TOKEN}" || true)
PAGE_TOKEN=$(echo "$PAGE_ACCOUNTS" | jq -r --arg pid "$FB_PAGE_ID" \
  '.data[]? | select(.id == $pid) | .access_token' 2>/dev/null | head -1 || true)
if [ -z "$PAGE_TOKEN" ]; then
  echo "  ⚠ Could not get page token — using stored token"
  PAGE_TOKEN="$FB_TOKEN"
else
  echo "  ✓ Page token obtained"
fi

# ── Fetch photo list from Bunny CDN ──────────────────────────────────
echo ""
echo "--- Scanning Bunny CDN ($BUNNY_ZONE/${BUNNY_SUBFOLDER}) ---"
LIST_JSON=$(curl -s -H "AccessKey: $BUNNY_KEY" \
  "${BUNNY_STORAGE}/${BUNNY_ZONE}/${BUNNY_SUBFOLDER}" || echo "[]")

PHOTO_FILES=$(echo "$LIST_JSON" | jq -r \
  '.[] | select(.IsDirectory == false) | select(.ObjectName | test("\\.(jpg|jpeg|png)$"; "i")) | .ObjectName' \
  2>/dev/null || true)

if [ -z "$PHOTO_FILES" ]; then
  echo "ERROR: No photos found at ${BUNNY_ZONE}/${BUNNY_SUBFOLDER}" >&2
  exit 1
fi

TOTAL=$(echo "$PHOTO_FILES" | wc -l | tr -d ' ')
echo "  Found $TOTAL photos — selecting $NUM_PHOTOS"

SELECTED=$(echo "$PHOTO_FILES" | shuf | head -"$NUM_PHOTOS")

# ── Download photos ───────────────────────────────────────────────────
echo ""
echo "--- Downloading photos ---"
DOWNLOADED_PHOTOS=()
idx=0
while IFS= read -r fname; do
  idx=$((idx + 1))
  local_path="$WORK_DIR/photo_$(printf '%03d' $idx).jpg"
  encoded=$(python3 -c \
    "import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1],safe='/'))" \
    "$fname")
  curl -s -H "AccessKey: $BUNNY_KEY" \
    "${BUNNY_STORAGE}/${BUNNY_ZONE}/${BUNNY_SUBFOLDER}${encoded}" \
    -o "$local_path" || true
  fsize=$(wc -c < "$local_path" 2>/dev/null || echo 0)
  if [ "$fsize" -lt 5000 ]; then
    echo "  ⚠ Skipped (too small): $fname"
    continue
  fi
  echo "  ✓ $(basename "$fname") ($((fsize / 1024))KB)"
  DOWNLOADED_PHOTOS+=("$local_path")
done <<< "$SELECTED"

N=${#DOWNLOADED_PHOTOS[@]}
if [ "$N" -lt 2 ]; then
  echo "ERROR: Only $N usable photos downloaded (need at least 2)" >&2
  exit 1
fi
echo "  → $N photos ready"

# ── Get or cache music ────────────────────────────────────────────────
echo ""
echo "--- Getting background music ---"
MUSIC_FILE="$WORK_DIR/music.mp3"
MUSIC_CDN_PATH="_audio/reel-ambient.mp3"

MUSIC_HTTP=$(curl -s -o "$MUSIC_FILE" -w "%{http_code}" \
  -H "AccessKey: $BUNNY_KEY" \
  "${BUNNY_STORAGE}/${BUNNY_ZONE}/${MUSIC_CDN_PATH}" || echo "000")

if [ "$MUSIC_HTTP" = "200" ] && [ -s "$MUSIC_FILE" ]; then
  echo "  ✓ Using cached music from Bunny CDN"
else
  echo "  Downloading ambient track from Pixabay (CC0)..."
  # Multiple fallback URLs — CC0 royalty-free ambient tracks
  MUSIC_URLS=(
    "https://cdn.pixabay.com/download/audio/2022/10/11/audio_cf8f8b88d1.mp3"
    "https://cdn.pixabay.com/download/audio/2022/08/31/audio_d1718ab41b.mp3"
    "https://cdn.pixabay.com/download/audio/2021/08/04/audio_12b0c7443c.mp3"
  )
  GOT_MUSIC=false
  for url in "${MUSIC_URLS[@]}"; do
    HTTP=$(curl -s -L --max-time 30 -o "$MUSIC_FILE" -w "%{http_code}" "$url" || echo "000")
    if [ "$HTTP" = "200" ] && [ -s "$MUSIC_FILE" ]; then
      GOT_MUSIC=true
      echo "  ✓ Track downloaded"
      # Cache it on Bunny CDN so future runs are instant
      curl -s -X PUT \
        -H "AccessKey: $BUNNY_KEY" \
        -H "Content-Type: audio/mpeg" \
        --data-binary @"$MUSIC_FILE" \
        "${BUNNY_STORAGE}/${BUNNY_ZONE}/${MUSIC_CDN_PATH}" > /dev/null \
        && echo "  ✓ Cached to Bunny CDN for next run" || true
      break
    fi
  done
  if [ "$GOT_MUSIC" = false ]; then
    echo "  ⚠ Music unavailable — reel will be silent"
    MUSIC_FILE=""
  fi
fi

# ── Generate Ken Burns segments ───────────────────────────────────────
echo ""
echo "--- Generating Ken Burns video segments ---"
FRAME_COUNT=$((PHOTO_DURATION * TARGET_FPS))
SEGMENTS=()

for i in "${!DOWNLOADED_PHOTOS[@]}"; do
  photo="${DOWNLOADED_PHOTOS[$i]}"
  seg="$WORK_DIR/seg_$(printf '%03d' $i).mp4"

  # Alternate zoom direction per photo for visual variety
  if (( i % 2 == 0 )); then
    # Even: slow zoom-in, drift right
    ZOOM="min(zoom+0.0012,1.25)"
    PX="iw/2-(iw/zoom/2)+on*0.4"
    PY="ih/2-(ih/zoom/2)"
  else
    # Odd: slow zoom-out, drift left
    ZOOM="if(lte(on\,1)\,1.25\,max(1.001\,zoom-0.0012))"
    PX="iw/2-(iw/zoom/2)-on*0.4"
    PY="ih/2-(ih/zoom/2)"
  fi

  ffmpeg -y -loglevel error \
    -loop 1 -t "$PHOTO_DURATION" -i "$photo" \
    -vf "scale=2600:-2,zoompan=z='${ZOOM}':x='${PX}':y='${PY}':d=${FRAME_COUNT}:s=${RESOLUTION}:fps=${TARGET_FPS}" \
    -c:v libx264 -preset fast -crf 21 -pix_fmt yuv420p \
    -r "$TARGET_FPS" \
    "$seg" 2>&1 | grep -v "^$" || true

  SEGMENTS+=("$seg")
  echo "  ✓ Segment $((i+1))/$N"
done

# ── Concatenate with crossfade transitions ────────────────────────────
echo ""
echo "--- Concatenating $N segments with ${CROSSFADE_DUR}s crossfades ---"
VIDEO_RAW="$WORK_DIR/video_raw.mp4"

if [ "$N" -eq 1 ]; then
  cp "${SEGMENTS[0]}" "$VIDEO_RAW"
else
  # Build xfade filter_complex chain dynamically
  # Offset for transition i = i * (PHOTO_DURATION - CROSSFADE_DUR)
  INPUT_FLAGS=""
  for seg in "${SEGMENTS[@]}"; do
    INPUT_FLAGS+=" -i $seg"
  done

  STEP=$(echo "$PHOTO_DURATION $CROSSFADE_DUR" | awk '{printf "%.2f", $1 - $2}')

  if [ "$N" -eq 2 ]; then
    FILTER="[0:v][1:v]xfade=transition=fade:duration=${CROSSFADE_DUR}:offset=${STEP}[final]"
  else
    FILTER="[0:v][1:v]xfade=transition=fade:duration=${CROSSFADE_DUR}:offset=${STEP}[v1]"
    for (( i=2; i<N; i++ )); do
      PREV="v$((i-1))"
      NEXT="v${i}"
      [ $i -eq $((N-1)) ] && NEXT="final"
      OFFSET=$(echo "$i $STEP" | awk '{printf "%.2f", $1 * $2}')
      FILTER+=";[${PREV}][${i}:v]xfade=transition=fade:duration=${CROSSFADE_DUR}:offset=${OFFSET}[${NEXT}]"
    done
  fi

  # shellcheck disable=SC2086
  ffmpeg -y -loglevel error \
    $INPUT_FLAGS \
    -filter_complex "$FILTER" \
    -map "[final]" \
    -c:v libx264 -preset fast -crf 21 -pix_fmt yuv420p \
    "$VIDEO_RAW"
  echo "  ✓ Segments combined"
fi

# ── Mix in music ──────────────────────────────────────────────────────
FINAL_MP4="$WORK_DIR/reel_final.mp4"

if [ -n "${MUSIC_FILE:-}" ] && [ -f "$MUSIC_FILE" ]; then
  echo ""
  echo "--- Mixing music (volume: ${MUSIC_VOLUME}) ---"
  TOTAL_DUR=$(echo "$N $PHOTO_DURATION $CROSSFADE_DUR" | \
    awk '{printf "%.2f", $1 * $2 - ($1 - 1) * $3}')
  FADE_START=$(echo "$TOTAL_DUR" | awk '{printf "%.2f", $1 - 2.0}')

  ffmpeg -y -loglevel error \
    -i "$VIDEO_RAW" \
    -stream_loop -1 -i "$MUSIC_FILE" \
    -filter_complex \
      "[1:a]volume=${MUSIC_VOLUME},afade=t=in:st=0:d=1.5,afade=t=out:st=${FADE_START}:d=2[mus]" \
    -map 0:v -map "[mus]" \
    -shortest \
    -c:v copy -c:a aac -b:a 128k \
    "$FINAL_MP4"
  echo "  ✓ Music added"
else
  cp "$VIDEO_RAW" "$FINAL_MP4"
  echo "  (No music)"
fi

VIDEO_SIZE=$(wc -c < "$FINAL_MP4" | tr -d ' ')
echo "  Final file: $((VIDEO_SIZE / 1024 / 1024))MB"

# ── Upload video to Bunny CDN ─────────────────────────────────────────
echo ""
echo "--- Uploading video to Bunny CDN ---"
TS=$(date +%Y%m%d_%H%M%S)
REEL_PATH="reels/reel_${PROPERTY}_${TS}.mp4"

curl -s -X PUT \
  -H "AccessKey: $BUNNY_KEY" \
  -H "Content-Type: video/mp4" \
  --data-binary @"$FINAL_MP4" \
  "${BUNNY_STORAGE}/${BUNNY_ZONE}/${REEL_PATH}"

REEL_URL="https://${BUNNY_CDN}/${REEL_PATH}"
echo "  ✓ $REEL_URL"

# ── Generate caption ──────────────────────────────────────────────────
if [ -z "$CAPTION" ]; then
  echo ""
  echo "--- Generating caption via Claude ---"
  ANTHROPIC_KEY=$(jq -r '.anthropic.apiKey' "$CREDS_FILE")
  CAPTION_RESP=$(curl -s https://api.anthropic.com/v1/messages \
    -H "x-api-key: $ANTHROPIC_KEY" \
    -H "anthropic-version: 2023-06-01" \
    -H "Content-Type: application/json" \
    -d "{
      \"model\": \"claude-haiku-4-5-20251001\",
      \"max_tokens\": 250,
      \"messages\": [{
        \"role\": \"user\",
        \"content\": \"Write a short, punchy Facebook Reel caption for ${PROPERTY_NAME} in ${LOCATION}. Brand voice: ${BRAND_VOICE}. Keep it to 2-3 sentences max. Evoke the lifestyle. End with a soft CTA (DM for info or availability). Add 6 relevant hashtags. No emojis. No quotation marks.\"
      }]
    }" || true)
  CAPTION=$(echo "$CAPTION_RESP" | jq -r '.content[0].text // empty' || true)
  if [ -z "$CAPTION" ]; then
    CAPTION="${PROPERTY_NAME} — ${LOCATION}. Send us a message for availability and pricing."
    echo "  ⚠ Claude unavailable — using default caption"
  else
    echo "  ✓ Caption generated"
  fi
fi

# ── Post to Facebook ──────────────────────────────────────────────────
echo ""
echo "--- Posting to Facebook (page $FB_PAGE_ID) ---"
FB_RESP=$(curl -s -X POST \
  "https://graph.facebook.com/v19.0/${FB_PAGE_ID}/videos" \
  -F "file_url=${REEL_URL}" \
  -F "description=${CAPTION}" \
  -F "access_token=${PAGE_TOKEN}" || true)

VIDEO_ID=$(echo "$FB_RESP" | jq -r '.id // empty' || true)

if [ -z "$VIDEO_ID" ]; then
  echo "ERROR posting to Facebook:" >&2
  echo "$FB_RESP" >&2
  # Try direct upload as fallback
  echo "  → Trying direct upload fallback..."
  FB_RESP2=$(curl -s -X POST \
    "https://graph.facebook.com/v19.0/${FB_PAGE_ID}/videos" \
    -F "source=@${FINAL_MP4};type=video/mp4" \
    -F "description=${CAPTION}" \
    -F "access_token=${PAGE_TOKEN}" || true)
  VIDEO_ID=$(echo "$FB_RESP2" | jq -r '.id // empty' || true)
  if [ -z "$VIDEO_ID" ]; then
    echo "ERROR: Direct upload also failed: $FB_RESP2" >&2
    exit 1
  fi
fi

echo "  ✓ Posted! Video ID: $VIDEO_ID"
echo ""
echo "=== REEL COMPLETE ==="
echo "  Reel URL : $REEL_URL"
echo "  FB Video : https://www.facebook.com/video.php?v=${VIDEO_ID##*_}"
echo "  Caption  : ${CAPTION:0:80}..."
