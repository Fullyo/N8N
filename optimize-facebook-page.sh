#!/usr/bin/env bash
set -euo pipefail

PAGE_ID="1004908006045909"
TOKEN="${FB_PAGE_TOKEN}"
API="https://graph.facebook.com/v19.0"

echo "=== SkyHouse Sayulita — Facebook Page Optimizer ==="
echo ""

# ── READ CURRENT PAGE INFO ────────────────────────────────────────────────────
echo "--- Reading current page fields ---"
CURRENT=$(curl -s "${API}/${PAGE_ID}?fields=name,about,description,website,phone,emails,category,location&access_token=${TOKEN}")
echo "$CURRENT" | python3 -m json.tool 2>/dev/null || echo "$CURRENT"
echo ""

# ── UPDATE PAGE FIELDS ────────────────────────────────────────────────────────
echo "--- Updating page fields ---"

# About (short tagline — shown under page name, 255 char max)
ABOUT="Luxury penthouse villa in Sayulita, Mexico. Panoramic ocean views. 3 bed · 3 bath · Sleeps 8. Starlink WiFi. 3 min to the beach. Managed by LUX Property Management."

# Description (longer — shown in About tab)
DESCRIPTION="SkyHouse Sayulita is a two-level corner penthouse at the top of the Monterosa complex on Sayulita's quiet Northside — 3 minutes from the surf break, 5 minutes from the town plaza.

Three bedrooms, three en-suite bathrooms, sleeps up to 8 guests. The main level features an open-plan living and dining area, a full chef's kitchen, and an expansive sunset terrace. The upper level is home to the master suite, BBQ setup, and a rooftop terrace with panoramic views of the Pacific.

Amenities include a shared infinity pool, a private tennis court, Starlink WiFi (the fastest in Sayulita), and a whole-house purified water system — safe to drink from every tap.

Your host Eño was born and raised in Sayulita. He offers private airport transfers, boat charters, surf lessons, ATV explorations, golf cart rentals, jungle hikes, yoga sessions, and fishing charters — everything you need to experience Sayulita beyond the beach.

Book direct at skyhousesayulita.com or message us on WhatsApp: +52 322 239 4077"

# Update about
echo "Updating 'about'..."
R=$(curl -s -X POST "${API}/${PAGE_ID}" \
  -d "about=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''${ABOUT}'''))")" \
  -d "access_token=${TOKEN}")
echo "$R"

# Update description
echo "Updating 'description'..."
R=$(curl -s -X POST "${API}/${PAGE_ID}" \
  --data-urlencode "description=${DESCRIPTION}" \
  -d "access_token=${TOKEN}")
echo "$R"

# Update website
echo "Updating website..."
R=$(curl -s -X POST "${API}/${PAGE_ID}" \
  -d "website=https://skyhousesayulita.com" \
  -d "access_token=${TOKEN}")
echo "$R"

# Update phone
echo "Updating phone..."
R=$(curl -s -X POST "${API}/${PAGE_ID}" \
  -d "phone=%2B52+322+239+4077" \
  -d "access_token=${TOKEN}")
echo "$R"

echo ""
echo "--- Reading updated page ---"
UPDATED=$(curl -s "${API}/${PAGE_ID}?fields=name,about,description,website,phone&access_token=${TOKEN}")
echo "$UPDATED" | python3 -m json.tool 2>/dev/null || echo "$UPDATED"

echo ""
echo "=== Done ==="
echo ""
echo "Fields that require Facebook UI (cannot update via API):"
echo "  - Profile photo (use a high-quality exterior shot of SkyHouse)"
echo "  - Cover photo (use the panoramic rooftop/ocean view shot)"
echo "  - Username/handle (@SkyHouseSayulita if available)"
echo "  - Call-to-action button (set to 'Book Now' → skyhousesayulita.com)"
echo "  - Page category (set to: Vacation Home Rental)"
