# Invariants

Rules that hold across changes to this app. Every one of them exists because it was broken
once, and the note says how. Read this before changing the save path, the session screen, or
anything that derives from `game_log`.

## The source of truth
- **`game_log` is the only source of truth.** `players`, `duo_log`, and the session screen's
  saved-state are caches rebuilt from it, never incremented.
  *Totals were once incremented read-modify-write, so a re-save double-counted and a wrong
  total could never self-correct. Joey's row read 324 points where the matches said 76.*
- **`active_session.data` is the rotation plan, not a record of results.** Nothing that
  several phones write concurrently belongs in one JSON blob.
  *`saveRound` used to upsert the whole blob, so the last phone to save reverted everyone
  else's saved rounds. It also made the maintainer report that a whole session was unsaved.*

## Writes
- **POST before DELETE, always.** A delete-then-failed-insert leaves nothing and nothing to
  rebuild from. Duplicates are recoverable by saving again; missing matches are not.
- **Scope a replace to the individual match**, court plus both sorted line-ups plus session,
  never to the whole `(date, group, round)` slot.
  *A slot-scoped delete destroyed an earlier same-day session's real matches. 2026-07-27 in
  this database has three rotations recorded under round 1.*
- **Every delete and update checks how many rows it affected.** PostgREST returns 200 with an
  empty body when a filter matches nothing or a policy blocks it, which is indistinguishable
  from success.
- **Any button that triggers a network write is disabled for the whole round trip.**
  *Two concurrent saves both read an empty slot, both insert, neither deletes. On club wifi a
  double tap is the normal case, not the edge case.*
- **A read-then-write sequence is not idempotent across devices.** An in-flight guard is
  per-device and cannot see other phones. Where two clients can both act on "there is
  nothing here yet", add a deterministic post-write collapse: sort the collisions by a
  stable key and keep the first, so every client computes the same survivor and the losers
  delete nothing.
  *Four phones saving one round together produced four rows, each having read an empty slot
  before any of them inserted.*
- **Bulk inserts against a unique constraint are all-or-nothing.** Insert per row and tolerate
  the conflict, or one collision aborts an entire operation and reports a false failure for
  work that actually succeeded.

## Derived state
- **Fail loud, never render a confident blank.** If the data a screen is derived from cannot
  be read, say so on screen.
  *A failed `game_log` read rendered a fresh, entirely unsaved session, which would have sent
  six people off to re-enter an evening that was already recorded.*
- **A matcher that is order-insensitive must not write back an order-sensitive value.**
  Sorted line-ups match either orientation; the scores must be flipped to suit.
- **An identity column means backfilling existing rows in the same migration.** An
  un-backfilled key silently leaves the old heuristic in force.
- **Never discard user-typed data because a count changed.** Re-index by a stable key.
  *Drafts were a positional array, so one phone adding a round wiped every other phone's
  typed scores, with no message.*

## Guards and state
- **Null checks come before the properties they guard.** *Reading `live.sessionId` above the
  `!live` test turned a staleness guard into dead code, and its offline `catch` then hid the
  TypeError.*
- **A catch scoped to connectivity must not swallow programming errors.**
- **Pure view toggles never touch the network.** *`loadSessionsForDate`'s catch replaces the
  session view with an error, so expanding a round on bad wifi wiped the screen someone was
  scoring into.*
- **A function that mutates state locally re-renders locally.** *`unlockRoundEdit` called
  `loadSessionsForDate`, which re-read the server copy and discarded the unlock, making the
  Edit button a silent no-op for months.*
- **Any per-phone override must have exactly one place that clears it.** A sticky override
  disables reconciliation for the life of the page.

## Migrations
- **End any migration that adds a column with `notify pgrst, 'reload schema';`.** A stale
  PostgREST cache produces `PGRST204`, which looks exactly like "the migration never ran".
- **`has_table_privilege` is blind to RLS.** Use it to prove a REVOKE took, never to prove a
  capability still works. Prove capabilities with a real request.
- **Assert every role named in a revoke**, not just `anon`. Signups are open on this project,
  so `authenticated` is reachable by anyone holding the publishable key.
- **Name every consumer of a privilege before revoking it**, including jobs outside this repo.
  *The weekly backup at `~/n8n-docker/padel-backup.sh` uses the publishable key; it was
  checked and only reads, and prunes local files rather than rows.*

## Deployment
- **`index.html` at the repo root is what Netlify serves.** No build command, publish
  directory is the root. Any other filename gives a 404 at `/`.
- **One write path.** The site is Git-connected; a drag-and-drop deploy is reverted by the
  next push and vice versa.
- **Schema before client.** If a release writes a new column, the migration runs and is
  verified first, or every save fails.

## Copy
- **User-facing copy that promises something about data must be re-read whenever that code
  path changes.** *The Regenerate dialog kept promising "the new result replaces the old one"
  after replace was narrowed to matching line-ups, where it now duplicates.*
- **Never call anything in this app "admin only".** `isAdmin` is a browser variable, the PIN
  is readable in view-source, and RLS is permissive. It is a usability guard.
