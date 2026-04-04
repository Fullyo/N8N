# SkyHouse Sayulita — Social Media Automation Strategy

## Goal
Generate direct bookings and grow followers on the SkyHouse Sayulita Facebook page through daily automated posts — combining luxury property content with Sayulita destination content to build an engaged audience that books.

---

## Posting Schedule
- **Platform:** Facebook Page — SkyHouse Sayulita (Page ID: 1004908006045909)
- **Frequency:** Once daily
- **Time:** 6:00 PM UTC = 11:00 AM Mexico City time
- **Managed by:** n8n Cloud (fullyo.app.n8n.cloud) — workflow: *SkyHouse Sayulita — Daily Social Post*

---

## Content Cadence (3:4 Ratio)

| Day | Post Type | Photos | Focus |
|-----|-----------|--------|-------|
| Monday | Property | 3× SkyHouse | The villa, views, terraces, amenities |
| Tuesday | Experience | 1× SkyHouse + 2× Sayulita | Sayulita activity, SkyHouse as home base |
| Wednesday | Property | 3× SkyHouse | The villa, views, terraces, amenities |
| Thursday | Experience | 1× SkyHouse + 2× Sayulita | Sayulita activity, SkyHouse as home base |
| Friday | Experience | 1× SkyHouse + 2× Sayulita | Sayulita activity, SkyHouse as home base |
| Saturday | Property | 3× SkyHouse | The villa, views, terraces, amenities |
| Sunday | Experience | 1× SkyHouse + 2× Sayulita | Sayulita activity, SkyHouse as home base |

**Ratio:** 3 property days / 4 experience days per week

**Why:** Too many property posts = people unfollow (feels like ads). Destination content builds a following of Sayulita lovers who eventually book.

---

## Audience Targeting (by day)

| Day | Target Audience |
|-----|----------------|
| Sunday | Sayulita Community |
| Monday | Sayulita Rentals (actively searching) |
| Tuesday | Riviera Nayarit & Puerto Vallarta Travelers |
| Wednesday | Digital Nomads & Remote Workers |
| Thursday | Luxury Travel & Villas |
| Friday | Mexico Expats & Frequent Travelers |
| Saturday | Surfers & Adventure Travelers |

Claude adapts the caption tone, CTA, and hook for each audience automatically.

---

## Photo Sources

### SkyHouse Photos (property days + 1 anchor photo on experience days)
- **Storage:** Bunny.net — `skyhousesayulita` zone
- **CDN:** `SkyhouseSayulita.b-cdn.net`
- **32 photos** of the unit, terraces, pool, views, master suite, etc.
- Photos are selected randomly each day from the full pool

### Sayulita Shared Photos (experience days)
- **Storage:** Bunny.net — `sayulitaandbeyond` zone
- **CDN:** `sayulitaandbeyond.b-cdn.net`
- **12 folders**, each dedicated to one experience category:

| Folder | Experience |
|--------|-----------|
| Surf | Surfing at Sayulita break |
| Yoga | Yoga sessions |
| Restaurants | Dining scene |
| Marieta Islands | Day trips to Marieta |
| Monkey Mountain | Jungle hike, 360° views |
| Golf | Golf nearby |
| Fishing Charter | Deep sea fishing |
| Whale Tours | Whale watching |
| SUP | Stand-up paddleboarding |
| Ally Cat | Ally Cat bar/restaurant |
| CachaSol | CachaSol venue |
| Local Cultural | Town culture, market, community |

**Folder rotation:** The workflow uses n8n static data to cycle through all 12 folders before repeating any. No experience is posted twice in a row.

---

## Caption Generation (Claude AI)

**Model:** claude-opus-4-6

**Property day prompt:** Focused on the villa — views, terraces, feeling of being at SkyHouse. CTA drives to skyhousesayulita.com.

**Experience day prompt:** Entirely about the featured experience. SkyHouse mentioned only briefly as the perfect home base. Makes the reader fall in love with Sayulita first.

### Brand Voice Rules
- Elegant, experiential, warm, confident
- Second or third person only (never "I")
- No markdown in posts
- No mention of nightly rates
- Never claim private beach (3-min walk) or private pool (shared with Monterosa)
- Hashtags at the very end only
- 100–200 words per post

---

## Technical Stack

| Component | Tool |
|-----------|------|
| Automation | n8n Cloud |
| AI captions | Anthropic Claude API (claude-opus-4-6) |
| Photo storage | Bunny.net CDN |
| Publishing | Facebook Graph API v19.0 |
| Deployment | GitHub Actions (repo: Fullyo/N8N) |
| Credentials | Stored as n8n credentials (never in code) |

---

## Workflow Nodes (in order)

1. **Daily Schedule** — triggers at 6pm UTC
2. **Get Day Config** — determines postType (property/experience), audience, CTA style
3. **Pick Sayulita Folder** — picks next unused experience folder from rotation
4. **List SkyHouse Photos** — fetches file list from Bunny CDN
5. **List Sayulita Shared Photos** — fetches files from selected folder
6. **Pick 3 Photos** — selects 3 photos per strategy (property: 3×SkyHouse, experience: 1×SkyHouse + 2×Sayulita)
7. **Upload Photo to Facebook** — stages each photo with Facebook Graph API (unpublished)
8. **Collect Upload Results** — gathers 3 Facebook photo IDs
9. **Build Claude Request** — assembles prompt with brand bible, audience, post type
10. **Call Claude API** — generates the caption
11. **Parse & Validate Post** — checks caption quality, word count
12. **Build Facebook Post Body** — assembles final post with photos + caption
13. **Post to Facebook Page** — publishes live to the page

---

## Roadmap

### Phase 1 — Complete ✅
- Daily Facebook posts with AI captions
- Property/experience content cadence
- Bunny CDN photo rotation
- Folder-based experience rotation with memory

### Phase 2 — Next
- Instagram cross-posting (once account is set up)
- Google Sheets post log (date, caption, post ID, folder used)
- Facebook Group sharing (requires Meta App Review approval)

### Phase 3 — Future
- AI comment reply automation
- Engagement tracking (reach, clicks, DMs)
- Scale to other businesses: Moroccan Palace, Casa Sempre Avanti, LUX Property Management, Villas Sempre Avanti

---

## Key IDs & Links

| Item | Value |
|------|-------|
| Facebook Page ID | 1004908006045909 |
| Meta App ID | 812551218572821 |
| n8n instance | fullyo.app.n8n.cloud |
| Bunny SkyHouse zone | skyhousesayulita |
| Bunny Sayulita zone | sayulitaandbeyond |
| Deploy branch | claude/n8n-social-media-automation-XpSkG |
| SkyHouse website | skyhousesayulita.com |
| Host WhatsApp | +52 322 239 4077 |
