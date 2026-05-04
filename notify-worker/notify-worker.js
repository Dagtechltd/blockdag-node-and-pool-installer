// notify-worker — Cloudflare Worker that receives install-complete pings from
// the BlockDAG pool-stack-docker installer and forwards an email to
// dawie@dagminingtrust.com via Resend's HTTP API.
//
// One-time deploy:
//   1. npm i -g wrangler                    (or: pnpm add -g wrangler)
//   2. wrangler login                       (opens a browser for OAuth)
//   3. wrangler kv:namespace create RL      (rate-limit storage; copy id into wrangler.toml)
//   4. wrangler secret put RESEND_API_KEY   (paste the key from https://resend.com/api-keys
//                                            after you've verified dagminingtrust.com there)
//   5. wrangler deploy
//   6. In the Cloudflare dashboard, add a custom domain "notify.dagminingtrust.com"
//      pointing at the Worker. Or skip and use the default *.workers.dev URL.
//
// Endpoint becomes: https://notify.dagminingtrust.com/install-complete
// (or https://notify-worker.<your-account>.workers.dev/install-complete)
//
// To test locally:
//   wrangler dev
//   curl -X POST http://localhost:8787/install-complete \
//     -H 'Content-Type: application/json' \
//     -d '{"version":"v1.3.23","hostname":"test","os":"linux-debian","wallet":"0x6387C32ccDD60BfBa00EC70A67715Dcd52E8083f","status":"running"}'

export default {
  async fetch(request, env, ctx) {
    if (request.method !== 'POST') {
      return new Response('Method Not Allowed', { status: 405 });
    }
    const url = new URL(request.url);
    if (url.pathname !== '/install-complete') {
      return new Response('Not Found', { status: 404 });
    }

    // Per-IP rate limiting: max 5 installs per minute per source IP.
    const ip = request.headers.get('CF-Connecting-IP') || 'unknown';
    const ipCountry = request.headers.get('CF-IPCountry') || 'XX';
    const minute = Math.floor(Date.now() / 60000);
    const rlKey = `rl:${ip}:${minute}`;
    const cur = parseInt((await env.RL.get(rlKey)) || '0', 10);
    if (cur >= 5) {
      return new Response('Rate limit exceeded (5/min)', { status: 429 });
    }
    ctx.waitUntil(env.RL.put(rlKey, String(cur + 1), { expirationTtl: 120 }));

    // Parse body.
    let payload;
    try {
      payload = await request.json();
    } catch {
      return new Response('Invalid JSON', { status: 400 });
    }

    // Required fields.
    for (const k of ['version', 'hostname', 'os', 'wallet', 'status']) {
      if (!payload[k]) {
        return new Response(`Missing field: ${k}`, { status: 400 });
      }
    }
    if (!/^0x[a-fA-F0-9]{40}$/.test(payload.wallet)) {
      return new Response('Invalid wallet format', { status: 400 });
    }

    payload.ip_country = ipCountry;
    payload.received_at = new Date().toISOString();
    // Defensive: cap absurd field lengths so a malformed client can't run up our costs.
    for (const k of Object.keys(payload)) {
      if (typeof payload[k] === 'string' && payload[k].length > 256) {
        payload[k] = payload[k].slice(0, 256) + '...';
      }
    }

    // Build the email.
    const escape = (s) =>
      String(s).replace(/[<>&]/g, (c) => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;' }[c]));
    const rows = Object.entries(payload)
      .map(
        ([k, v]) =>
          `<tr><td style="padding:4px 12px;background:#f4f4f4;font-family:monospace"><b>${escape(k)}</b></td>` +
          `<td style="padding:4px 12px;font-family:monospace">${escape(v)}</td></tr>`
      )
      .join('');
    const html = `
      <h2 style="font-family:sans-serif">BlockDAG Pool-Stack install complete</h2>
      <table style="border-collapse:collapse;border:1px solid #ddd">${rows}</table>
      <p style="color:#888;font-size:11px;font-family:sans-serif">
        Sent by notify-worker on Cloudflare. Source IP: ${escape(ip)}.
      </p>
    `;
    const subject = `[bdag-installer] ${payload.os} install OK — ${payload.hostname} (${payload.wallet.slice(0, 10)}…)`;

    const resp = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${env.RESEND_API_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        from: 'BDAG Installer <installer@dagminingtrust.com>',
        to: ['dawie@dagminingtrust.com'],
        subject,
        html,
      }),
    });

    if (!resp.ok) {
      const txt = await resp.text();
      // Don't echo the full Resend error to the caller — could leak account info.
      console.error('Resend API failed:', resp.status, txt);
      return new Response(`Email send failed (status ${resp.status})`, { status: 502 });
    }
    return new Response(JSON.stringify({ ok: true }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    });
  },
};
