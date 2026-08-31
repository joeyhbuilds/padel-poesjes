# Padel Hub — Project Handoff

## Overview
Padel Hub is a single-file web app (`padel-hub.html`) for managing casual padel sessions across two friend groups. It handles session planning, live score tracking, a persistent leaderboard, and Instagram-shareable stat cards.

**Live URL:** https://padel-poesjes.netlify.app  
**Deployment:** Netlify, auto-deployed from GitHub `joeyhbuilds/padel-poesjes` on push to `main`. No build step.  
**Backend:** Supabase (Postgres + REST API)  
**Architecture:** 100% client-side. No framework, no bundler, no npm. Pure HTML/CSS/JS in one file.

---

## Supabase

**Project:** joeyhbuilds account  
**URL:** `https://mobsafcoqqtdauwgmuos.supabase.co`  
**Anon key:** `sb_publishable_4rPADCUxVWPevzebhcRhCQ_GioDLhZm`

> ⚠️ Note: The app uses Supabase's publishable key (new format). All API calls go through the REST endpoint at `/rest/v1/`. No Supabase JS SDK is used — raw fetch calls only.

> ⚠️ RLS note: All tables have RLS enabled with `using (true) with check (true)` — fully open. Anyone with the key can insert/update/delete. This is intentional for now (public group app) but should be tightened in a future task.

---

## Database Schema

Five tables:

### `groups`
```sql
id uuid primary key default gen_random_uuid()
name text unique not null
emoji text default '🎾'
created_at timestamptz default now()
```
Pre-populated with:
- Padel Poesjes 🐱
- Padelleyballers 🏐

### `players`
```sql
id uuid primary key default gen_random_uuid()
name text unique not null
points int default 0        -- all-time total games won (Americano scoring)
games int default 0         -- all-time matches played
wins int default 0          -- all-time match wins
sessions int default 0      -- number of sessions attended
group_id uuid references groups(id)
updated_at timestamptz default now()
```

### `game_log`
```sql
id uuid primary key default gen_random_uuid()
session_id text            -- which session produced this row; see Session identity below
session_date date not null
round int
court int default 1
team1 text[]               -- array of player names
team2 text[]
score1 int                 -- total games won by team1 across all sets
score2 int
sets_detail jsonb          -- [{t1, t2, tb1?, tb2?}] per set
group_id uuid references groups(id)
created_at timestamptz default now()
```

### `active_session`
```sql
id int primary key default nextval('active_session_id_seq')
data jsonb not null            -- full session object (see Session Object below)
group_id uuid not null unique  -- active_session_group_id_key
session_mode text default 'individual'
created_at timestamptz default now()
```
**Rotation plan only, one row per group**, upserted with `on_conflict=group_id`.
It carries the date, players, settings, the matches and `cancelled`. It is written by
exactly four actions: build, regenerate, add-round and cancel. **`saveRound` does not write
it.** Which rounds are saved, and their scores, are derived from `game_log` on read.
Upserted with `on_conflict=group_id`. It used to be a single global
row keyed `id=1`, which meant building a Padelleyballers session silently destroyed a live
Padel Poesjes one, and made a delete-session button impossible to implement correctly.
Migration applied 2026-08-30.

### `duo_log`
```sql
id uuid primary key default gen_random_uuid()
group_id uuid references groups(id)
session_date date not null
player1 text not null
player2 text not null
points int default 0
sets_won int default 0
matches int default 0
wins int default 0
created_at timestamptz default now()
```

---

## Session Object (active_session.data)
```json
{
  "date": "2026-07-06",
  "players": ["Joey", "Michael", "Martin", "Alf"],
  "courts": 1,
  "startTime": "18:00",
  "gameLen": 20,
  "sessionLen": 90,
  "isDuo": false,
  "is1v1": false,
  "sessionMode": "individual",
  "duoPairs": [],
  "groupId": "uuid",
  "groupName": "Padel Poesjes",
  "groupEmoji": "🐱",
  "targetScore": null,
  "location": null,
  "notes": null,
  "playCount": {"Joey": 4, "Michael": 4, "Martin": 4, "Alf": 4},
  "maxPairReuse": 1,
  "maxMatchupReuse": 1,
  "allSaved": false,
  "sessionId": "m1abc23xy",
  "cancelled": false,
  "rounds": [
    {
      "round": 1,
      "matches": [
        {
          "court": 1,
          "team1": ["Joey", "Alf"],
          "team2": ["Michael", "Martin"]
        }
      ],
      "sitting": [],
      "scores": [
        {
          "sets": [
            {"t1": "6", "t2": "4"},
            {"t1": "3", "t2": "2"},
            {"t1": "", "t2": ""}
          ],
          "saved": false
        }
      ],
      "roundSaved": false
    }
  ]
}
```

---

## Scoring System
**Format:** Americano with proper set-based scoring  
**Score entry:** Games per set (e.g. Set 1: 6–4, Set 2: 3–2 at buzzer)  
**Points:** Total games won across all sets = personal leaderboard points  
**Tiebreak:** At 6–6 in a set, TB score boxes appear  
**Win:** Determined by sets won (majority of sets played)

---

## Leaderboard Logic
- **Ranked by:** PPG (points per game average)
- **Tiebreaker:** Win rate
- **Window:** All sessions, lifetime. The 10-session cap was removed 2026-08-30.
- **Minimum:** 2 games to appear as ranked (below = Unranked)
- **Group filter:** All groups / per group

`renderLeaderboard` issues ONE projected `game_log` query and filters in the browser. It
used to slice to the last 10 dates and then fire one HTTP request per date, so removing the
cap without changing the query would have meant one request per session, forever.

### Live session standings
The Session tab carries a separate `renderTodayPanel`, ranked by points scored today with
PPG as the tiebreak and a `played n/N` column. It is derived from `game_log`, not from
`currentSession`, because any phone that saves a round overwrites `active_session` with its
own copy of the blob. Saved rounds only. Collapsed to a one-line leader strip by default.

---

## Rotation Engine
Key rules baked into `buildRotation()`:
1. **Sit-out fairness:** Hard queue — no one sits twice before everyone has sat once
2. **Partnership uniqueness:** −1000 penalty for repeated partnerships within a session (effectively hard block)
3. **Matchup variety:** −50 penalty for repeated matchups within a session
4. **Cross-session memory:** Fetches last session's pairs from game_log, adds −15 penalty
5. **4-player special case:** Explicitly enumerates all 3 unique pairings and cycles through them
6. **Serpentine seeding:** Strong+weak pairing (rank1+rank4 vs rank2+rank3) for balanced teams
7. **Seed minimum:** 2 games played before a player is seeded

---

## Session Modes
- **Individual:** Random rotating partners, serpentine seeded
- **Duo:** Fixed pre-defined pairs, rotation randomises which pair plays which
- **1v1:** Singles matches, game duration optional (can play to target score)

---

## Admin System
- **PIN:** `6969`
- **PIN-gated actions:** Build/rebuild sessions, cancel a session, edit saved scores,
  remove/rename players. **Reset all data was removed from the app on 2026-08-31** and is
  now a deliberate SQL operation, see `sql/manual-reset-all-data.sql`. It was the only code
  path that deleted players, groups or the session row, and removing it is what allowed
  those DELETE grants to be revoked.
- **Everyone can:** View sessions, enter and save scores, view leaderboard/history

> This is a usability guard, not a security control, and must never be described as
> "admin only". `isAdmin` is a browser variable, the PIN is readable in view-source, and RLS
> is fully permissive, so anyone who opens devtools can perform any of these actions
> directly against the REST API. `isAdmin` is also never reset on group switch, so one PIN
> entry makes that browser tab admin until it is reloaded.

---

## App Features
- Group selector on open (Padel Poesjes / Padelleyballers / add new)
- URL hash navigation: `#plan`, `#session`, `#board`, `#duos`, `#history`
- Session tab: date picker, shows active session or history for that date
- Score entry: Set 1/2/3 per match, TB at 6–6, auto-save drafts to localStorage
- Leaderboard: clean table, tap player → profile card slides up
- Share card: Instagram share button triggers native iOS/Android share sheet
- History: filterable by group and date
- Duo leaderboard: separate tab, pair win rates
- Dynamic round extension: "＋ Add round" appears after session complete
- Rebuild flow: "↺ Regenerate" modal with "Keep settings" or "Start fresh"

---

## Deployment
Push to `main`. Netlify builds and publishes automatically.

1. Edit `index.html`
2. `git commit` and `git push origin main`
3. Live in ~30 seconds

**The deployed file must be named `index.html` at the repo root.** Netlify's publish
directory for this site is the repo root with no build command, so `/` is served from
`index.html`. A file named `padel-hub.html` produces a 404 at `/`. Verified from the
last known-good deploy (2026-08-04, id `6a71e15b779b606d5abf6fdf`), which contained a
single file, `/index.html`, sha1 `ede6e8db60699f3afef8af55d8703e41cf795644`.

**Do not drag-and-drop onto Netlify any more.** The site is Git-connected, so a manual
deploy is silently reverted by the next push, and a push silently reverts a manual
deploy. One write path only.

**Netlify site identity:** account `jh2593` (not `joeyhbuilds`),
site_id `518bb4c6-b204-4cb1-9bc3-ee7a325248ff`.

**Rollback:** restore a previous deploy from the Netlify Deploys tab, or
`POST /api/v1/sites/{site_id}/deploys/{deploy_id}/restore`.

---

## Known Issues / Open Tasks

### Open
- **RLS is fully open.** Every table is `using(true) with check(true)` and both the
  publishable key and `ADMIN_PIN` ship in this HTML, so anyone with devtools can wipe every
  row. `resetAll()` does exactly that in four calls. This is the only item on this list that
  changes the actual risk profile; the admin PIN is a usability guard, not a control.
  Never describe any feature in this app as "admin only".
- **`players` is keyed on name alone, with one `group_id` per row.** Joey plays in both
  groups, so his single row carries both groups' points and the group-filtered board shows a
  cross-group total for him. Fixing it means a `(name, group_id)` key.
- **2026-07-27 holds 5 matches in 2 round slots** (three rows at round 1, two at round 2).
  Joey confirmed these were really played, so the round NUMBERING is wrong rather than the
  rows. Left alone deliberately. It blocks a `UNIQUE (session_date, group_id, round, court)`
  constraint, which would otherwise make duplicate rounds impossible at the database rather
  than relying on every future client build keeping the fix.
- **Keep-alive** is recorded in README as an n8n workflow live since 2026-08-04. Not
  re-verified against n8n execution history. A GitHub Action would remove the dependency on
  Joey's Mac being awake.
- `unlockRoundEdit` does not work: it clears `roundSaved` then calls
  `loadSessionsForDate`, which immediately overwrites `currentSession` from the server copy
  where the round is still saved. Pre-existing, unrelated to the 2026-08-30 work.
- Player names are interpolated into `onclick="openPlayerCard('${name}')"`, so a name
  containing an apostrophe breaks that row.

### Resolved 2026-08-30
- Duplicate points on re-save. `saveRound` replaces the individual match (court plus both
  team line-ups) rather than appending, and totals are rebuilt from `game_log` rather than
  incremented, so a wrong total now self-heals on the next save.
- Cross-group session destruction, via one `active_session` row per group.
- Players present in `game_log` with no `players` row. Hidde had played 5 matches on
  2026-08-24 and was invisible on the board; `recomputeTotals` now creates the missing row.
- Leaderboard group filter and `group_id` backfill: no longer outstanding, all 11 players
  carry a `group_id`.

---

## Key People
- **Joey** — owner, admin (PIN: 6969)
- **Alf** — "Marge Simpson Alf" — trusted user, has admin PIN
- **Groups:** Padel Poesjes (6 members), Padelleyballers (4 members)


---

## Changelog

### 2026-08-30 — repo, deploy pipeline, correctness, UX

**Deployment moved to GitHub.** The site is Git-connected to `joeyhbuilds/padel-poesjes`,
publish directory is the repo root, no build command, so the served file must be
`index.html`. Drag-and-drop deploys must not be used any more: a manual deploy is reverted
by the next push and vice versa.

**Outage.** The site 404'd from ~2026-08-30 11:43 until 12:15 because connecting Netlify to
the then-empty repo published a tree containing only a README. Restored by republishing
deploy `6a71e15b779b606d5abf6fdf`. Netlify Free additionally refuses to build a private repo
unless the pushing GitHub identity is a verified member of the Netlify team, which the
`joeyhbuilds` account is not; the repo is public for that reason.

**Correctness**
- Round save replaces the individual match, not the whole `(date, group, round)` slot, so a
  second session on the same date can no longer destroy the first.
- Writes POST before they DELETE everywhere, so a failed save can never leave a round with
  no rows at all. Duplicates are recoverable by saving again; missing matches are not.
- Save button is disabled for the whole network round trip. A double tap on slow wifi was
  the ordinary way this app produced duplicate matches.
- `recomputeTotals` creates missing `players` rows, one at a time tolerating conflicts, so
  one collision cannot abort a save and report a false "Save failed" for a round that was
  in fact written.
- Renaming a player now rewrites `game_log` and `duo_log` names first, then `players`.
  Renaming used to leave the log holding the old name, so the next recompute zeroed the
  renamed row and resurrected the old one.
- Staleness guard: a save re-reads `active_session` and aborts if the session was cancelled,
  replaced, or is for another date, instead of silently resurrecting it via the upsert.
- Draft scores are keyed per session. The old global key could paste one night's scores onto
  another night's matches by round index.

**Features**
- Lifetime ranking window.
- Session admin sheet with Regenerate and a soft Cancel (`data.cancelled`, never a DELETE,
  so it is reversible and cannot be undone by a stale phone).
- Live standings for the session in progress.
- App opens on the Session tab when a live session exists for today.

**UX**, measured at 375px before and after
- 25 of 27 interactive elements were under the 44px touch minimum; navigation tabs were 23px
  tall at 10px type. All now 44px or more, inputs at 16px so iOS stops zooming on focus.
- Session page height 4859px to 1824px. Rounds collapse, the round being played is expanded,
  badged NOW and scrolled to.
- Score boxes on a 10-round session 60 to 2. Set 2 and Set 3 sit behind a `＋ Set N` control:
  across all 59 recorded matches, Set 1 was used 100% of the time and Sets 2 and 3 zero.
- `.lb-remove` and `.lb-rename` had no CSS rule at all and rendered as 14x19px default OS
  buttons; they are now styled 34px controls.


### 2026-08-31 — RLS, session identity, and the multi-phone override bug

**The bug reported after the first real session.** Several phones each held their own copy
of the session and `saveRound` upserted the *whole* blob, so the last phone to save reverted
every other phone's `roundSaved` flags and scores. No score was ever lost from `game_log`,
but the screen lied about what was recorded and people re-entered rounds already saved. It
also fooled the maintainer into reporting that nothing had been saved at all.

Fixed structurally rather than narrowed: `active_session.data` is now the rotation plan
only, and saved-state plus scores are derived from `game_log` on read. The concurrent write
no longer exists.

**Session identity.** Matching a `game_log` row to a planned match used court plus both
line-ups. With 6 players on one court there are 45 possible pairings, so after a regenerate
a new round could coincidentally match an old saved one (~2% per round, ~20% across ten),
render as already saved, hide the Save button, and the game played would never be recorded.
`game_log.session_id` makes that a key. Existing rows are backfilled to
`legacy-<date>-<group>`. Line-ups are still checked even when session ids agree.

**RLS.** Reads stay public and inserts stay open, because the app needs them and the key
ships in the HTML, so this is mitigation and not a boundary. What was removed: DELETE on
`players`, `groups` and `active_session`; UPDATE on `groups`; and UPDATE on `game_log`
narrowed by column grant to `team1, team2` so match scores can never be rewritten in place.
Grants are revoked from `authenticated` as well as `anon`, because signups are open on this
project so anyone with the key can mint an authenticated token.

An earlier draft of this migration froze history behind a 7-day window. It was abandoned: it
would have frozen 76% of `game_log` and 100% of `duo_log` on day one, was shorter than the
median gap between sessions, and removed DELETE, which is the app's own repair for the
duplicate bug this project's whole history is about. A blocked DELETE returns 200 with an
empty body, so editing an older session would have silently duplicated it with no way back.

**Write verification.** `sbDelete` now returns the rows it removed and every caller asserts
on the count. A delete that removed nothing used to be indistinguishable from success.

**Still open after this**
- Signups are enabled on the Supabase project. Any policy written against `anon` alone can
  be sidestepped by creating an account, which is why the grants also name `authenticated`.
  Turning signups off is a free, larger improvement than most of this migration.
- The publishable key is in the HTML. Someone who reads the JS can still insert junk rows.
  A real boundary needs auth or a server-side write proxy.
