# Fullyo — N8N Social Media Automation
## Reference for Claude Code Sessions

This file exists so Claude never asks the user for information that is already available,
and never repeats the same diagnostic mistakes across sessions.

---

## Golden Rules

1. **GitHub Secrets cannot be read back.** The PAT allows writing secrets and triggering
   workflows — it cannot retrieve secret values. This is GitHub's design. It is not a gap
   in access. Do not ask the user for keys that are in GitHub Secrets. All workflows that
   need those keys run inside GitHub Actions where they are injected automatically.

2. **Everything runs through GitHub Actions — not locally.** `credentials.local.json` is
   intentionally incomplete (missing Bunny VSA key, etc.). That is fine. The Actions
   workflows build a full credentials file from secrets at runtime. Never block on a missing
   local key.

3. **Check the debug log before asking the user anything.** Every post attempt writes
   `_post-debug.log` to the repo. Pull it first.

4. **Photos are uploaded.** The user has already uploaded all property photos to Bunny CDN.
   Do not tell them folders are empty without verifying via API first.

5. **Do not ask the user to do something you can do yourself.** Exhaust all available tools
   before involving the user. If you must ask, be 150% sure there is no other way.

---

## Repository

- **Repo:** `fullyo/n8n` (Gitea proxy at `http://127.0.0.1:39567/git/Fullyo/N8N`)
- **Active branch:** `claude/n8n-social-media-automation-XpSkG`
- **Every push to this branch triggers:** `deploy-n8n.yml` (redeploys n8n workflows)

---

## GitHub Secrets (all confirmed present)

| Secret | Purpose |
|---|---|
| `ANTHROPIC_API_KEY` | Claude API for caption generation |
| `BUNNY_SAYULITA_KEY` | Bunny CDN `sayulitaandbeyond` zone |
| `BUNNY_SEMPREAVANTI_KEY` | Bunny CDN `villassempreavanti` zone |
| `BUNNY_SKYHOUSE_KEY` | Bunny CDN `skyhousesayulita` zone |
| `FB_TOKEN_CASASEMPREAVANTI` | Facebook long-lived USER token for CSA page |
| `FB_TOKEN_SKYHOUSE` | Facebook token for SkyHouse page |
| `N8N_API_KEY` | n8n Cloud API key |
| `PEXELS_API_KEY` | Pexels stock photo fallback |
| `TELEGRAM_BOT_TOKEN` | Telegram bot |

**Note on Facebook tokens:** Stored tokens may be user tokens OR page tokens.
`post-to-facebook.sh` automatically exchanges user tokens for page tokens via
`/me/accounts` before every post. This is permanent — no manual token management needed.

---

## Properties

### SkyHouse Sayulita
- **Facebook Page ID:** `1004908006045909`
- **Pending post file:** `pending-post.json`
- **GitHub Action:** `.github/workflows/auto-post-facebook.yml`
  - Triggers on push to `pending-post.json`
- **n8n workflow:** `skyhouse-sayulita-social-poster.json`
  - Schedule: Mon / Wed / Fri at 18:00 UTC (11am Mexico time)
- **Bunny zones:**
  - Property photos: `skyhousesayulita` (folder: root)
  - Activity photos: `sayulitaandbeyond` (folder: category name)

### Villas Sempre Avanti (Casa Sempre Avanti)
- **Facebook Page ID:** `350547805544245`
- **Pending post file:** `pending-post-casasempreavanti.json`
- **GitHub Action:** `.github/workflows/auto-post-casasempreavanti.yml`
  - Triggers on push to `pending-post-casasempreavanti.json`
  - Sets `PENDING_FILE` env var so `post-to-facebook.sh` routes correctly
- **n8n workflow:** `villas-sempre-avanti-social-poster.json`
  - Schedule: Tue / Thu / Sat at 16:00 UTC (9am Mexico time)
- **Bunny zones:**
  - Property photos: `villassempreavanti`
    - `Villa Luisa/` — 87 objects confirmed uploaded
    - `Villa Pietro/` — confirmed uploaded
    - `Villas Sempre Avanti/` — confirmed uploaded
  - Activity photos: `sayulitaandbeyond` (Surf, Yoga, Restaurants, etc.)
- **Facebook app:** `812551218572821` (LUX Business Portfolio app)
- **Note:** Page lives under Seb L'Heureux personal account — NOT in any Business Portfolio.
  System Users cannot be created for it without moving it to a Business Portfolio.

---

## Bunny CDN

| Zone | Hostname | Purpose |
|---|---|---|
| `skyhousesayulita` | `SkyhouseSayulita.b-cdn.net` | SkyHouse property photos |
| `sayulitaandbeyond` | `sayulitaandbeyond.b-cdn.net` | Shared activity photos (Surf, Yoga, etc.) |
| `villassempreavanti` | `VillasSempreAvanti.b-cdn.net` | VSA property photos |

**Storage API:** `https://la.storage.bunnycdn.com`

To verify folder contents (requires key from GitHub Actions context, not local):
```bash
curl -s -H "AccessKey: $BUNNY_KEY" "https://la.storage.bunnycdn.com/villassempreavanti/"
```

---

## Posting Flow

### GitHub Actions (manual/triggered posts)
1. Edit `pending-post-casasempreavanti.json` (or `pending-post.json` for SkyHouse)
2. Push → Action triggers → `post-to-facebook.sh` runs
3. Script auto-exchanges user token → page token → uploads photos → publishes post
4. On success: pending post file is cleared automatically
5. Debug log written to `_post-debug.log` on every run — pull and read it to diagnose

### n8n (scheduled posts)
1. Schedule trigger fires
2. Workflow picks photos from Bunny CDN
3. Calls Claude API to generate caption
4. Uploads photos + publishes to Facebook
5. Errors go to Error Trigger → Log Error to Console node

---

## Diagnosing Failures — Do This Before Asking the User

```bash
# 1. Pull latest debug log
git pull origin claude/n8n-social-media-automation-XpSkG
cat _post-debug.log

# 2. Check GitHub Actions runs via API (PAT is in credentials.local.json)
GITHUB_PAT=$(jq -r '.github.pat' /home/user/N8N/credentials.local.json)
curl -s -H "Authorization: Bearer $GITHUB_PAT" \
  "https://api.github.com/repos/fullyo/n8n/actions/runs?per_page=5" \
  | jq '.workflow_runs[] | {id, name, status, conclusion, created_at}'

# 3. Check n8n workflow status
N8N_KEY=$(jq -r '.n8n.apiKey' /home/user/N8N/credentials.local.json)
curl -s -H "X-N8N-API-KEY: $N8N_KEY" \
  "https://fullyo.app.n8n.cloud/api/v1/workflows?limit=10" \
  | jq '.data[] | {id, name, active}'

# 4. Verify Bunny folder via Actions — create a diagnostic workflow if needed
```

---

## Deploying Changes

Any push to `claude/n8n-social-media-automation-XpSkG` triggers `deploy-n8n.yml` which:
1. Builds `credentials.local.json` from all GitHub Secrets
2. Runs `deploy-to-n8n.sh` — creates/updates both n8n workflows and credentials
3. Activates both workflows

To trigger a VSA Facebook post manually:
```bash
# Edit pending post, bump the _trigger field, push
git add pending-post-casasempreavanti.json
git commit -m "trigger: <description>"
git push -u origin claude/n8n-social-media-automation-XpSkG
```

---

## Key Technical Facts

- **Facebook token exchange:** `post-to-facebook.sh` calls `/me/accounts` to convert any
  stored user token to a page token before posting. Page tokens are required for
  `published=false` photo uploads. This is automatic — no manual token management.

- **Pexels fallback:** If a Bunny folder is empty for an activity category, the script
  fetches from Pexels, saves to Bunny, and uses those photos. Hard-fails for property
  folders (Villa Luisa, Villa Pietro, etc.) — stock photos never used for real villa shots.

- **n8n credential IDs:** Stored as `CRED_ID_*` placeholders in workflow JSON files.
  `deploy-to-n8n.sh` replaces them via `sed` with real IDs at deploy time.

- **Proxy environment:** Outbound internet through a proxy. `api.github.com` is accessible.
  Direct calls to some external services may fail with exit code 56 — use GitHub Actions
  for anything that needs to call Facebook Graph API or Bunny CDN from outside Actions.
