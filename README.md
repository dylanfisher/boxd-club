# Boxd Club

A private movie picker for small groups. One app, any number of clubs.

A club reads its members' public Letterboxd watchlists, puts the films the most
of them already want to see on a ballot, and emails it out. Everyone drags the
films into order; a Borda count picks the winner **the moment the last person
votes** — rounds have no deadline. Then everyone watches it and logs it on
Letterboxd, and the next round opens once everyone has.

No accounts, no passwords, no public signup. Magic links are the entire auth
model, for members and for the admin area alike.

## Stack

Ruby 4.0 · Roda · Sequel · SQLite (WAL) · Puma · rufus-scheduler · Nokogiri.
One process, one container, no Redis, no worker, no build step.

## The shape of it

- **Clubs** own rounds. A member can be in several.
- **Where films come from** is per club (`list_mode`). The first three read the
  same pool — every member's watchlist — and differ only in how much overlap a
  film needs. The icon is what members see next to the mode on the club page.
  | Mode | Icon | What it does |
  |---|---|---|
  | `own` (default) | ◍ | Films at least two members share, most-shared first, backfilled with single picks so obscure entries still surface |
  | `cross` | ◎ | Only films on *every* watchlist — members without one sit it out. Empty intersection means no ballot |
  | `union` | ◌ | Anything on anyone's watchlist, drawn at random |
  | `list` | ▤ | One fixed Letterboxd list, minus anything a member has already watched |

  The same wording lives in `Club::MODE_NOTES`, so admin and the club page can't
  drift apart.
- **Nobody watches the same film twice.** The three watchlist modes get this
  free — a watchlist is by definition films you haven't seen. `list` mode
  doesn't, so it keeps its own record of what members have watched and drops any
  film one of them has (`lib/seen.rb`). Films nobody has been asked about count
  as unseen, so a club whose record is thin still gets a ballot.
- **Films don't repeat.** A film the club has settled on never comes back. A
  film that has merely *been on a ballot* is held back until every eligible film
  has had a turn — only when the pool runs dry do repeats return, longest-unseen
  first. Without that second rule a club sees the same five most-shared titles
  most weeks.
- **Rounds** go `open` → `decided` → `watched`, or `skipped`. Open until
  everyone votes; decided until everyone logs the winner on Letterboxd; then the
  next one opens by itself. The club page shows the date a round *opened*,
  because there is no date it's due.
- **Voting to skip** is the way out of a decided round nobody can finish — the
  film isn't streaming anywhere, or the club has gone off it. Half the members,
  rounded up and never fewer than two (2 of 2, 2 of 3, 2 of 4, 3 of 5), ends the
  round and opens the next — nobody skips a film for the club alone. The
  film still counts as spent, so it isn't offered again.
- **Rounds are numbered per club** — "round 5" — from `rounds.number`, assigned
  when the round opens and never reused. Every email about a round says which
  one it is, and `/club/:slug/round/:n` is a permalink to it: the winner, the
  final Borda order, and what else was on the ballot.
- **A club has one open round.** Every transition that ends a round and opens
  the next goes through `Rounds.claim!`, a conditional UPDATE that only one
  caller can win, and `open!` takes SQLite's writer lock before re-checking. Two
  skip votes landing together, or two admin buttons pressed at once, can't leave
  a club with two ballots out.
- **Every film reference** carries title, year, director and Letterboxd rating,
  with a poster where we have one. A decided round also shows the film's wide
  backdrop across the top of the page.
- **Members have faces.** A member's Letterboxd profile picture appears beside
  their name wherever they're listed. Letterboxd's own uploads are downloaded
  once and re-served from `/avatars/…` rather than hotlinked; Gravatars, which
  are a CDN built for it, are linked as they are. See `lib/avatars.rb`.
- **`/cache` says what we hold.** Every member can see our copy of Letterboxd —
  which watchlists we have, how many films, how old each read is, and when the
  scheduled jobs last ran — because "why is a film I removed still on the
  ballot?" is a question with an answer. It fetches nothing; a member sees the
  people they share a club with, an admin sees everyone (`lib/cache.rb`).
- **Dates** are written one way everywhere — `August 9, 2026`, from `Fmt.date`,
  with `Fmt.ago` beside it where staleness is the point. No template calls
  `strftime`.
- **Vertical rhythm** comes from one place: the `--space-*` scale in
  `views/layout.erb` and the `.section` rule that uses it. A page is a stack of
  `<section class="section">`, and adding one shouldn't mean writing a margin.
- **Admin** is at `/admin`: create clubs, set where their films come from,
  invite people, chase whoever hasn't voted, and force a stuck round along.

### URLs

```
/                         your clubs
/login                    email → magic link
/settings                 your Letterboxd username, and club email on or off
/cache                    what we hold from Letterboxd, and how old it is
/club/:slug               one club: mode, members, the open ballot, past rounds
/club/:slug/round/:n      one past round
/club/:slug/vote          POST — a ranked ballot
/club/:slug/skip          POST — one vote to skip a decided round's film
/avatars/:file            a member's profile picture, our copy
/admin, /admin/clubs/:slug
```

`/c/:slug` was the old club URL and still redirects — sign-in links live in
inboxes for 60 days and carry a `?to=` path.

## Local development

```bash
bundle install
bundle exec rake db:migrate
bundle exec rake seed_demo          # a demo club off four real public watchlists
bundle exec rake "dry_run[demo]"    # print the ballot, change nothing
bundle exec puma -p 9292
```

`seed_demo` reads four watchlists from the CSVs in `db/seeds/watchlists/`, so it
needs no network and finishes in under a second. The files are Letterboxd's own
export format, so you can drop a real `watchlist.csv` from
letterboxd.com/settings/data/ in beside them. To go to Letterboxd instead:
`rake "seed_demo[fetch]"` for one run, or `rake seed_fixtures` to re-scrape and
rewrite the checked-in files.

With `SMTP_HOST` unset, mail is logged to stdout rather than sent, and every
invite prints its magic link, so you can walk the whole flow locally.

### Being each member

`seed_demo` creates four members of the `demo` club and prints a sign-in link
for each. In development the tokens are fixed strings, so these are the actual
links — paste one into a private window and you are that person:

```
http://localhost:9292/auth/dev-demo?to=/club/demo     demo@example.com    admin
http://localhost:9292/auth/dev-alice?to=/club/demo    alice, schaffrillas
http://localhost:9292/auth/dev-bob?to=/club/demo      bob, sidneyprescott
http://localhost:9292/auth/dev-cara?to=/club/demo     cara, karsten
```

They survive re-seeds and restarts, and are valid for 60 days after the last
seed. Guessable tokens are the point here and also the reason
`Tokens.dev_login_url` raises unless `RACK_ENV=development`; everywhere else
tokens are 256 random bits. For any other account, or a fresh unguessable link:
`rake "link[bob@example.invalid,/club/demo]"`.

Nothing signs you in on its own — there is no development autologin — so a fresh
private window is always a logged-out stranger. One session cookie per browser,
so a private window per person is how you hold several at once.

**Only `demo@example.com` is an admin.** As the other three there's no Admin
link in the nav and `/admin` 403s, which is what an ordinary member sees. The
seed is authoritative, so re-running it undoes a stray
`rake admin[alice@example.invalid]`.

### Walking a round

```bash
bundle exec rake "dry_run[demo]"          # what the ballot would be; changes nothing
bundle exec rake advance                  # open the round (or use /admin/clubs/demo)
bundle exec rake "demo_vote[demo]"        # vote as everyone but you, so yours decides it
bundle exec rake "demo_vote[demo,all]"    # or vote it through and print the standings
bundle exec rake "demo_next[demo]"        # close the round and open the next
```

`demo_vote` leaves `demo@example.com` — the admin you browse as — one ballot
short, so submitting yours takes the real path: the tally, the winner on the
club page and the result emails all happen for real rather than being faked.
After submitting, that member's club page comes back read-only and a second
submission is refused.

`demo_next` is the admin page's **mark watched** button. A decided round normally
waits for every member to log the film on Letterboxd, which you can't fake for
accounts you don't own — so this is how you get back to a fresh ballot. Run it
with `demo_vote` in between and you can walk several rounds in a minute, which
is also how you watch previous winners drop off the ballot.

To work on a scratch copy instead of your dev data:

```bash
cp db/boxd.db /tmp/scratch.db
DATABASE_URL=sqlite:///tmp/scratch.db bundle exec puma -p 9292
```

### Looking at the emails

http://localhost:9292/dev/emails lists every email the app sends, each rendered
from fixtures — Rails' mailer previews, for this app. A preview shows both parts:
the HTML part in a frame of its own, so only the email's own styles act on it,
and the text part as it goes out (a real part of every message, not a fallback).
`/dev/emails/:name/html` and `/dev/emails/:name/text` are the bare parts.

In development, signed in as an admin, there's an **Email previews** link in the
header dropdown. Plain members don't see it, and neither does anyone under
another `RACK_ENV`, where the routes 404 and `lib/email_previews.rb` isn't even
loaded.

Nine previews, because several templates have a branch worth seeing:

| Preview | What it covers |
|---|---|
| `invite` / `invite-general` | An invite to a club, and one with no club yet |
| `login` / `login-club` | A sign-in link, and one aimed at a club page |
| `ballot` / `ballot-stale` | A new round, and one built on watchlists we couldn't refresh |
| `nudge` | The reminder to whoever still owes a ballot |
| `result` / `result-random` | A round decided by the votes, and one nobody voted in |

The fixtures are unsaved model objects (`lib/email_previews.rb`), so a preview
needs no club, no round and no member, renders the same on an empty database,
and can't send or write anything. The links inside are dead strings, not tokens.
One fixture film is deliberately missing a director and rating and another its
poster, so the previews show what a film the enricher hasn't reached does to the
layout. Previews follow `Mailer.unsubscribable?`, so the two that carry no
unsubscribe footer don't show one.

## Rake tasks

| Task | What it does |
|---|---|
| `db:migrate` / `db:status` | Schema |
| `db:release` | The deploy hook: snapshot, then migrate, if anything is pending |
| `clubs` | Every club and where its round is |
| `club["Name",mode,list_url]` | Create a club |
| `invite[email,club_slug]` | Invite someone (club optional) |
| `link[email,path]` | Print a sign-in link for an existing user — become them locally |
| `admin[email]` | Invite someone as an admin |
| `join[club_slug,email]` | Add an existing user to a club |
| `people` | Everyone, their watchlist freshness, their clubs |
| `fetch[username]` | Scrape one watchlist, print what it found |
| `refresh` | Re-scrape every member's watchlist and every club list, ignoring freshness |
| `advance` | Move every club along — open, tally, or check who's logged the winner |
| `dry_run[club_slug]` | Build a ballot and print it — no round, no email |
| `seen[club_slug,n]` | Check a list club's films against what its members have watched |
| `import_watched[email,path]` | Import somebody's `watched.csv` from a Letterboxd export (asks you to confirm it isn't `watchlist.csv`) |
| `enrich[n]` | Backfill director/rating/poster/backdrop for films missing them |
| `avatars` | Fetch everyone's Letterboxd profile picture now, ignoring freshness |
| `seed_demo` | A demo club on real public watchlists — offline; `seed_demo[fetch]` scrapes instead |
| `seed_fixtures` | Re-scrape the demo watchlists and rewrite `db/seeds/watchlists/*.csv` |
| `demo_vote[slug]` | Vote as everyone but you; `[slug,all]` votes it through |
| `demo_next[slug]` | Close the current round without waiting on Letterboxd logs |
| `test` | The suite |

## Tests

`rake test` — Minitest and rack-test, about a second for the lot.

The suite runs against a real SQLite file in a temp directory, built by the
same migrations a fresh deploy runs, and drives the real routes and the real
templates. Two things are switched out and nothing else: mail goes to
`Mail::TestMailer` instead of a transport, and `Net::HTTP.start` raises — a
test that forgets to stub a scrape fails loudly rather than quietly reaching
letterboxd.com. `Rounds.in_background` runs inline, so no thread outlives the
test that started it.

What's covered, roughly in order of what it would cost to get wrong:

- **`matcher_test.rb`** — which films reach a ballot: the four modes, and the
  two rules on top of them (a film the club settled on never returns; a film
  merely offered waits until the pool runs dry, then comes back oldest-first).
- **`rounds_test.rb`** — the lifecycle, `open` → `decided` → `watched | skipped`,
  including the skip thresholds, the nudge interval, and what happens when
  Letterboxd is unreachable mid-round.
- **`concurrency_test.rb`** — a club has one open round, and a round ends once,
  under real threads. Starting threads together isn't enough to make them
  collide, so each test holds them at a barrier just before the critical
  section and lets them go at once.
- **`votes_test.rb`** — the Borda count, and everything a hand-made POST can't
  do to a ballot.
- **`routes_test.rb`** — who may see what, CSRF, the open-redirect refusal, the
  avatar path, one-click unsubscribe.
- **`tokens_test.rb`, `throttle_test.rb`, `seen_test.rb`, `avatars_test.rb`,
  `clubs_test.rb`, `letterboxd_test.rb`, `mailer_test.rb`, `invites_test.rb`,
  `fmt_test.rb`** — one file per `lib/` file it defends.
- **`emails_test.rb`** — every template rendered from the `/dev/emails`
  fixtures, both parts, every link absolute.

## How the pieces fit

```
config/boot.rb      DB connect + PRAGMAs, mail config
config/schedule.rb  rufus cron, loaded only when ENABLE_SCHEDULER=1
app.rb              routes only
lib/models.rb       the Sequel models, and what "reachable" means
lib/letterboxd.rb   watchlists, lists, film pages, avatars, "have they logged it?"
lib/tmdb.rb         poster and backdrop URLs (optional API key)
lib/films.rb        director / rating / poster / backdrop, filled in lazily
lib/avatars.rb      members' profile pictures: downloaded, or Gravatar links
lib/cache.rb        what /cache reads back — nothing here fetches
lib/fmt.rb          the one date format, "3 days ago", thousands separators
lib/matcher.rb      candidate selection per club mode, and not repeating films
lib/seen.rb         what members have already watched, for list-mode clubs
lib/clubs.rb        club CRUD and membership
lib/invites.rb      invites and sign-in links
lib/rounds.rb       open! / advance! / tally! / check_logs! / claim!
lib/votes.rb        ranked ballots + Borda count
lib/tokens.rb       magic links (SHA256-hashed, raw value never stored)
lib/throttle.rb     sliding-window limits on the forms that can send mail
lib/mailer.rb       multipart text + HTML, and the only-known-recipients guard
lib/email_previews.rb  fixtures for /dev/emails (development only)
lib/quotes.rb       the film line under the sign-in form and the error pages
lib/backup.rb       nightly VACUUM INTO, 7-day rotation
```

### Schedule

Nothing here decides anything on a clock — it only keeps data fresh and gives
each club a regular chance to move itself along.

| When (local time) | Job |
|---|---|
| Daily 08:00 | `daily_fetch` — re-scrape watchlists, club lists, and what list-club members have watched |
| Every 4h | `advance` — open / tally / check who's logged the winner |
| Daily 03:30 | `cleanup` — prune expired tokens, back up the database |

A tally doesn't wait for `advance`: the last ballot submitted decides the round
in the request that submits it, and the result emails go out on a background
thread so nobody waits on SMTP.

Both scraping jobs run at the background pace (below), so "Daily 08:00" means
the first request goes out somewhere in the following 45 minutes and the last
can be an hour after that. Nothing downstream cares when they finish.

Every job is wrapped in a `guard` that logs and swallows exceptions — an
uncaught error in a rufus thread dies silently otherwise — and takes an atomic
claim against `job_runs` first, so redeploying doesn't re-fire it. `TZ` must be
set or "8am" becomes midnight Pacific inside a UTC container.

### When mail goes out

Five templates, and nothing else sends. Only `nudge` is on a timer; the rest go
out in the same breath as the thing that caused them.

| Email | Sent when | Cadence |
|---|---|---|
| `invite` | An admin invites someone (`/admin`, `rake invite`, `rake admin`) | Once per invite, immediately. The verify link lasts 14 days (`Tokens::VERIFY_TTL`) |
| `login` | Someone asks for a link at `/login` | One per request, immediately. Nothing is sent for an address we don't have — the page says the same thing either way |
| `ballot` | A round opens, to every voting member | Once per round |
| `nudge` | `advance` finds an open round with people who still owe a ballot | At most once every 6 days per round (`Rounds::NUDGE_DAYS`), indefinitely — a round has no deadline |
| `result` | A round is decided, to every voting member | Once per round |

What triggers a round to open — and so the ballots — is one of: the previous
round being logged by everyone, a skip vote carrying, an admin pressing "mark
watched", or `advance` finding a club with no round at all. Only the last waits
for the 4-hourly tick.

Nudge timing is measured from `nudged_at || opened_at` and is only *checked* by
`advance`, so the first reminder lands 6 days after the round opened plus up to
4 hours plus the job's random start offset. The admin page's nudge button
ignores the throttle entirely — pressing it twice sends twice.

Recipients come from `club.voting_members`, which is `reachable` (active,
verified, not unsubscribed), so unsubscribing takes you out of every automated
email at once. `Mailer.deliver` will only mail an address that belongs to a
saved user, so no form can make this server mail a stranger.

Two things switch the whole lot off: with `ENABLE_SCHEDULER` unset there is no
`advance`, so no nudges and no automatic round opening; with `SMTP_HOST` unset
mail is written to the log rather than sent.

### Unsubscribing, and the way back

Club mail — `invite`, `ballot`, `nudge`, `result` — carries a fresh single-use
unsubscribe link and RFC 8058 `List-Unsubscribe` headers, both of them or
neither. `login` doesn't, and is the only exception (`Mailer::TRANSACTIONAL`):
it's the one message someone requests seconds before it arrives, and Gmail puts
the unsubscribe button next to the sender name, where it's easy to hit instead
of the link you came for. An invite goes to an address that never asked us for
anything, so it keeps its way out — the alternative is the spam button, and that
report costs the sending domain.

Unsubscribing is reversible. It stops club mail; it doesn't close the account,
so `/login` still mails a sign-in link to someone who has unsubscribed —
otherwise the only door in is locked and the page, which deliberately says the
same thing either way, can't explain why. **Email** on `/settings` turns club
mail back on.

### How hard we hit Letterboxd

Two speeds, set by `Letterboxd::PACE`:

| Pace | Between requests | Used by |
|---|---|---|
| `interactive` | 0.35–0.6s | Username check at signup, list check, enriching a ballot, `rake` tasks |
| `background` | 4–15s | `daily_fetch`, `advance` |

On top of that, the background jobs:

- **wait a random 90–600s between one member and the next**, so a refresh is
  never a burst — it's one request in flight, trickling for an hour;
- **shuffle the order** of members and clubs, so it isn't the same person first
  every night and a run that dies halfway doesn't die on the same half twice;
- **start late by a random amount** (up to 45 min for `daily_fetch`, 12 for
  `advance`), so nothing lands at exactly 08:00:00 with every other cron.

What we deliberately *don't* fetch:

- watchlists of members who are only in list-mode clubs — nothing reads them;
- watchlists fetched less than `Letterboxd::REFRESH_AFTER` (3 days) ago, so most
  nights the job scrapes a handful of members rather than all of them. The
  ballot only calls data stale after 8 days (`Rounds::STALE_DAYS`);
- club lists refreshed inside the same window;
- full watchlists at signup — `check` reads page 1 only, to confirm the account
  is public and non-empty;
- film pages for anything that hasn't reached a ballot: a few thousand films sit
  on the watchlists and a handful reach a ballot, so details are filled in there
  and re-read after 90 days (`Films::REFRESH_AFTER`);
- anything at all for a member already recorded as having logged the winner;
- watch histories for members of watchlist-mode clubs — only `list` mode reads
  them — and per-film checks for a list club that already has enough film
  verified unseen to fill its next few ballots.

`LETTERBOXD_NO_DELAY=1` skips every deliberate sleep, for local dry runs.

Letterboxd being unreachable is never our bug and never a 500:
`Letterboxd::TRANSPORT_ERRORS` is the single list of ways a request can fail —
refused, hung, bad certificate, challenge page — and every call site rescues it
and carries on with what we already hold. `NotFound` and `RateLimited` descend
from it, so rescue those first where they mean something.

### Auth

Everything is a magic link. `/login` takes an email and mails a sign-in link to
it *if that address already exists* — it says the same thing either way, so the
form can't be used to find out who's a member. Ballot and result emails are
themselves sign-in links, landing on the club page.

`Mailer.deliver` is the single choke point, and it refuses to send unless the
recipient is a row that's actually in `users` *and* the address being mailed is
that row's own. Nothing this app sends can reach an address a stranger typed
into a form.

Login tokens last 60 days and are reusable, so last week's email still works.
Invite (`verify`) and unsubscribe tokens are single-use.

Admins are users with `admin` set. `ADMIN_EMAILS` promotes an address the first
time it signs in, so a fresh deploy has a way in.

### Voting

`POST` records, `GET` never does — email scanners (Outlook Safe Links, Gmail)
prefetch every URL in a message and would otherwise cast votes nobody intended.

Drag-to-reorder uses Pointer Events, not HTML5 drag-and-drop, which doesn't work
on mobile Safari or Chrome. Reordering is purely local — nothing reaches the
server until Submit ballot is pressed. With JS off, the number menus are the
form and the same button submits it.

**A ballot is final once submitted.** The last ballot in closes the round on the
spot, so a later edit could contradict a result that has already been decided
and mailed. `Votes.record_ranking!` refuses a second ballot from the same user,
and the club page shows a submitted ballot read-only. Changing a vote means an
admin forcing the round along from `/admin/clubs/:slug`. The server validates
that a ballot is exactly a 1..n permutation of *that round's* candidates, then
writes the whole set in one transaction.

### Knowing when someone has watched it

`letterboxd.com/{user}/film/{slug}/` returns 200 once they have a diary entry,
review or rating for the film, and 404 otherwise — a film merely sitting on
their watchlist 404s. That's the whole mechanism. One request per member who
hasn't been seen logging it yet, four times a day at most. Members without a
Letterboxd account still vote; they're just not waited on.

The admin page's **check** button does the same thing on a background thread,
because a Letterboxd that hangs rather than refuses is 45 seconds of timeout per
member. It says so, and the page is worth reloading a minute later.

### Knowing what they watched before they got here

Only `list` mode needs this: point a club at a Top 250 and the obvious ballot is
five films everybody saw years ago. The bar is that *nobody* has seen it — one
member's "yes" drops a film, since the point is watching something together for
the first time.

Letterboxd won't serve a watch history in bulk. `/{user}/films/` answers with
the 72 most recent, but every paginated form of it — `/page/2/`, `/by/date/`,
`/by/name/`, `/rated/…` — returns 403 with `cf-mitigated: challenge` (checked
2026-08-09), while watchlist and list pagination stay open. So three sources
feed `seen_checks`, in ascending order of how much they cost:

| Source | Cost | Covers |
|---|---|---|
| An uploaded `watched.csv` from [the export](https://letterboxd.com/user/exportdata/) | nothing | their whole history |
| `/{user}/films/`, in `daily_fetch` | 1 request per member per night | the 72 most recent |
| `/{user}/film/{slug}/`, in `Letterboxd.warm_seen!` | 1 request per member per film | whatever the budget reaches |

The last of those is capped at `Letterboxd::SEEN_BUDGET` (40) checks per club per
night, and skipped entirely once a club has `Seen::RESERVE` ballots' worth of
film verified — so it costs while a club is new and nothing once it has settled.
At roughly three films per twelve requests for a club of four, that's ten films
a night: the import is what makes a fresh list club filter properly on day one,
which is why `/settings` and the welcome page both ask for it.

A film nobody has been asked about counts as unseen. A cold club behaves exactly
as it did before any of this existed, and the filter tightens as the record
fills, rather than a new club going ballot-less on data we haven't collected.
When a list runs dry the ballot falls back to what the fewest members have seen,
so it never sends nothing.

Bulk imports skip films still on that member's own watchlist — `watched.csv` and
`watchlist.csv` have identical columns, so the wrong file would otherwise mark
everything they *want* to see as seen. (The upload rejects a file named
`watchlist.csv` outright, and says so if you hand it the zip.)

### Look

Letterboxd's own idiom: serif headings in white, a page that washes from light
grey down into `#14181c`, a solid dark header and a lighter footer, green
buttons with white text, body links white and underlined, film titles unlined
and blue on hover. Every hover rule is inside
`@media (hover: hover) and (pointer: fine)` so nothing sticks half-hovered after
a tap on a phone.

Every link that leaves the site carries `target="letterboxd"`, so they all share
one tab: click through five films and you get one Letterboxd tab that moves, not
five, with the ballot you were part-way through still open behind it.
Deliberately *without* `rel="noopener"`, which forces a fresh context and
ignores the target name. The trade is that letterboxd.com can see
`window.opener` — it can navigate our tab but not read it, and Letterboxd is the
one third party this app is built on.

The emails are [Lee Munroe's responsive email
template](https://github.com/leemunroe/responsive-html-email-template) in the
site's colours — a 600px card on a dark page, one green call-to-action, a grey
footer. `emails/layout.html.erb` is his skeleton and stylesheet with our palette
dropped in (`#14181c` page, `#1c2228` card, `#2c3440` border, `#d8e0e8` text,
`#8b9aa8` meta, `#00c030` button under `#06240e` lettering, `#40bcf4` links);
every `emails/*.html.erb` is only the body that goes inside it, and
`Mailer.button` is the one call-to-action so five templates don't each carry
Outlook's version of a rounded rectangle.

Colours are set twice — in the layout's `<style>` block and inline on the
elements that carry them. Gmail keeps embedded styles, but the clients that drop
them would otherwise leave pale text on a white background. The head keeps his
Outlook/iOS fixes and his one media query verbatim; `color-scheme: dark` asks
clients not to invert a design that's already dark. Nothing is inlined by a
build step: what's in the file is what goes out. The text parts are untouched by
any of this, and they're the ones that always render.

## Deploy

```bash
dokku apps:create boxd-club
dokku storage:ensure-directory boxd-club
dokku storage:mount boxd-club /var/lib/dokku/data/storage/boxd-club:/app/db
# Downloaded avatars live in db/avatars/ — on the volume, so a deploy doesn't
# wipe them. AVATAR_DIR moves them somewhere else if you'd rather.

dokku config:set boxd-club \
  DATABASE_URL=sqlite:///app/db/boxd.db \
  RACK_ENV=production \
  ENABLE_SCHEDULER=1 \
  TZ=America/Los_Angeles \
  BASE_URL=https://boxd.dylanfisher.com \
  ADMIN_EMAILS=hi@dylanfisher.com \
  SESSION_SECRET=$(openssl rand -hex 64) \
  SMTP_HOST=... SMTP_PORT=587 SMTP_USER=... SMTP_PASS=... \
  MAIL_FROM="Boxd Club <hello@boxd.dylanfisher.com>" \
  TMDB_API_KEY=...        # optional; without it, art comes from Letterboxd

dokku domains:add boxd-club boxd.dylanfisher.com
dokku letsencrypt:enable boxd-club
git remote add dokku dokku@YOUR_HOST:boxd-club
git push dokku main
```

**The storage mount is not optional.** Without it the SQLite file lives inside
the container and dies on every deploy.

Migrations run themselves. `app.json` sets a Dokku predeploy task —
`rake db:release` — which takes a snapshot to `db/backups/boxd-pre-migrate.db`
and applies anything pending, then the new container starts. No restart step,
and no forgetting.

Three things make that safe rather than the usual release-phase gamble:

- The predeploy container gets the app's deploy-phase storage mounts, so it
  migrates the real database on the volume — not a throwaway copy inside the
  image. (Dokku's `docker-args-deploy` trigger, which the storage plugin answers
  with the `-v`.)
- A failed task fails the *deploy*. The old container keeps serving old code
  against the old schema, and pushing a fixed migration is the whole recovery —
  nothing is wedged. SQLite has transactional DDL and Sequel wraps each
  migration in one, so a migration that raises leaves no half-applied schema.
- It's a no-op when `schema_info` is already current, so ordinary deploys don't
  churn the database or the backups.

It runs while the old container is still writing, so a migration on a large
table can meet `SQLITE_BUSY`; the 5s `busy_timeout` in `config/boot.rb` covers
the pauses that actually happen here. A *brand-new* empty database still
bootstraps itself on first boot, so a fresh volume doesn't crashloop.

`rake db:migrate` is still there for migrating by hand
(`dokku run boxd-club bundle exec rake db:migrate`), and `rake db:status` says
what's pending.

`/up` is the health check: it touches the database and returns plain text.
