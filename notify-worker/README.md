# notify-worker — Cloudflare Worker for install telemetry

Receives install-complete payloads from the BlockDAG pool-stack-docker installer (Linux/macOS/Windows), validates them, rate-limits per IP, and forwards a single email to `dawie@dagminingtrust.com` via Resend.

## What you'll need

- A Cloudflare account (free tier is fine).
- A Resend account (free tier covers ~3 000 emails/month) with `dagminingtrust.com` verified as a sending domain.
- The `wrangler` CLI: `npm i -g wrangler`.

## One-time setup

```bash
# 1. Authenticate to Cloudflare
wrangler login

# 2. Create the KV namespace used for per-IP rate limiting
wrangler kv:namespace create RL
# Copy the `id` from the output into wrangler.toml under [[kv_namespaces]]

# 3. Store the Resend API key as a Worker secret (never commits to git)
wrangler secret put RESEND_API_KEY
# Paste the key you generated at https://resend.com/api-keys

# 4. Deploy
wrangler deploy
```

By default the Worker is reachable at `https://notify-worker.<your-account>.workers.dev`. To use the friendlier `https://notify.dagminingtrust.com/install-complete` URL the installer points at:

1. In Cloudflare dashboard → Workers & Pages → your `notify-worker` → Settings → Triggers → **Custom Domains** → add `notify.dagminingtrust.com`.
2. Cloudflare automatically creates the DNS record and provisions a TLS cert.

## Smoke test

```bash
curl -X POST https://notify.dagminingtrust.com/install-complete \
  -H 'Content-Type: application/json' \
  -d '{
    "version":"pool-stack-docker-v1.3.21",
    "hostname":"smoke-test",
    "os":"linux-debian",
    "wallet":"0x6387C32ccDD60BfBa00EC70A67715Dcd52E8083f",
    "worker_name":"smoke",
    "started_at":"2026-05-04T18:00:00Z",
    "duration_seconds":42,
    "use_snapshot":"yes",
    "status":"running"
  }'

# Expected: HTTP 200 {"ok":true}
# Plus an email lands at dawie@dagminingtrust.com within ~10 s.
```

## What gets logged where

- Resend logs: outbound emails (success / bounce) — visible in the Resend dashboard.
- Cloudflare Workers logs: every POST, including malformed payloads and rate-limit hits — visible via `wrangler tail` or in the Cloudflare dashboard.
- KV: only ephemeral rate-limit counters with 120 s TTL; nothing persisted long-term.

## What it does NOT do

- It does NOT receive private keys, RPC passwords, postgres passwords, or any other secret. The installer scripts deliberately do not include those fields in the payload.
- It does NOT track the operator over time — there's no UUID, no install id, no follow-up checks. One email per install, then nothing.
- It does NOT publish data outside this account. Resend → Dawie's inbox; Cloudflare logs → Dawie's Cloudflare account.

## Cost

Free tier of both Cloudflare Workers (100K req/day) and Resend (3K emails/month) is more than enough for organic 60K-community adoption levels. If you exceed it: ~$5/mo for Workers Paid + ~$20/mo for Resend if you outgrow the free email tier.
