# Device Sync (optional)

By default UsageMeter runs entirely on your machine and talks to nothing but the
Claude/Codex usage APIs. **Sync is opt-in.** When you turn it on, each install
publishes its usage to a small endpoint **you** control, so that:

- your other computers show the same numbers,
- a **phone view** can display your usage from anywhere, and
- optionally, only **one** device polls the provider APIs per interval (the
  others reuse the shared reading — see [Reduce cross-device polling](#reduce-cross-device-polling)).

Only usage **percentages and reset times** are stored — never tokens or
credentials. UsageMeter ships **no default server**; you point it at your own.

There are three steps: **(1)** create a free endpoint, **(2)** turn on sync in
the app, **(3)** add the phone view. Step 1 is the only fiddly part, and it's
walked through click-by-click below — with **Supabase** first (recommended) and
**Cloudflare** as an alternative.

---

## Step 1 — Create a free endpoint with Supabase (recommended)

You'll make one small table and one "Edge Function" (a script Supabase runs),
both from the dashboard — no command line. Supabase has **no per-day write
limit**, so it comfortably handles frequent updates (including the coordination
feature below).

> Button names shift over time; look for the closest match if something differs.

### 1a. Create the table
1. Open your project at **https://supabase.com/dashboard**.
2. Left sidebar → **SQL Editor** → **New query**.
3. Paste this and click **Run**:

```sql
create table if not exists usage_sync (
  key text primary key,
  blob jsonb not null,
  updated_at timestamptz not null default now()
);
alter table usage_sync enable row level security;
-- No policies added on purpose: this blocks direct public access. Only the
-- Edge Function (which uses the service role) can read/write it.
```

### 1b. Create the Edge Function
4. Left sidebar → **Edge Functions** → **Create a function** →
   **Via Editor** (create/edit in the browser).
5. Name it `usage-sync`.
6. **Turn OFF "Verify JWT"** for this function. ⚠️ This is the one easy-to-miss
   step — the app authenticates with *its own* token, not a Supabase login, so
   if JWT verification is left on, every request is rejected before your code
   runs. (The toggle is on the create screen, or later under the function's
   **Details/Settings**.)
7. Select all the placeholder code, delete it, and paste the function below.
8. Change `PUT-A-LONG-RANDOM-PASSWORD-HERE` to a long random password you invent
   (that's your *Token* — keep a copy).
9. Click **Deploy**.

```ts
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const TOKEN = "PUT-A-LONG-RANDOM-PASSWORD-HERE"; // <-- change this (step 8)

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, // auto-provided; bypasses RLS
);

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET,PUT,OPTIONS",
  "Access-Control-Allow-Headers": "Authorization,Content-Type",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  if ((req.headers.get("Authorization") || "") !== "Bearer " + TOKEN)
    return new Response("unauthorized", { status: 401, headers: cors });

  const key = new URL(req.url).pathname; // the per-user path is the storage key

  if (req.method === "PUT") {
    const body = await req.text();
    if (body.length > 8192) return new Response("too large", { status: 413, headers: cors });
    const { error } = await supabase
      .from("usage_sync")
      .upsert({ key, blob: JSON.parse(body), updated_at: new Date().toISOString() });
    if (error) return new Response(error.message, { status: 500, headers: cors });
    return new Response("ok", { headers: cors });
  }

  if (req.method === "GET") {
    const { data } = await supabase
      .from("usage_sync").select("blob").eq("key", key).maybeSingle();
    return new Response(JSON.stringify(data?.blob ?? {}), {
      headers: { ...cors, "Content-Type": "application/json" },
    });
  }

  return new Response("method not allowed", { status: 405, headers: cors });
});
```

### 1c. Write down your two values
10. Your function's base URL is
    `https://YOUR-PROJECT-REF.supabase.co/functions/v1/usage-sync`.
    (Find `YOUR-PROJECT-REF` in **Project Settings → Data API / API → Project
    URL**, or it's the subdomain of your project's URL.)
11. Your **Sync URL** = that base URL + `/` + a secret word you invent, e.g.
    `https://YOUR-PROJECT-REF.supabase.co/functions/v1/usage-sync/kf9x2q7m`.
    Use the **same** one on every device.
12. Your **Token** = the password you set in step 8.

---

## Step 1 (alternative) — Cloudflare Workers + KV

No website or domain needed. Note: Cloudflare KV's free tier caps **writes at
1,000/day** — fine for normal use (the app writes sparingly), but if you turn on
[coordination](#reduce-cross-device-polling), Supabase is the better fit.

> Cloudflare occasionally renames buttons; look for the closest equivalent.

### 1a. Sign up
1. Go to **https://dash.cloudflare.com/sign-up**, create a free account, log in.
2. If it pushes you to "add a website/domain", find **Skip** / "continue to
   dashboard". You do **not** need a domain.

### 1b. Make the storage (KV namespace)
3. Left sidebar → **Storage & Databases → KV** (or **Workers & Pages** → **KV**).
4. **Create a namespace**, name it `usage`, **Add**.

### 1c. Make the Worker
5. Left sidebar → **Workers & Pages** → **Create** → **Create Worker**
   (pick a free `*.workers.dev` subdomain if asked).
6. Name it `usage-sync`, **Deploy** (deploys a placeholder).
7. **Edit code** (`</>`), select-all + delete, paste the script below, and change
   `PUT-A-LONG-RANDOM-PASSWORD-HERE` to a long random password (your *Token*).
   **Deploy**.

### 1d. Connect the storage
8. Worker page → **Settings** → **Bindings** (older UI: **Variables → KV
   Namespace Bindings**) → **Add binding** → **KV namespace**:
   variable name **`USAGE`** (capitals), namespace `usage`. **Save**.

### 1e. Your two values
9. **Sync URL** = the Worker URL + `/` + a secret word, e.g.
   `https://usage-sync.YOUR-NAME.workers.dev/kf9x2q7m`. **Token** = the password.

```js
const TOKEN = "PUT-A-LONG-RANDOM-PASSWORD-HERE"; // <-- change this

export default {
  async fetch(req, env) {
    const cors = {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "GET,PUT,OPTIONS",
      "Access-Control-Allow-Headers": "Authorization,Content-Type",
    };
    if (req.method === "OPTIONS") return new Response(null, { headers: cors });

    if ((req.headers.get("Authorization") || "") !== "Bearer " + TOKEN)
      return new Response("unauthorized", { status: 401, headers: cors });

    const key = "u:" + new URL(req.url).pathname;
    if (req.method === "PUT") {
      const body = await req.text();
      if (body.length > 8192) return new Response("too large", { status: 413, headers: cors });
      await env.USAGE.put(key, body, { expirationTtl: 86400 });
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

---

## Step 2 — Turn on sync in the app (each computer)

1. Click the **📡 icon** in the popover.
2. Turn on **Enable sync**.
3. Paste your **Sync URL** and **Token** from Step 1.
4. Click **Save**, then **Test connection**. It should say **"✓ Connected"**.
   - "✕ token rejected" → the Token doesn't match the one in your function/Worker
     (on Supabase, also check that **Verify JWT is off**).
   - "✕ couldn't reach" → the Sync URL is wrong or not deployed.
5. Repeat on your other computer with the **same** URL and Token.

Both computers now publish to and read from the same place, so they converge
automatically — and if one has an expired login, it shows the numbers the other
published. (You can also edit `~/.usage-meter.json` by hand:
`{"sync":{"enabled":true,"url":"…","token":"…"}}`.)

---

## Step 3 — Add the phone view

Once **Test connection** passes, the app shows a **QR code**. On your phone:

1. Scan it — a live page opens showing your usage.
2. Use your browser's **Add to Home Screen** to keep it one tap away.

Your URL and token travel in the link's `#fragment`, which browsers never send
to the page's host — so the page host only ever serves plain HTML and never sees
your endpoint or token. The phone reads your usage directly from **your**
endpoint.

> The phone can only **display** data — it has no credentials of its own, so it
> shows whatever your computers last published. Keep at least one computer
> running for it to stay fresh.

### Want a real home-screen widget instead of a page?

**On Android**, use the companion **[Usage Widget](../android/)** app in this
repo. Install its APK, tap **Scan QR** and point it at the same sync QR code,
and drop the resizable "AI Usage" widget on your home screen — the same four-bar
glyph as the Mac menu bar. It reads your endpoint directly (quota only, no
credentials). See [`android/README.md`](../android/README.md) to build/install.

Prefer not to install anything, or on another platform? Any generic HTTP widget
app works too: point **HTTP Shortcuts** or **KWGT** (with an HTTP/JSON source) at
your Sync URL, add the header `Authorization: Bearer <token>`, and render
`providers.codex` / `providers.claude`.

---

## Reduce cross-device polling

With sync on, each computer still polls Claude/Codex on its own by default. If
you run 2+ computers and want to cut that, turn on **Reduce cross-device
polling** in the 📡 panel (or `"coordinate": true` in the config).

When it's on, a computer that finds a **fresh, complete** reading already in the
shared store **reuses it and skips its own API calls**. So only one device
actually polls per interval, and the total provider-poll rate becomes roughly
**3600 ÷ freshnessSeconds per hour, regardless of how many devices you run**
(default `freshnessSeconds` is 150, i.e. ~24 polls/hour total). There's no fixed
"leader": whichever awake device notices the reading has gone stale does the next
poll, so it keeps working when a laptop sleeps or travels.

The trade-off: reused numbers can be up to `freshnessSeconds` old, and the
device does one shared-store **write per poll** to refresh the reading — which is
why this is best on **Supabase** (no daily write cap) rather than Cloudflare KV.
Tune `freshnessSeconds` in `~/.usage-meter.json` (higher = fewer polls, staler
numbers).

---

## Free-tier usage

- **Supabase (free):** no per-operation daily cap; the only limits (500 MB
  storage, ~5 GB/month egress, pause after 7 days *idle*) are nowhere near
  relevant for a ~1 KB blob polled a few times a minute.
- **Cloudflare KV (free):** **1,000 writes/day**, 100,000 reads/day. With
  coordination **off**, the app writes only when your figures change (plus a
  ~30-min heartbeat) — well under the cap. With coordination **on** it writes
  every poll, so prefer Supabase.

If you ever do exceed a limit, the endpoint just returns errors until it resets
and the app quietly falls back to local data — nothing breaks, and you are not
charged.

## Security notes

- Stored data is **usage percentages only** — no tokens ever leave your machine.
- The Sync URL + Token together are a **bearer capability**: anyone with both can
  read your usage and write to your blob. Use a hard-to-guess word in the URL
  **and** a long random Token, and don't post the QR publicly.
- The function/Worker caps body size; the Cloudflare one also auto-expires idle
  data after a day.
- If a Token leaks, change it in the function/Worker code, redeploy, and update
  the app.
