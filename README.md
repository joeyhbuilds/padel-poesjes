# Padel Hub

## What deploys

**`index.html`** is the app. It is the only file that gets served. Push to `main` and
Netlify publishes it automatically; the publish directory is the repo root, so the file
must keep this name or `/` returns 404.

**Do not drag-and-drop onto Netlify.** The site is Git-connected. A manual deploy is
reverted by the next push and vice versa.

## Three lineages, and which one is in `index.html`

There are three divergent versions of this app. Keeping them straight matters, because
two of them are missing something the third has.

| file | sha1 | has dedup fix | has newer UI |
|---|---|---|---|
| `archive/padel-hub-2026-08-04-with-dedup-fix.html` | `ede6e8db…` | yes | no |
| `index.html` (current) | `31a9bbba…` | **no** | yes |
| `padel-hub.original-backup.html` | `1882b8ef…` | no | no |

The `ede6e8db` build is what Netlify actually served from 2026-08-04 until 2026-08-30,
confirmed from deploy `6a71e15b779b606d5abf6fdf`, which contained exactly one file,
`/index.html`, sha1 `ede6e8db60699f3afef8af55d8703e41cf795644`. The 2026-08-24 session
was played on it.

The current `index.html` carries newer UI work (keyboard PIN entry, full-width save
button, partial re-render on score entry so the mobile keyboard no longer closes) but
was branched from the pre-fix backup, so its `saveRound` is byte-identical to
`padel-hub.original-backup.html` and the duplicate-points fix is absent. Porting the
fix onto it is the next change.

## Deploy
1. Edit `index.html`
2. `git commit` and `git push origin main`
3. Live in ~30 seconds

Netlify site: account `jh2593`, site_id `518bb4c6-b204-4cb1-9bc3-ee7a325248ff`.
Rollback is the Deploys tab, restore a previous deploy.

## Backend
`https://mobsafcoqqtdauwgmuos.supabase.co` — the migrated joeyhbuilds project.
URL and publishable key are two `const` lines at the top of the `<script>` block.
Verified: no reference to the old personal-account project remains in the file.

---

## The duplicate-points bug — what it was and what changed

> **Status: this fix is NOT in the current `index.html`.** Everything below describes
> the `ede6e8db` build in `archive/`. The UI work now in `index.html` was branched from
> the pre-fix backup, so the bug is live again in the deployed file. Porting it forward
> is the next change. Keeping this section because the diagnosis and the one-time data
> repair below are still accurate and still the reference for redoing the fix.

`PADEL_HUB_PROJECT.md` listed it as "score edit after save re-adds to game_log
instead of replacing". Both halves of it were live:

1. `saveRound` did a plain `sbPost('game_log', …)` with no delete first. Unlocking
   a saved round and saving again inserted a **second copy of every match**. That
   copy is read by the leaderboard's recent-sessions query, so it corrupted PPG
   and win rate — the actual rankings.
2. Player totals were incremented read-modify-write
   (`points: existing.points + delta`), so a re-save double-counted again, and a
   wrong total could never correct itself. Same pattern for `duo_log` and for the
   `sessions` counter.

### The fix (three changes in the script)
- `saveRound` now deletes `game_log` rows for `session_date + group_id + round`
  before inserting. Scoped so it can never touch another session.
- New `recomputeTotals()` rebuilds `players.points/games/wins/sessions` from
  `game_log` instead of incrementing. Any bad total now self-heals on the next save.
- New `recomputeDuoLog(date, groupId)` rebuilds that date's duo rows the same way.
  `renderDuos` sums rows per pair, so per-session rows aggregate identically to
  the old one-row-per-pair shape.

### One-time data repair (already applied to the live database)
- Deleted one duplicated match: 2026-07-06 round 10, Michael+Alf vs Martin+Heytor
  1–4, which had been inserted twice three seconds apart. `game_log` went 54 → 53
  rows, score checksum 301 → 296.
- Rewrote every player total from `game_log`. Verified 0 players out of sync and
  0 remaining duplicates.

| player  | before | after |
|---------|--------|-------|
| Joey    | 324    | 76    |
| Michael | 255    | 10    |
| James   | 145    | 129   |
| Martin  | 132    | 118   |
| Alf     | 105    | 92    |
| Heytor  | 97     | 91    |

The "after" column is what the matches actually say. Stijn, Tomek, Ivo and Imran
were already correct.

### Verified
Ran the patched save path against a throwaway date on the live database:

```
baseline        rows=0  James:129pts/35g/24w/6s
after 1st save  rows=1  James:135pts/36g/25w/7s
after re-save   rows=1  James:135pts/36g/25w/7s   <- was rows=2, 141pts under the old code
after edit 3-5  rows=1  James:132pts/36g/24w/7s   <- tracks the correction, no accumulation
after cleanup   rows=0  James:129pts/35g/24w/6s   <- exact baseline
```

Test rows removed; database confirmed at 53 rows with no strays.

## Keep-alive (recorded 2026-08-04, not re-verified)
Workflow `6LQjGKc5pPYIFqYc`, every 2 days at 09:10 Europe/Amsterdam.
Not re-checked against n8n execution history in this session, so treat "active" as a
claim from the original install note rather than a verified fact.

It was blocked for weeks waiting on a Postgres password. That turned out to be
the wrong design: the open question in the migration notes was whether a direct
Postgres connection even resets Supabase's inactivity clock, and REST traffic
certainly does. So the node is now an HTTP Request hitting
`/rest/v1/players?select=id&limit=1` with the publishable key — no password
needed, and it exercises the same path the app uses. Endpoint tested: HTTP 200
in 0.48s. n8n was restarted afterwards so the schedule actually registered.

Note this protects **access**, not data — it stops the free tier pausing the
project. Pausing never deleted data anyway. Data loss is what the weekly backup
below is for.

## Still open
- **RLS is fully open** (permissive policies on every table) and the publishable
  key ships in this HTML, so anyone who opens devtools can wipe every row. Needs
  an auth decision before it can be tightened. Tracked on the Notion board.

---

## Weekly backup (installed 2026-08-04)

`~/n8n-docker/padel-backup.sh`, run by launchd agent
`com.joeyhbuilds.padel-backup` every Sunday 08:00 local (catches up on next wake
if the Mac was asleep). Writes
`~/Documents/padel-backups/padel-YYYY-MM-DD/<table>.json` plus a manifest with
row counts and the game_log score checksum. Keeps the last 12 weeks.

**Deliberately not an n8n workflow.** A backup must not depend on the thing that
might be broken — this still runs if Docker or n8n is down. It uses only the
publishable key, which is already public in `padel-hub.html`, so there is no
secret in the script.

Alerts to Telegram (same bot as the newsletter heartbeat) if a table fails to
dump, returns unparseable JSON, or if `game_log` comes back empty — an empty
game_log means the scores were wiped, not that nothing happened.

Verified on install: manual run OK; forced launchd run exit 0 with empty stderr
(so it works under launchd's minimal PATH, not just an interactive shell);
counts matched the live DB exactly (groups 2, players 10, game_log 53, duo_log 8,
active_session 1, checksum 296); failure path tested with a deliberately bad
table name and it logged + raised the alert as intended.

Restore is a plain REST insert per table from the JSON, groups first (everything
FKs to it) — same order as `~/Documents/padel-migration/02-data.sql`.
