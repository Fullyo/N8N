# LUX Property Management — Social Media Automation Roadmap

**Repo:** `fullyo/n8n` | **Branch:** `claude/n8n-social-media-automation-XpSkG`
**Maintained by:** Claude Code sessions — update this file after every build session.

---

## Overview

Automated daily social media posting for 5 LUX Property Management businesses.
Starting with Business #1: **SkyHouse Sayulita**.

**Stack:** n8n (automation) · Claude API (content generation) · Facebook Graph API · Instagram Graph API · Google Drive (photos) · Google Sheets (logging)

**Group resharing** is handled separately by Manus (manual, from personal Facebook). n8n owns content generation + Facebook Page + Instagram only.

---

## Workflow Files

| File | Business | Status |
|---|---|---|
| `skyhouse-sayulita-social-poster.json` | SkyHouse Sayulita | ✅ Built |
| `[business-2]-social-poster.json` | TBD | ⏳ Pending brand bible |
| `[business-3]-social-poster.json` | TBD | ⏳ Pending brand bible |
| `[business-4]-social-poster.json` | TBD | ⏳ Pending brand bible |
| `[business-5]-social-poster.json` | TBD | ⏳ Pending brand bible |

---

## Phase 1 — Foundation (Current)

**Goal:** Daily posts live, reliable, brand-correct. Simple but working.

| Component | Tool | Notes |
|---|---|---|
| Caption generation | Claude API (`claude-opus-4-6`) | Brand bible embedded in system prompt |
| Photo source | Google Drive | Folder: `Lux/SkyHouse Sayulita/Full Resolution/` |
| Facebook Page post | Facebook Graph API v19.0 | Multi-photo (3 images per post) |
| Instagram post | Instagram Graph API | Carousel (3 images) |
| Post logging | Google Sheets | Operations Sheet → `Post Log` tab |
| Schedule | n8n cron | Daily at 18:00 UTC (10:00 AM PT) |

**Weekly audience rotation:**

| Day | Audience | CTA Style |
|---|---|---|
| Monday | Sayulita Rentals | Direct: `skyhousesayulita.com` |
| Tuesday | Riviera Nayarit & Puerto Vallarta | Soft: `Link in comments` |
| Wednesday | Digital Nomads & Remote Workers | `DM for availability` |
| Thursday | Sayulita Community | None (community tone) |
| Friday | Mexico Expats & Travelers | Soft: `Link in comments` |
| Saturday | Surfers & Adventure Travelers | `DM for availability` |
| Sunday | Luxury Travel & Villas | None (brand awareness) |

**One-time setup required before activating:**
1. Create Facebook App at developers.facebook.com (Business type)
   - Permissions: `pages_manage_posts`, `pages_read_engagement`, `instagram_content_publish`
   - No App Review needed — you own the Page and Instagram account
   - Generate long-lived Page Access Token
2. Get Instagram User ID: call `GET /me/accounts` and find linked IG account ID
3. Set Google Drive folder `Lux/SkyHouse Sayulita/Full Resolution/` to "Anyone with the link — Viewer"
4. Add `Post Log` tab to Operations Sheet with columns:
   `Date | Day | Audience | Post Preview | FB Post ID | IG Post ID | Photo Count | Warnings | Status`
5. In n8n Settings → Credentials, configure:
   - `Anthropic API` (Header Auth: `x-api-key`)
   - `SkyHouse Facebook Token` (Header Auth: `Authorization: Bearer PAGE_ACCESS_TOKEN`)
   - `Google Drive OAuth2`
   - `Google Sheets OAuth2`
6. In the workflow, replace all `REPLACE_WITH_...` placeholders (see workflow comments)

---

## Phase 2 — Content Quality (Month 2–3)

**Goal:** Posts look designed, not raw. Performance data collected.

| Enhancement | Tool | Notes |
|---|---|---|
| Text overlays on photos | **Cloudinary** (start here) | Free tier. Adds logo bug, text, filters via URL params. Integrates via n8n HTTP node. No extra design setup. |
| Branded templates | **Canva Connect API** | Upgrade path if Cloudinary is too limited. More complex setup (OAuth2, asset upload, export). |
| Engagement tracking | Facebook Graph API `/{post-id}/insights` | Pull reach, reactions, clicks per post into Google Sheets |
| Hook A/B testing | Code node randomizer | Rotate 2 hook variants per audience, track performance |

---

## Phase 3 — AI Comment Replies (Month 3–4)

**Goal:** Claude reads incoming Facebook comments and replies automatically.
Basic questions get auto-replies. Complex ones get escalated to property manager.

**Architecture:**
```
Facebook Webhook → n8n Webhook node
  → Get comment text via Graph API
  → Claude API (brand voice + FAQ context + escalation rules)
  → If answerable: POST reply via Graph API
  → If escalation needed: WhatsApp notification to property manager
```

**Escalation triggers:**
- Price negotiation
- Complaints or negative sentiment
- Booking disputes
- Requests requiring Eño (charters, rentals, transfers)
- Anything unclear or needing local knowledge

**Setup required:** Facebook Webhook subscription to `page` object, `feed` field.

---

## Phase 4 — Video Content (Month 5–6)

**Goal:** Automated short-form video for Instagram Reels and Facebook Reels.

| Tool | Best For | n8n Integration |
|---|---|---|
| **Runway ML (Gen-3)** | Cinematic image-to-video — terraces, ocean, jungle | HTTP API |
| **Kling AI** | High-quality 5–10 sec clips, luxury property | HTTP API |
| **Pika Labs** | Fast, affordable motion clips | API available |
| **HeyGen** | AI spokesperson — "Eño intro" style videos | HTTP API |
| **InVideo AI** | Script + photos → slideshow video | API available |

**Recommended start:** Runway ML — best quality for architectural and landscape content (terraces, ocean views, jungle shots).

> **Note on "Nano Banana":** If this refers to a specific tool, please confirm the name so it can be evaluated. Closest known tools are Kaiber (photo animation) or Banana.dev (GPU inference, not a video generator directly).

---

## Scaling to All 5 Businesses

Once SkyHouse is stable (1–2 weeks of clean daily runs), clone the workflow per business:
- Swap: brand bible in Claude system prompt
- Swap: Facebook Page ID
- Swap: Instagram User ID
- Swap: Google Drive photo folder ID
- Swap: Google Sheets log location
- Adjust: audience rotation and CTA style per brand

Each business gets its own workflow file in this repo.

---

## Key IDs Reference (SkyHouse Sayulita)

| Item | Value |
|---|---|
| Facebook Page ID | `1004908006045909` |
| Instagram User ID | `REPLACE_WITH_IG_USER_ID` |
| Google Drive Folder | `Lux/SkyHouse Sayulita/Full Resolution/` (use folder ID in workflow) |
| Operations Sheet ID | `142zDJuO2Gz8NNgjTjh7lox_u4iy4jOdCDDCmGNDMyMI` |
| Facebook Group Directory | `1CTKZYDhcyYSbE5nYtwf8ojuY6126CbiAN50uasfl3ks` |
| Website | `skyhousesayulita.com` |
