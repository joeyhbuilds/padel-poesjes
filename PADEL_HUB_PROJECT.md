# Padel Hub — Project Handoff

## Overview
Padel Hub is a single-file web app (`padel-hub.html`) for managing casual padel sessions across two friend groups. It handles session planning, live score tracking, a persistent leaderboard, and Instagram-shareable stat cards.

**Live URL:** https://padel-poesjes.netlify.app  
**Deployment:** Netlify — drag-and-drop single HTML file, no build process, no CLI, no repo  
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
id int primary key default 1   -- always 1 row, upserted on conflict
data jsonb not null            -- full session object (see Session Object below)
group_id uuid
session_mode text default 'individual'
created_at timestamptz default now()
```

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
- **Window:** Last 10 sessions only
- **Minimum:** 2 games to appear as ranked (below = Unranked)
- **Group filter:** All groups / per group

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
- **Protected actions:** Build/rebuild sessions, edit saved scores, remove/rename players, reset all data
- **Non-admin can:** View session, enter scores, view leaderboard/history

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
No CI/CD. Manual process:
1. Edit `padel-hub.html`
2. Go to netlify.com → site dashboard → Deploys tab
3. Drag the file onto the deploy zone
4. Done — live in ~10 seconds

---

## Known Issues / Open Tasks
- RLS policies are fully open — tightening needed (own task, not urgent)
- Score edit after save re-adds to game_log instead of replacing — causes duplicate points (known bug, needs fix)
- The keep-alive workflow needs Postgres credentials for the new Supabase project before it can be activated
- Leaderboard group filter requires existing players to have group_id set — run `update players set group_id = '[poesjes-uuid]' where group_id is null` after migration

---

## Key People
- **Joey** — owner, admin (PIN: 6969)
- **Alf** — "Marge Simpson Alf" — trusted user, has admin PIN
- **Groups:** Padel Poesjes (6 members), Padelleyballers (4 members)
