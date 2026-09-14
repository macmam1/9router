# 9Router ModelScope Studio Deployment Guide

## Current Status

| Component | Status |
|-----------|--------|
| Studio existence | ✅ Verified (`https://www.modelscope.ai/studios/magoco/9Router`) |
| Local repo | ✅ Ready at `/app/working/workspaces/default/9router-repo/` |
| Entrypoint script | ✅ Ready at `modelscope-entrypoint.sh` |
| Cloudflare token | ✅ Claimed present in QwenPaw secrets (do not echo) |
| Tailscale auth | ⚠️ Not yet configured in studio env |

## 1) Studio Preparation (do now)

1. Open ModelScope Studio Console:
   `https://www.modelscope.ai/studios/magoco/9Router/console`

2. If the studio is deleted/recreated, go to:
   `https://www.modelscope.ai/studios/magoco/9Router`

3. In Studio Settings, set:
   - **Environment Variables**: add `PORT=7860`
   - **Entrypoint Command**: `/app/docker-entrypoint.sh`

4. If QwenPaw secrets contain a Cloudflare token, set:
   - `CLOUDFLARE_TUNNEL_TOKEN=<your token>`
   - Do **not** paste any Zero Trust token here.

5. Optional: add `TUNNEL_URL_WEBHOOK` if you want the tunnel URL POSTed somewhere.

6. Optional Tailscale auth:
   - `TAILSCALE_AUTH_KEY=<tailscale auth key>`
   - `TAILSCALE_HOSTNAME=9router-magoco`

7. Rebuild the studio.

## 2) Keep-Alive (run once per fresh studio)

Use the cron/keepalive workflow to prevent idle timeout:
- Target URL: `https://www.modelscope.ai/studios/magoco/9Router`
- Interval: every 15–30 minutes
- Method: GET

## 3) Verification After Rebuild

Check:
- `https://www.modelscope.ai/studios/magoco/9Router/console`
- Cloudflare tunnel log output
- Tailscale Funnel URL (if configured)

## 4) Access URLs (expected)

| Method | URL |
|--------|-----|
| ModelScope | `https://www.modelscope.ai/studios/magoco/9Router` |
| Cloudflare Quick Tunnel | `https://<random>.trycloudflare.com` |
| Cloudflare Named Tunnel | `https://omni.magoc.dpdns.org` |
| Tailscale Funnel | `https://9router-magoco.ts.net` |
| Local | `http://localhost:7860` |

## 5) Notes

- ModelScope Studio only exposes one port (default 7860).
- The entrypoint keeps the container alive even if the main app exits unexpectedly.
- Random keep-alive reduces chance of bot detection.
- Do **not** use Zero Trust payment-required features here.
