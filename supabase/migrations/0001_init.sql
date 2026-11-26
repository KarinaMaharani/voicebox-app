-- VoiceBox initial schema
--
-- Run this once against a fresh Supabase project:
--   Dashboard -> SQL Editor -> New query -> paste -> Run
--
-- Derived from voicebox/src/integrations/supabase/types.ts and the queries in
-- src/routes/index.tsx, src/routes/auth.tsx and
-- src/routes/_authenticated/profile.tsx. Column names and types match those
-- exactly; changing one here means changing the TypeScript types too.
--
-- SECURITY NOTE, please read before editing the policies below.
-- The app queries phrases WITHOUT a user_id filter, e.g.
--
--     supabase.from("phrases").select("text").order("last_used_at", ...)
--
-- There is no `.eq("user_id", user.id)` anywhere. Row scoping is therefore
-- done ENTIRELY by Row Level Security. If RLS is disabled, or a policy uses
-- `using (true)`, every signed-in user silently reads every other user's
-- spoken phrases — which for this app is medical-adjacent personal speech.
-- Keep RLS enabled and keep every policy scoped to auth.uid().

-- ---------------------------------------------------------------- profiles
-- One row per auth user, created automatically by the trigger at the bottom.
create table if not exists public.profiles (
  id           uuid        primary key references auth.users (id) on delete cascade,
  display_name text,
  created_at   timestamptz not null default now()
);

alter table public.profiles enable row level security;

drop policy if exists "profiles_select_own" on public.profiles;
create policy "profiles_select_own"
  on public.profiles for select
  using (auth.uid() = id);

drop policy if exists "profiles_update_own" on public.profiles;
create policy "profiles_update_own"
  on public.profiles for update
  using (auth.uid() = id)
  with check (auth.uid() = id);

drop policy if exists "profiles_insert_own" on public.profiles;
create policy "profiles_insert_own"
  on public.profiles for insert
  with check (auth.uid() = id);

-- ----------------------------------------------------------------- phrases
-- Spoken phrase history, used to rank word suggestions.
--
-- No unique constraint on (user_id, text) on purpose: index.tsx uses plain
-- .insert() on every speak, so a unique index would make the second use of a
-- phrase fail. Duplicates are collapsed client-side with new Set(). If you
-- later want true dedupe, add the constraint AND switch that call to
--   .upsert({...}, { onConflict: "user_id,text" })
-- so repeats refresh last_used_at instead of erroring.
create table if not exists public.phrases (
  id           uuid        primary key default gen_random_uuid(),
  user_id      uuid        not null references auth.users (id) on delete cascade,
  text         text        not null,
  last_used_at timestamptz not null default now()
);

-- Matches the app's only access pattern: own rows, newest first.
create index if not exists phrases_user_recent_idx
  on public.phrases (user_id, last_used_at desc);

alter table public.phrases enable row level security;

drop policy if exists "phrases_select_own" on public.phrases;
create policy "phrases_select_own"
  on public.phrases for select
  using (auth.uid() = user_id);

drop policy if exists "phrases_insert_own" on public.phrases;
create policy "phrases_insert_own"
  on public.phrases for insert
  with check (auth.uid() = user_id);

drop policy if exists "phrases_update_own" on public.phrases;
create policy "phrases_update_own"
  on public.phrases for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

drop policy if exists "phrases_delete_own" on public.phrases;
create policy "phrases_delete_own"
  on public.phrases for delete
  using (auth.uid() = user_id);

-- ------------------------------------------------------------- corrections
-- When the user edits a predicted word, the pair is kept so suggestions can
-- learn from it. Typed in types.ts; not yet queried by the UI.
create table if not exists public.corrections (
  id                  uuid        primary key default gen_random_uuid(),
  user_id             uuid        not null references auth.users (id) on delete cascade,
  original_prediction text        not null,
  corrected_word      text        not null,
  created_at          timestamptz not null default now()
);

create index if not exists corrections_user_created_idx
  on public.corrections (user_id, created_at desc);

alter table public.corrections enable row level security;

drop policy if exists "corrections_select_own" on public.corrections;
create policy "corrections_select_own"
  on public.corrections for select
  using (auth.uid() = user_id);

drop policy if exists "corrections_insert_own" on public.corrections;
create policy "corrections_insert_own"
  on public.corrections for insert
  with check (auth.uid() = user_id);

drop policy if exists "corrections_delete_own" on public.corrections;
create policy "corrections_delete_own"
  on public.corrections for delete
  using (auth.uid() = user_id);

-- ------------------------------------------------- profile auto-creation
-- auth.tsx signs users up with
--     options: { data: { display_name: ... } }
-- which lands in auth.users.raw_user_meta_data. Without this trigger the
-- profiles row never exists, and profile.tsx shows an empty display name
-- forever with no error to explain why.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, display_name)
  values (
    new.id,
    coalesce(
      nullif(new.raw_user_meta_data ->> 'display_name', ''),
      split_part(new.email, '@', 1)
    )
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Backfill profiles for any users that already exist (re-running is safe).
insert into public.profiles (id, display_name)
select
  u.id,
  coalesce(
    nullif(u.raw_user_meta_data ->> 'display_name', ''),
    split_part(u.email, '@', 1)
  )
from auth.users u
on conflict (id) do nothing;
