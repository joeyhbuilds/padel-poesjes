-- Padel Hub, 2026-08-31
-- (1) session identity on game_log, (2) RLS narrowed to what the app actually does.
--
-- What this deliberately does NOT do: freeze history behind a date window. An earlier
-- draft did, and it was aimed at the wrong risk. Every documented failure in this project
-- is accidental DUPLICATION, and the app's own repair mechanism for that is DELETE. A
-- blocked DELETE returns 200 with an empty body (the app sends Prefer:
-- return=representation), indistinguishable from success unless the caller counts rows,
-- so windowing it would have turned an
-- edit to an older session into a duplicate the app could not undo. The wipe scenario it
-- guarded against is already covered by the weekly backup and its Telegram alarm.
--
-- What it does do: remove capabilities the app never uses, and make scores unrewritable.

begin;
set local lock_timeout = '5s';

-- ---------------------------------------------------------------------------
-- 1. Session identity.
-- Matching a game_log row back to the session that produced it is currently done by
-- comparing court plus both line-ups. With 6 players on one court there are 45 possible
-- pairings, so after a regenerate a new round coincidentally matches an old saved one
-- roughly 2% of the time, ~20% across ten rounds. When it does, the round renders as
-- already saved, the Save button disappears, and the game actually played is never
-- recorded. A session id turns that heuristic into a key.
-- ---------------------------------------------------------------------------
alter table public.game_log add column if not exists session_id text;
create index if not exists game_log_lookup_idx
  on public.game_log (session_date, group_id, round);

-- Backfill. Without this all 69 existing rows keep session_id NULL, the matcher stays on
-- the line-up heuristic for every one of them, and the collision this column exists to
-- prevent is still live for historical dates. Partitioning legacy rows by date+group is not
-- a true session id, but it stops a NEW session's round coincidentally matching an OLD
-- rotation's row.
update public.game_log
   set session_id = 'legacy-'||session_date::text||'-'||coalesce(group_id::text,'nogroup')
 where session_id is null;

-- Sanity bound on session_date. CHECK must be immutable, so these are fixed dates rather
-- than a rolling window; the point is to catch a typo like 2062, not to expire anything.
alter table public.game_log drop constraint if exists game_log_session_date_sane;
alter table public.game_log add constraint game_log_session_date_sane
  check (session_date between date '2020-01-01' and date '2035-01-01');

-- ---------------------------------------------------------------------------
-- 2. Re-assert RLS, then replace the blanket policies.
-- ---------------------------------------------------------------------------
alter table public.groups         enable row level security;
alter table public.players        enable row level security;
alter table public.game_log       enable row level security;
alter table public.duo_log        enable row level security;
alter table public.active_session enable row level security;

do $$
declare p record;
begin
  for p in
    select schemaname, tablename, policyname
      from pg_policies
     where schemaname = 'public'
       and tablename in ('groups','players','game_log','duo_log','active_session')
  loop
    execute format('drop policy %I on %I.%I', p.policyname, p.schemaname, p.tablename);
  end loop;
end $$;

-- game_log and duo_log keep full CRUD: DELETE is how a re-saved round replaces itself.
create policy game_log_all on public.game_log for all using (true) with check (true);
create policy duo_log_all  on public.duo_log  for all using (true) with check (true);

-- players: totals are rebuilt from game_log constantly. The app never deletes a player.
create policy players_select on public.players for select using (true);
create policy players_insert on public.players for insert with check (true);
create policy players_update on public.players for update using (true) with check (true);

-- groups: created from the UI, never modified or removed by it.
create policy groups_select on public.groups for select using (true);
create policy groups_insert on public.groups for insert with check (true);

-- active_session: upserted constantly, cancelled via data.cancelled, never deleted.
create policy active_session_select on public.active_session for select using (true);
create policy active_session_insert on public.active_session for insert with check (true);
create policy active_session_update on public.active_session for update using (true) with check (true);

-- ---------------------------------------------------------------------------
-- 3. Privilege-level controls. These bind regardless of policies, and they cover
-- `authenticated` as well as `anon` because signups are currently open on this project,
-- so anyone holding the publishable key can mint an authenticated token.
-- ---------------------------------------------------------------------------
revoke delete on public.players, public.groups, public.active_session from anon, authenticated;
revoke update on public.groups from anon, authenticated;

-- The only UPDATE the app performs on game_log is the rename rewriting team1/team2.
-- Match scores must never be editable in place.
revoke update on public.game_log from anon, authenticated;
grant  update (team1, team2) on public.game_log to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. Assert it actually took, inside the transaction, so a silent no-op rolls back.
-- ---------------------------------------------------------------------------
do $$
begin
  if has_column_privilege('anon','public.game_log','score1','update')
    then raise exception 'FAILED: anon can still update game_log.score1'; end if;
  if not has_column_privilege('anon','public.game_log','team1','update')
    then raise exception 'FAILED: anon cannot update game_log.team1, rename would break'; end if;
  if has_table_privilege('anon','public.players','delete')
    then raise exception 'FAILED: anon can still delete players'; end if;
  if has_table_privilege('anon','public.active_session','delete')
    then raise exception 'FAILED: anon can still delete active_session'; end if;
  if not has_table_privilege('anon','public.game_log','delete')
    then raise exception 'FAILED: anon cannot delete game_log, the dedup repair would break'; end if;
  if not has_column_privilege('anon','public.game_log','session_id','insert')
    then raise exception 'FAILED: anon cannot insert session_id'; end if;
  -- `authenticated` matters as much as `anon`: signups are open on this project, so anyone
  -- holding the publishable key can mint an authenticated token.
  if has_column_privilege('authenticated','public.game_log','score1','update')
    then raise exception 'FAILED: authenticated can still update game_log.score1'; end if;
  if has_table_privilege('authenticated','public.players','delete')
    then raise exception 'FAILED: authenticated can still delete players'; end if;
  if has_table_privilege('authenticated','public.active_session','delete')
    then raise exception 'FAILED: authenticated can still delete active_session'; end if;
  if has_table_privilege('authenticated','public.groups','delete')
    then raise exception 'FAILED: authenticated can still delete groups'; end if;
  -- has_table_privilege reports GRANTs and is blind to RLS, so it can only prove a REVOKE
  -- took. It cannot prove a capability still works; that needs a real request.
  raise notice 'All privilege assertions passed.';
end $$;

-- A stale PostgREST schema cache after adding a column produces PGRST204, which looks
-- exactly like "the migration never ran".
notify pgrst, 'reload schema';

commit;
