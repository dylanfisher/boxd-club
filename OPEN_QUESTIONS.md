# Open questions

Things I decided on my own while you were away, and things I still need from
you. Ordered by what blocks the first real round.

Answers you'd already given are now built and don't appear here: rounds stay
open until everyone votes and show their opened date; a new round waits for
everyone with a Letterboxd account to log the film; there's an admin area at
`/admin` behind an emailed magic link, with clubs, list assignment and invites;
club pages list members by Letterboxd username; club access is all magic-link;
list mode is per club (own / cross / union / a specific list); the domain is
`boxd.dylanfisher.com` and the Dokku app is `boxd-club`; every film reference
carries title, year, director and Letterboxd rating; unsubscribe tokens stay
per-email; posters are hotlinked.

---

## Blocking — I can't do these for you

### 1. Who's in, and which clubs?

I need email addresses, and their Letterboxd watchlists must be public. Once you
have them:

```
rake admin[hi@dylanfisher.com]           # you, first
rake club["Thursday Night",own]          # or just do it in /admin
rake invite[someone@example.com,thursday-night]
```

They click the link, enter their own username, and they're in — so you only
strictly need the emails.

The database currently holds a **demo** club and a **pixar-night** club with
fake users (`alice@example.invalid` and friends) pointing at real public
watchlists, so `rake dry_run[demo]` has something to chew on. Delete them before
going live.

### 2. SMTP credentials

The app reads `SMTP_HOST`, `SMTP_PORT` (default 587), `SMTP_USER`, `SMTP_PASS`,
`MAIL_FROM`. With `SMTP_HOST` unset it logs emails to stdout instead of sending,
which is how local dev works — so nothing breaks until you set it.

Whatever you pick needs SPF and DKIM on the sending domain or the ballots land
in spam. Worth one test send to a Gmail address before the first real round.

`MAIL_FROM` also receives replies (there's no `Reply-To` and no inbound parsing),
so point it at something you read.

### 3. TMDB API key — do you want one?

You asked for TMDB posters. `TMDB_API_KEY` is unset, so right now posters come
from the Letterboxd film page instead (`a.ltrbxd.com`, which serves them without
a challenge — verified). Everything works; the crops are just Letterboxd's.

Set `TMDB_API_KEY` and every film enriched from then on gets
`image.tmdb.org/t/p/w342/...` instead. The TMDB id is already stored for every
film we've looked at, so `rake enrich` can backfill.

Untested until there's a key: the TMDB call itself.

### 4. Timezone

Assumed `TZ=America/Los_Angeles`. It matters much less than it used to — nothing
is decided on a clock — but the daily fetch, the 4-hourly `advance` and the
nightly backup key off it.

### 5. Nothing is committed

The repo is `git init`ed with **no commits**. I didn't want to author the first
commit for you. Dokku needs one (`git push dokku main`).

---

## Decisions I made without you

### I rewrote migration 001 rather than adding 002

Clubs, memberships, watch logs, film metadata and the loss of `rounds.closes_at`
touch nearly every table, and SQLite can't drop a NOT NULL constraint without
rebuilding the table anyway. Since nothing has ever been deployed, one coherent
schema beats a migration that patches a schema no database ever ran. **The local
dev database was deleted and rebuilt.** If anything *has* been deployed, tell me
and I'll write the incremental version instead.

### Vote tokens are gone; every emailed link is a sign-in link

There used to be a `vote` token that implied "the one open round". With clubs
that's ambiguous. Now every email links to `/auth/<token>?to=/c/<slug>`, which
signs you in and drops you on the club page, where the ballot is inline. One
mechanism instead of two, and it's what "club access is all magic email token
authentication" wants.

Login tokens are reusable for 60 days, so an old email still works. A mail
scanner prefetching the link only warms a cookie it can't use — voting is POST
with a CSRF token.

### The deciding vote sends result emails on a background thread

Whoever votes last would otherwise sit through five SMTP round-trips. The
decision itself is committed before the response, so the club page is right even
if the process dies mid-send; worst case someone misses a result email that the
club page still shows.

### Nudges every six days, forever

A round with no deadline can stall on one person. Non-voters get a reminder at
most every six days, indefinitely. Admin can force a tally from the club's
admin page. Say the word if you'd rather it gave up after N reminders.

### Films are enriched lazily

Director / rating / poster need a request to the film's own page. Members have
hundreds of watchlist films, so those are fetched only for the handful that
reach a ballot (plus `rake enrich` for anything else), and refreshed after 90
days.

### Someone who already watched the film counts as having logged it

`logged?` asks whether a member has *any* diary entry, review or rating for the
film — not whether it's dated after the round opened. In `own`/`cross` mode this
can't really happen (the film came off their watchlist). In `union` and `list`
mode it can: someone who saw it years ago is instantly "done" and the round
waits only on everyone else. I think that's right — they've seen it — but it's
a choice.

### One Letterboxd account per person

Signup rejects a username another user already has, since two members on one
account would count that watchlist twice.

### Unsubscribing doesn't remove you from the club

You stop being mailed, stop being counted for votes, and stop being waited on
for logging — but you can still open the club page, and signing in again doesn't
silently re-subscribe you. Getting back in is an admin re-invite.

### Kept from before

The `csv` gem stays declared (bundled gem in Ruby 3.4+, needed by the CSV
backend). Ruby is `~> 4.0` in the Gemfile and pinned exactly in the Dockerfile,
because your rbenv tops out below the pinned version. A totally empty database
bootstraps its schema on first boot; pending migrations still run by hand. CSRF
failure renders a 403 page, not a 500. The ballot keeps its number menus visible
with JS on, so it's keyboard-accessible.

---

## Things worth deciding later

### A club in `cross` mode can go quiet

If no film is on every member's watchlist, no round opens and the admin page
just shows "nothing open". I didn't add a fallback to near-misses, because
silently relaxing the rule is worse than saying nothing matched — but it does
mean a `cross` club can sit idle without an obvious cause.

### A round can wait forever on one person's diary

`decided` doesn't time out. If someone never logs the film, the club never
starts a new round until an admin hits "Mark watched, start next". An automatic
"after 30 days, move on" rule would be easy if you want it.

### The CSV backend is still untested and unwired

`Letterboxd.from_csv` expects `Date, Name, Year, Letterboxd URI`. Nothing calls
it — no upload route, no rake task. It's the escape hatch for when scraping
breaks. Specifically unverified: whether `Letterboxd URI` is a `/film/<slug>/`
path or a `boxd.it` short link (the short-link path falls back to a
title-derived slug that won't match a scraped row for the same film).

If you export from letterboxd.com/settings/data/ and drop `watchlist.csv`
somewhere I can read it, I'll verify and wire it up.

### No tests

Everything above was verified by hand (see README's "Verified"), but nothing is
guarded against regression. The matcher, the Borda tally and `logged?` are the
three places where a silent wrong answer would go unnoticed for weeks.

### Scraping is against Letterboxd's ToS

Unattended jobs wait 4–15s between requests and 90–600s between members, start
at a random offset from their cron time, and skip anything scraped in the last
three days — so a normal night is a handful of members trickling out over an
hour, one request in flight. Interactive paths (signup, ballot enrichment) stay
at ~0.35s because somebody is waiting. Log checks are one request per member
who hasn't watched it yet, at most every four hours. The practical risk is a
Cloudflare block rather than a lawyer — if `refresh_all!` starts logging
`rate-limited`, that's the signal.

### `logged?` depends on one page's behaviour

The whole "wait for everyone to watch it" mechanism rests on
`/{user}/film/{slug}/` 404ing until there's a diary entry. Verified on
2026-08-08 across several films and two states. If Letterboxd changes that, the
symptom is rounds that never advance (or advance instantly) — check that page by
hand first.
