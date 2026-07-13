# Device Sync (optional)

By default, UsageMeter runs entirely on your machine and talks to nothing but
the Claude/Codex usage APIs. **Sync is opt-in.** When you turn it on, each
install publishes its usage to a small endpoint **you control**, so that:

- your other computers show the same numbers without each polling the APIs, and
- a **phone view** can display your usage from anywhere.

Only usage **percentages and reset times** are ever stored — never tokens or
credentials. UsageMeter ships **no default server**; you point it at your own.

---

## 1. Stand up an endpoint (once)

You need a URL that stores a small JSON blob on `PUT` and returns it on `GET`,
protected by a bearer token, with CORS enabled (so the phone page can read it).
Pick one:

### Option A — Cloudflare Worker + KV (free, ~5 min)

1. Create a KV namespace (Workers & Pages → KV) called `USAGE`.
2. Create a Worker, bind the KV namespace as `USAGE`, and add a secret
   `SYNC_TOKEN` (a long random string).
3. Paste this and deploy:

```js
export default {
  async fetch(req, env) {
    const cors = {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "GET,PUT,OPTIONS",
      "Access-Control-Allow-Headers": "Authorization,Content-Type",
    };
    if (req.method === "OPTIONS") return new Response(null, { headers: cors });

    const auth = req.headers.get("Authorization") || "";
    if (env.SYNC_TOKEN && auth !== "Bearer " + env.SYNC_TOKEN)
      return new Response("unauthorized", { status: 401, headers: cors });

    const key = "u:" + new URL(req.url).pathname;               // per-key storage
    if (req.method === "PUT") {
      const body = await req.text();
      if (body.length > 8192) return new Response("too large", { status: 413, headers: cors });
      await env.USAGE.put(key, body, { expirationTtl: 86400 }); // auto-expire after 1 day idle
      return new Response("ok", { headers: cors });
    }
    if (req.method === "GET") {
      const val = (await env.USAGE.get(key)) || "{}";
      return new Response(val, { headers: { ...cors, "Content-Type": "application/json" } });
    }
    return new Response("method not allowed", { status: 405, headers: cors });
  },
};
```

Your **Sync URL** is then `https://<your-worker>.workers.dev/<a-random-key>`
(pick any hard-to-guess path, e.g. a UUID), and your **Token** is `SYNC_TOKEN`.

### Option B — Supabase Edge Function

If you already use Supabase, deploy an Edge Function that reads/writes one row
of a table (`usage(key text primary key, blob jsonb, updated_at timestamptz)`)
keyed by a path segment, echoing the same `GET`/`PUT` + CORS contract as above.
The app only requires "GET returns the JSON, PUT stores it, bearer auth,
CORS" — any backend that does that works.

---

## 2. Turn it on in the app (each computer)

Click the **📡 sync icon** in the popover → **Enable sync**, paste the same
**Sync URL** and **Token** on every computer, and **Save**. Both computers
now publish to and read from the same place, so they converge automatically —
and if one has an expired login, it shows the numbers the other published.

(You can also edit `~/.usage-meter.json` directly:)

```json
{
  "sync": { "enabled": true, "url": "https://…/<key>", "token": "<token>" }
}
```

---

## 3. Add the phone view

With sync active, the app shows a **QR code**. On your phone:

1. Scan it — it opens a live page showing your usage.
2. Use your browser's **Add to Home Screen** to keep it one tap away.

The page is a static file served from GitHub Pages
(`docs/phone.html`). Your URL and token travel in the link's `#fragment`,
which browsers never send to the page's host — so GitHub only ever serves the
plain HTML and never sees your endpoint or token. The phone reads your usage
directly from **your** endpoint.

> The phone can only **display** data — it has no Claude/Codex credentials of
> its own, so it shows whatever your computers last published. Keep at least one
> computer running for it to stay fresh.

### Want a real home-screen widget instead of a page?

A live Android widget needs a third-party widget app (no custom app required):
point **HTTP Shortcuts** or **KWGT** (with an HTTP/JSON source) at the same
Sync URL (with the `Authorization: Bearer <token>` header) and render the
`providers.codex` / `providers.claude` percentages. That's pure setup on the
phone; nothing to install from here.

---

## Security notes

- Stored data is **usage percentages only** — no tokens ever leave your machine.
- The Sync URL + token together are a **bearer capability**: anyone who has both
  can read your usage and write to your blob. Use a long random key in the URL
  **and** a long random token, and don't post the QR publicly.
- The Worker template caps body size and auto-expires idle blobs after a day.
- Prefer a per-user key you keep private; rotate the token if it leaks.
