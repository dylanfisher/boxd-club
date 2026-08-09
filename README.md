# Boxd Club

A private movie picker for small groups. One app, any number of clubs.

A club reads its members' public Letterboxd watchlists, puts the films the most
of them already want to see on a ballot, and emails it out. Everyone drags the
films into order; a Borda count picks the winner **the moment the last person
votes** — rounds have no deadline. Then everyone watches it and logs it on
Letterboxd, and the next round opens once everyone has.

No accounts, no passwords, no public signup. Magic links are the entire auth
model, for members and for the admin area alike.

**Read [OPEN_QUESTIONS.md](OPEN_QUESTIONS.md) before deploying** — it lists what
still needs your input and the judgment calls made along the way.

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
  | `cross` | ◎ | Only films on *every* member's watchlist. Empty intersection means no ballot |
  | `union` | ◌ | Anything on anyone's watchlist, drawn at random |
  | `list` | ▤ | One fixed Letterboxd list |

  The same wording lives in `Club::MODE_NOTES`. Admin prints it under the mode
  picker; on the club page it's behind the marker next to the mode — the labels
  alone read like three ways of saying "our watchlists".
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
  rounded up (1 of 2, 2 of 3, 2 of 4), ends the round and opens the next. The
  film still counts as spent, so it isn't offered again.
- **Rounds are numbered per club** — "round 5" — from `rounds.number`, assigned
  when the round opens and never reused. Every email about a round says which
  one it is, the club page lists past rounds with their posters, and
  `/club/:slug/round/:n` is a permalink to one: the winner, the final Borda
  order, and what else was on the ballot.
- **Every film reference** carries title, year, director and Letterboxd rating,
  with a poster where we have one. A round that's been decided also shows the
  film's wide backdrop still across the top of the page.
- **Members have faces.** A member's Letterboxd profile picture appears beside
  their name wherever they're listed. Letterboxd's own uploads are downloaded
  once and re-served from `/avatars/…` rather than hotlinked; Gravatars, which
  are a CDN built for it, are linked as they are. See `lib/avatars.rb`.
- **Dates** are written one way everywhere — `August 9, 2026`, from `Fmt.date`.
  No template calls `strftime`.
- **Vertical rhythm** comes from one place: the `--space-*` scale in
  `views/layout.erb` and the `.section` rule that uses it. A page is a stack of
  `<section class="section">`, and adding one shouldn't mean writing a margin.
- **Admin** is at `/admin`: create clubs, set where their films come from,
  invite people, chase whoever hasn't voted, and force a stuck round along.

### URLs

```
/                         your clubs
/login                    email → magic link
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

`seed_demo` reads those four watchlists from the CSVs in
`db/seeds/watchlists/`, so it needs no network and finishes in under a second.
The files are Letterboxd's own export format, so you can drop a real
`watchlist.csv` from letterboxd.com/settings/data/ in beside them. To go to
Letterboxd instead: `rake "seed_demo[fetch]"` for one run, or
`rake seed_fixtures` to re-scrape and rewrite the checked-in files.

With `SMTP_HOST` unset, mail is logged to stdout rather than sent, and every
invite prints its magic link, so you can walk the whole flow locally.

`seed_demo` finishes by printing a sign-in link for each of the four accounts
it creates. Paste one into a private window and you are that person. Nothing
signs you in on its own — there is no development autologin — so a fresh window
is always a logged-out stranger, and you are only the admin while holding the
admin's link. They're real 60-day login tokens, the same thing the emails carry.

For a non-demo admin, or in any other environment: `rake admin[you@example.com]`,
then open the printed link.

### Testing a whole round as each member

`seed_demo` gives you four members of the `demo` club:

| Who | Letterboxd | Role |
|---|---|---|
| `demo@example.com` | deathproof | **admin** |
| `alice@example.invalid` | schaffrillas | plain member |
| `bob@example.invalid` | sidneyprescott | plain member |
| `cara@example.invalid` | karsten | plain member |

`seed_demo` prints all four sign-in links when it runs, and in development the
tokens are fixed strings, so these are the actual links — paste them straight
from here into a private window:

```
http://localhost:9292/auth/dev-demo?to=/club/demo     demo@example.com   admin
http://localhost:9292/auth/dev-alice?to=/club/demo    alice, schaffrillas
http://localhost:9292/auth/dev-bob?to=/club/demo      bob, sidneyprescott
http://localhost:9292/auth/dev-cara?to=/club/demo     cara, karsten
```

They keep working across re-seeds and restarts — `seed_demo` renews the same
four rather than minting new ones — and they're valid for 60 days after the last
seed. Drop the `?to=` to land on the home page instead.

Guessable tokens are the whole point here and also the reason
`Tokens.dev_login_url` raises unless `RACK_ENV=development`. Everywhere else,
tokens are 256 random bits. For any other account, or a fresh unguessable link
for these:

```bash
bundle exec rake "link[bob@example.invalid,/club/demo]"
```

**Only `demo@example.com` is an admin.** Signed in as the other three there is
no Admin link in the nav, and `/admin` and `/admin/clubs/:slug` both return 403
— what you see is what an ordinary member sees. The seed is authoritative about
this, so re-running `seed_demo` undoes a stray `rake admin[alice@example.invalid]`.

One session cookie per browser, so opening each member's link in the same window
just replaces the last one. A private window per person is the way to hold
several at once — and because nothing auto-signs-in, a private window that
hasn't been given a link shows the login page, not somebody's clubs.

A full round, start to finish:

```bash
bundle exec rake "dry_run[demo]"   # what the ballot would be; changes nothing
bundle exec rake advance           # actually open the round (or use /admin/clubs/demo)
```

Then, for each member in turn: open their `rake link` URL, drag the ballot into
order, and press **Submit ballot**. Watch for these as you go —

- After submitting, that member's club page comes back read-only: no drag list,
  no number menus, and a second submission is refused.
- The round stays `open` until the *last* member votes, then decides in that
  request — the club page shows the winner immediately and the result emails
  are printed to the Puma log (with `SMTP_HOST` unset nothing is actually sent).
- `rake clubs` shows where the round is; `/club/demo/round/:n` is the permalink
  to it afterwards.

### Skipping the other three

Ranking five films in three private windows to reach the interesting part gets
old. `demo_vote` casts a random ballot for every member who still owes one,
leaving `demo@example.com` — the admin you browse as — so the round sits one
ballot short:

```bash
bundle exec rake "demo_vote[demo]"        # opens a round if none is open
```

Then paste demo's link and submit yours. Yours is the deciding ballot, so the
tally, the winner on the club page and the result emails all happen on the real
path rather than being faked.

```bash
bundle exec rake "demo_vote[demo,all]"    # nobody left out: vote it through, print standings
bundle exec rake "demo_next[demo]"        # close the round and open the next one
```

`demo_next` is the admin page's **mark watched** button. A decided round
normally waits for every member to log the film on Letterboxd, which you can't
fake for accounts you don't own — so this is how you get back to a fresh open
ballot. Run it twice with `demo_vote` in between and you can walk several rounds
in a minute, which is also how you see previous winners dropping off the ballot.

To go back to being the admin, paste demo's link again (or mint one with
`rake link[demo@example.com]`). Signing out just signs you out; nothing puts
you back.

If you'd rather not touch your dev data, point the app at a scratch copy:

```bash
cp db/boxd.db /tmp/scratch.db
DATABASE_URL=sqlite:///tmp/scratch.db bundle exec puma -p 9292
```

### Looking at the emails

http://localhost:9292/dev/emails lists every email the app sends, each rendered
from fixtures — Rails' mailer previews, for this app. A preview shows both parts
of the message: the HTML part in a frame of its own, so only the email's own
styles act on it, and the text part as it goes out (it's a real part of every
message, not a fallback). `/dev/emails/:name/html` and `/dev/emails/:name/text`
are the bare parts, for looking at the source or pasting into a client.

In development, signed in as an admin, there's an **Email previews** link in the
header dropdown — the same menu as **Sign out** — so you can get there from
whatever page you're on. Plain members don't see it, and neither does anyone
under another `RACK_ENV`, where the link would only lead to a 404.

All nine names sit in one row, in the same place on the index and on every
preview (`views/email_preview_nav.erb`) — the one you're reading is marked
rather than dropped from the row — so clicking through them never moves the
link you want next.

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
and can't send or write anything — it renders the templates directly rather than
going through `Mailer.deliver`. The links inside are dead strings, not tokens.
One fixture film is deliberately left without a director or a rating and the
last poster is deliberately missing, so the previews show what a film the
enricher hasn't reached yet does to the layout; the posters that are there are
borrowed from whatever films your local database has.

The routes are development only: `/dev/emails` is a 404 under any other
`RACK_ENV`, and `lib/email_previews.rb` isn't even loaded.

## Rake tasks

| Task | What it does |
|---|---|
| `db:migrate` / `db:status` | Schema |
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
| `enrich[n]` | Backfill director/rating/poster/backdrop for films missing them |
| `avatars` | Fetch everyone's Letterboxd profile picture now, ignoring freshness |
| `seed_demo` | A demo club on real public watchlists, for local tuning — offline; `seed_demo[fetch]` scrapes instead |
| `seed_fixtures` | Re-scrape the demo watchlists and rewrite `db/seeds/watchlists/*.csv` |
| `demo_vote[slug]` | Vote as everyone but you, so the round is one ballot from a result; `[slug,all]` votes it through |
| `demo_next[slug]` | Close the current round without waiting on Letterboxd logs, opening the next |

## How the pieces fit

```
config/boot.rb      DB connect + PRAGMAs, mail config
config/schedule.rb  rufus cron, loaded only when ENABLE_SCHEDULER=1
app.rb              routes only
lib/letterboxd.rb   watchlists, lists, film pages, avatars, "have they logged it?"
lib/tmdb.rb         poster and backdrop URLs (optional API key)
lib/films.rb        director / rating / poster / backdrop, filled in lazily
lib/avatars.rb      members' profile pictures: downloaded, or Gravatar links
lib/fmt.rb          the one date format
lib/matcher.rb      candidate selection per club mode, and not repeating films
lib/clubs.rb        club CRUD and membership
lib/invites.rb      invites and sign-in links
lib/rounds.rb       open! / advance! / tally! / check_logs!
lib/votes.rb        ranked ballots + Borda count
lib/tokens.rb       magic links (SHA256-hashed, raw value never stored)
lib/mailer.rb       multipart text + HTML, and the only-known-recipients guard
lib/taglines.rb     the rotating line on the sign-in page
lib/lost_quotes.rb  the rotating line on a 404
lib/backup.rb       nightly VACUUM INTO, 7-day rotation
```

### Schedule

Nothing here decides anything on a clock — it only keeps data fresh and gives
each club a regular chance to move itself along.

| When (local time) | Job |
|---|---|
| Daily 08:00 | `daily_fetch` — re-scrape watchlists and club lists |
| Every 4h | `advance` — open / tally / check who's logged the winner |
| Daily 03:30 | `cleanup` — prune expired tokens, back up the database |

A tally doesn't wait for `advance`: the last ballot submitted decides the round
in the request that submits it, and the result emails go out on a background
thread so nobody waits on SMTP.

Both scraping jobs run at the background pace (see below), so "Daily 08:00"
means the first request goes out somewhere in the following 45 minutes and the
last one can be an hour after that. Nothing downstream cares when they finish.

### When mail goes out

Five templates, and nothing else sends. Only one of them — `nudge` — is on a
timer; the rest are sent in the same breath as the thing that caused them.

| Email | Sent when | Cadence |
|---|---|---|
| `invite` | An admin invites someone (`/admin`, `rake invite`, `rake admin`) | Once per invite, immediately. The verify link lasts 14 days (`Tokens::VERIFY_TTL`) |
| `login` | Someone asks for a link at `/login` | One per request, immediately. Nothing is sent for an unknown or unsubscribed address — the page says the same thing either way |
| `ballot` | A round opens, to every voting member | Once per round |
| `nudge` | `advance` finds an open round with people who still owe a ballot | At most once every 6 days per round (`Rounds::NUDGE_DAYS`), indefinitely — a round has no deadline |
| `result` | A round is decided, to every voting member | Once per round |

What actually triggers a round to open — and so the ballots — is one of: the
previous round being logged by everyone, a skip vote carrying, an admin
pressing "mark watched", or `advance` finding a club with no round at all. Only
the last of those waits for the 4-hourly tick.

`result` is sent from the request that submits the deciding ballot, on a
background thread, so the last voter doesn't sit through the SMTP round-trips.
An admin forcing a tally sends it inline instead.

Nudge timing is measured from `nudged_at || opened_at` and is only *checked* by
`advance`, so the first reminder lands 6 days after the round opened plus up to
4 hours plus the job's random start offset. The admin page's nudge button
ignores the throttle entirely — pressing it twice sends twice.

Recipients always come from `club.voting_members`, which is `reachable`
(active, verified, not unsubscribed), so unsubscribing takes you out of every
automated email at once. `Mailer.deliver` will only mail an address that
belongs to a saved user, so no form can make this server mail a stranger. Every
message carries a fresh single-use unsubscribe link and RFC 8058
`List-Unsubscribe` headers.

Two things switch the whole lot off: with `ENABLE_SCHEDULER` unset there is no
`advance`, so no nudges and no automatic round opening; with `SMTP_HOST` unset
mail is written to the log rather than sent, which is how local development and
`rake dry_run` work.

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
- film pages for anything that hasn't reached a ballot (see "Films are enriched
  lazily" in OPEN_QUESTIONS.md);
- anything at all for a member already recorded as having logged the winner.

`LETTERBOXD_NO_DELAY=1` skips every deliberate sleep, for local dry runs.

Every job is wrapped in a `guard` that logs and swallows exceptions — an
uncaught error in a rufus thread dies silently otherwise. Every job takes an
atomic claim against `job_runs` first, so redeploying doesn't re-fire it.

`TZ` must be set or "8am" becomes midnight Pacific inside a UTC container.

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
spot, so a later edit could contradict a result that has already been decided and
mailed out. `Votes.record_ranking!` refuses a second ballot from the same user,
and the club page shows a submitted ballot read-only. Changing a vote means an
admin forcing the round along from `/admin/clubs/:slug`.

The server validates that a submitted ballot is exactly a 1..n permutation of
*that round's* candidates, then writes the whole set in one transaction.

### Knowing when someone has watched it

`letterboxd.com/{user}/film/{slug}/` returns 200 once they have a diary entry,
review or rating for the film, and 404 otherwise — a film merely sitting on
their watchlist 404s. That's the whole mechanism. One request per member who
hasn't been seen logging it yet, four times a day at most.

Members without a Letterboxd account still vote; they're just not waited on.

### Nudges

`advance` mails whoever still owes a ballot, at most once every six days
(`Rounds::NUDGE_DAYS`). The admin page has a button that does the same thing
immediately and ignores the throttle — pressing it twice really does send twice.
See "When mail goes out" above for how that sits alongside the other four
emails.

### Look

Letterboxd's own idiom: serif headings in white, a page that washes from light
grey down into `#14181c`, a solid dark header and a lighter footer, green
buttons with white text, body links white and underlined, film titles unlined
and blue on hover. Every hover rule is inside
`@media (hover: hover) and (pointer: fine)` so nothing sticks half-hovered after
a tap on a phone.

Every link that leaves the site — film titles, member profiles, a club's source
list, the footer — carries `target="letterboxd"`, so they all share one tab.
Click through five films and you get one Letterboxd tab that moves, not five,
and the ballot you were part-way through is still open behind it. Deliberately
*without* `rel="noopener"`: noopener forces a fresh context and ignores the
target name, so it would defeat the shared tab entirely. The trade is that
letterboxd.com can see `window.opener` — it can navigate our tab but not read
it, and Letterboxd is the one third party this app is built on.

The emails are [Lee Munroe's responsive email
template](https://github.com/leemunroe/responsive-html-email-template) in the
site's colours — a 600px card on a dark page, one green call-to-action, a grey
footer with the unsubscribe link. `emails/layout.html.erb` is his skeleton and
stylesheet with our palette dropped in (`#14181c` page, `#1c2228` card,
`#2c3440` border, `#d8e0e8` text, `#8b9aa8` meta, `#00c030` button on `#06240e`
lettering, `#40bcf4` links); every `emails/*.html.erb` is only the body that
goes inside it, and `Mailer.button` is the one call-to-action so five templates
don't each carry Outlook's version of a rounded rectangle.

Colours are set twice — in the layout's `<style>` block and inline on the
elements that carry them. Gmail keeps embedded styles, but the clients that drop
them would otherwise leave pale text on a white background. The head keeps his
Outlook/iOS fixes and his one media query verbatim; `color-scheme: dark` asks
clients not to invert a design that's already dark. Nothing here is inlined by a
build step: what's in the file is what goes out.

The text parts are untouched by any of this, and they're the ones that always
render. `/dev/emails` is where you look at both.

## Deploy

```bash
git add -A && git commit -m "initial"

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

Migrations run by hand — `dokku run boxd-club bundle exec rake db:migrate` — so
a bad migration can't wedge future deploys. A *brand-new* empty database
bootstraps itself on first boot, so the first deploy doesn't crashloop.

## Verified

Checked by hand on 2026-08-08 against real Letterboxd data:

- Scrape: 183 films across 8 pages in ~3s; a 30-film public list; film pages for
  director, Letterboxd rating, TMDB id and poster
- `logged?` — true for a film in a member's diary, false for one on their
  watchlist, across four different slugs
- Full lifecycle: open → two of three ballots → nothing decided → last ballot →
  decided with the right Borda standings → logs checked → marked watched → next
  round opened, with the previous winner excluded from it
- All four club modes produce the ballots you'd expect (`cross` correctly finds
  the one film all three shared, and correctly finds nothing once it has won)
- Web: sign-in link → club page → ballot → submit; a second ballot from the same
  user is refused and changes nothing; duplicate ranks rejected with nothing
  persisted; expired CSRF renders 403
- Permissions: anonymous redirects to /login, non-member gets 403, non-admin
  gets 403 on /admin, unknown club 404s
- Invite → verify → username validation (nonexistent account, private
  watchlist, duplicate account) → signed in; the verify token then refuses reuse
- Admin: create a list-mode club from a real Letterboxd list URL, invite a
  member, open a round off that list
- Nudges fire once and don't repeat inside six days

Checked on 2026-08-08 against a throwaway database, driving the real Rack app:

- `/club/:slug` serves; `/c/:slug` 301s to it; `/club/:slug/round/1` renders and
  an unknown round number 404s
- Submitting a ballot persists all five ranks and redirects; the page comes back
  read-only ("this is final", no form, no menus) and a second POST is refused
  with the first ballot intact; the round still closes on the last ballot and
  the winner is the Borda leader
- The nudge button reports 0 when everyone has voted and mails everyone
  outstanding otherwise, twice in a row, with no throttle
- `Mailer.deliver` refuses an unsaved user and refuses an address that isn't the
  given user's; `/login` with an unknown address still sends nothing
- Round numbering survives a full round: round 1 watched → round 2 opened, and
  the club page links back to round 1
- Testing as each member (against a copy of the dev database): `rake link` signs
  in as alice, bob and cara; each one's club page carries no admin link at all
  and both `/admin` and `/admin/clubs/demo` 403 for them, while the demo admin
  still gets 200 on both; each votes once, the form goes read-only, and the
  fourth and last ballot flips the round to `decided` with a winner
- The 404 page shows a different film line per load and no longer repeats the
  wordmark; the 403, expired-link, unsubscribed and CSRF pages all still render
  with their message as the heading
- The four `dev-*` links in this README each sign in as the right person, still
  work after a re-seed, and `dev_login_url` refuses to run with
  `RACK_ENV=production`
- No autologin: a browser with no cookie gets the login page at `/` and is
  redirected away from `/admin` and `/club/demo`; pasting each seeded link makes
  you exactly that person (demo → admin links and `/admin` 200; alice, bob and
  cara → no admin links and `/admin` 403); signing out returns the login page
  and stays there
- Outbound links share one tab: clicking a film, then a member, then another
  film in a real browser leaves two tabs open in total, the second re-navigating
  each time, with the club page untouched behind it; internal links stay put

- Email previews: all nine render both parts (`/dev/emails`, each preview page,
  and both bare parts, 200 each); an unknown name and `/dev/emails/:name/xml`
  404; the whole tree 404s under `RACK_ENV=production`; every HTML part comes
  out wrapped in the layout — doctype first byte, the subject in the `<title>`
  and the preheader, the card, the green button, the footer's unsubscribe link
- A real `Mailer.deliver` (with the test transport) still builds both parts, and
  the HTML one is the same layout the preview shows
- The **Email previews** link is in the header dropdown on every page for the
  demo admin, absent for alice/bob/cara, absent logged out, and absent under
  `RACK_ENV=production`

Not yet verified: the restyled pages in an actual browser (no browser available
in this session — the markup and CSS were not eyeballed, and neither were the
email preview pages, whose responses were only checked over HTTP), drag-to-reorder on a
real phone, the CSV backend against a real export, a full round over real SMTP,
and TMDB posters (no API key yet).
