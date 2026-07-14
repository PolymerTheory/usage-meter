# Device Sync (optional)

By default UsageMeter runs entirely on your machine and talks to nothing but the
Claude/Codex usage APIs. **Sync is opt-in.** When you turn it on, each install
publishes its usage to a small endpoint **you** control, so that:

- your other computers show the same numbers, and
- a **phone view** can display your usage from anywhere.

Only usage **percentages and reset times** are stored — never tokens or
credentials. UsageMeter ships **no default server**; you point it at your own.

There are three steps: **(1)** create a free endpoint, **(2)** turn on sync in
the app, **(3)** add the phone view. Step 1 is the only fiddly part, and it's
walked through click-by-click below.

---

## Step 1 — Create a free endpoint with Cloudflare (≈10 min, no coding)

You'll make a tiny "Worker" (a script Cloudflare runs for you) plus a "KV"
store (where it saves your usage). It's free and you don't need a website or
domain.

> Cloudflare occasionally renames buttons. If a label below doesn't match
> exactly, look for the closest equivalent — the flow is the same.

### 1a. Sign up
1. Go to **https://dash.cloudflare.com/sign-up** and create a free account,
   then log in.
2. If it pushes you to "add a website/domain", look for **Skip** / a small
   "continue to dashboard" link. You do **not** need a domain for this.

### 1b. Make the storage (KV namespace)
3. In the left sidebar, open **Storage & Databases → KV**.
   (On some accounts it's **Workers & Pages**, then the **KV** tab.)
4. Click **Create a namespace** (or **Create instance**).
5. In **Namespace name**, type `usage` and click **Add** / **Create**.
   You now have an empty box to store data in.

### 1c. Make the Worker (the script)
6. Left sidebar → **Workers & Pages** → click **Create** (or
   **Create application**) → **Create Worker**.
   (If it's your first Worker it may ask you to pick a free
   `*.workers.dev` subdomain — choose anything and continue.)
7. Change the suggested name to `usage-sync`, then click **Deploy**.
   (This deploys a placeholder "Hello World" — that's expected.)
8. Click **Edit code** (a `</>` button, top right). In the editor, **select all
   and delete**, then paste the whole script from the box further down.
9. In the pasted code, change the first line — replace
   `PUT-A-LONG-RANDOM-PASSWORD-HERE` with a long random password you invent
   (20+ characters, letters and numbers). **Keep a copy of it** — that's your
   *Token*.
10. Click **Deploy** (top right of the editor).

### 1d. Connect the storage to the Worker
11. Go back to the Worker's page → **Settings** tab → find **Bindings**
    (older UI: **Variables** → **KV Namespace Bindings**).
12. Click **Add binding** → choose **KV namespace**.
    - **Variable name:** type exactly `USAGE` (capitals).
    - **KV namespace:** pick the `usage` one you made in step 5.
    - Click **Save** / **Deploy**.

### 1e. Write down your two values
13. On the Worker's page, copy its URL — it looks like
    `https://usage-sync.YOUR-NAME.workers.dev`.
14. Your **Sync URL** is that URL plus `/` plus a secret word you invent, e.g.
    `https://usage-sync.YOUR-NAME.workers.dev/kf9x2q7m`.
    Use the **same** Sync URL on every device.
15. Your **Token** is the password you set in step 9.

### The script to paste (step 8)

```js
const TOKEN = "PUT-A-LONG-RANDOM-PASSWORD-HERE"; // <-- change this (step 9)

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
      await env.USAGE.put(key, body, { expirationTtl: 86400 }); // auto-expire idle data after 1 day
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

## Step 1 (alternative) — Use Supabase instead

If you already have Supabase, it's a great fit: unlike Cloudflare KV's
1,000-writes/day cap, Supabase has no per-operation daily limit. You'll make one
small table and one "Edge Function" (a script Supabase runs), both from the
dashboard — no command line.

> As with Cloudflare, button names shift over time; look for the closest match.

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

### 1c. Get your two values
10. Your function's base URL is
    `https://YOUR-PROJECT-REF.supabase.co/functions/v1/usage-sync`.
    (Find `YOUR-PROJECT-REF` in **Project Settings → Data API / API → Project
    URL**, or it's the subdomain of your project's URL.)
11. Your **Sync URL** = that base URL + `/` + a secret word you invent, e.g.
    `https://YOUR-PROJECT-REF.supabase.co/functions/v1/usage-sync/kf9x2q7m`.
    Use the **same** one on every device.
12. Your **Token** = the password you set in step 8.

---

## Step 2 — Turn on sync in the app (each computer)

1. Click the **📡 icon** in the popover.
2. Turn on **Enable sync**.
3. Paste your **Sync URL** and **Token** (from steps 14–15).
4. Click **Save**, then **Test connection**. It should say **"✓ Connected"**.
   - "✕ token rejected" → the Token doesn't match the one in your Worker code.
   - "✕ couldn't reach" → the Sync URL is wrong, or the Worker isn't deployed.
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

A live Android widget needs a third-party widget app (nothing to install from
here): point **HTTP Shortcuts** or **KWGT** (with an HTTP/JSON source) at your
Sync URL, add the header `Authorization: Bearer <token>`, and render
`providers.codex` / `providers.claude`.

---

## Free-tier usage

Cloudflare KV's free tier allows **1,000 writes/day** (and 100,000 reads/day).
UsageMeter only **writes when your usage figures actually change**, plus a
"still alive" heartbeat every ~30 minutes — so a couple of devices generate
well under a hundred writes a day, not one per poll. Reads happen every poll
but have huge headroom. If you ever do exceed a daily limit, KV just returns
errors until it resets at 00:00 UTC and the app quietly falls back to local
data — nothing breaks and you are not charged.

## Security notes

- Stored data is **usage percentages only** — no tokens ever leave your machine.
- The Sync URL + Token together are a **bearer capability**: anyone with both can
  read your usage and write to your blob. Use a hard-to-guess word in the URL
  **and** a long random Token, and don't post the QR publicly.
- The Worker caps body size and auto-expires idle data after a day.
- If a Token leaks, change it in the Worker code, redeploy, and update the app.
