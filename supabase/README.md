# VoiceBox auth and database setup

The app runs fine with **no account at all** — "Continue as guest" uses
`localStorage` for phrase history. Supabase only adds cross-device sync of
spoken phrases and corrections. Set it up when you want that.

## Current state

The project ref previously in `voicebox/.env.local`
(`wfypgjmflatmkvxcxlkk.supabase.co`) **no longer exists** — it returns
NXDOMAIN on a public resolver, while `supabase.co` itself resolves. A Supabase
project that is paused for long enough is removed, and the subdomain stops
resolving. Nothing in the app can work around that, so step 1 below is
unavoidable.

## Setup

### 1. Create a project *(you have to do this part)*

At <https://supabase.com/dashboard> → **New project**. Any region; the free
tier is enough. Creating the account and project needs your identity, so it
is not something I can do for you.

### 2. Copy the two keys

**Dashboard → Project Settings → API**:

| Dashboard field | Goes into |
| --- | --- |
| Project URL | `VITE_SUPABASE_URL` and `SUPABASE_URL` |
| `anon` / publishable key | `VITE_SUPABASE_PUBLISHABLE_KEY` and `SUPABASE_PUBLISHABLE_KEY` |

Put them in `voicebox/.env.local` (copy `voicebox/.env.example` if it is
missing). `.env.local` is gitignored — keep it that way.

> Never put the **service_role** key in any `VITE_`-prefixed variable. Vite
> inlines those into the client bundle, which would publish a key that
> bypasses every RLS policy. `verify-auth.ps1` fails the run if it sees one.

### 3. Create the tables

**Dashboard → SQL Editor → New query**, paste all of
[`migrations/0001_init.sql`](migrations/0001_init.sql), press **Run**.

It is idempotent (`create table if not exists`, `drop policy if exists`), so
re-running it is safe.

That creates `profiles`, `phrases`, `corrections`, their indexes, RLS
policies scoped to `auth.uid()`, and the `on_auth_user_created` trigger that
fills in `profiles.display_name` from the sign-up form.

### 4. Allow email sign-in

**Dashboard → Authentication → Providers → Email**: enabled.

For local testing also turn **Confirm email → off**, otherwise sign-up
succeeds but sign-in fails until the emailed link is clicked — and the app
reports that as "confirm your email address", which is easy to miss.

### 5. Verify

```powershell
powershell -ExecutionPolicy Bypass -File scripts\verify-auth.ps1
```

It checks DNS, the auth endpoint, whether email sign-in and sign-ups are on,
whether confirmation is required, and that all three tables exist and return
nothing to an anonymous caller. It creates no accounts and writes no rows.

Then sign up at `/auth` in the app.

## Why RLS matters more than usual here

The app queries phrases **without** a `user_id` filter:

```ts
// src/routes/index.tsx
supabase.from("phrases").select("text").order("last_used_at", { ascending: false })
```

There is no `.eq("user_id", user.id)` anywhere in the codebase. Row scoping is
done **entirely** by Row Level Security. With RLS off — or a policy written
`using (true)` — every signed-in user would silently read every other user's
spoken phrases, which for this app is medical-adjacent personal speech.

So: keep RLS enabled, keep policies scoped to `auth.uid()`, and prefer fixing
a policy over adding a client-side filter.

`verify-auth.ps1` catches the blatant case (rows returned anonymously) but
**cannot prove inter-user isolation on an empty database**. To confirm that
properly: sign up two accounts, save a phrase in each, and check that neither
sees the other's on `/profile`.

## Schema

```
profiles                       phrases                        corrections
--------                       -------                        -----------
id           uuid PK ->users   id           uuid PK           id                  uuid PK
display_name text NULL         user_id      uuid ->users      user_id             uuid ->users
created_at   timestamptz       text         text              original_prediction text
                               last_used_at timestamptz       corrected_word      text
                                                              created_at          timestamptz
```

Column names and types mirror
`voicebox/src/integrations/supabase/types.ts` exactly. If you change the
schema, regenerate those types or the two will drift apart silently:

```powershell
npx supabase gen types typescript --project-id <your-project-ref> > voicebox\src\integrations\supabase\types.ts
```

`corrections` is typed and has policies but is not read by the UI yet.

## Note on `phrases` growth

`index.tsx` calls plain `.insert()` on every spoken phrase, so saying the same
sentence twice stores two rows; duplicates are collapsed client-side with
`new Set()`. The migration deliberately has **no** unique constraint on
`(user_id, text)`, because one would make the second insert fail.

For real dedupe, add the constraint and switch that call to an upsert so
repeats refresh the timestamp instead of erroring:

```sql
alter table public.phrases
  add constraint phrases_user_text_unique unique (user_id, text);
```

```ts
.upsert({ user_id: user.id, text, last_used_at: new Date().toISOString() },
        { onConflict: "user_id,text" })
```

Both changes must land together.
