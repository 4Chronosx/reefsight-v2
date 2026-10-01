# Sub-plan 7 — Cloud sync (offline-first, multi-tenant, Cloudflare)

This adds a cloud copy of survey data **on top of** the on-device SQLite store. It doesn't replace it.
`ReefSight_Specification.md`'s "Storage" decision (on-device `sqflite`, one row per tracked colony)
stays as it is: the phone remains the system of record during and after a dive. The cloud is where the
diver pushes a finished survey once back on land with signal. Nothing in the live pipeline
(segmentation, classify, tracking, recording) changes.

Decided with the project owner on 2026-09-28:
- **Goals (all four):** backup of field data, remote report access, the same data on several phones or
  divers, and a growing central dataset (e.g. for later model retraining).
- **Multi-tenant**, with user accounts. Each tenant sees only its own data. **For now, one account per
  diver** (the diver is the tenant), with no organisations or team sharing.
- **Offline-first, manual sync.** The app works with no network at all. The diver taps **Sync** after
  the dive. There's no background or automatic upload.
- **Everything syncs**: session and colony records, mask files, and the transect video.
- **Backend: Cloudflare, free tier.**

## Cloudflare free-tier limits (checked against developers.cloudflare.com, 2026-09-28)

| Product | Free limit | Relevance |
|---|---|---|
| R2 storage | **10 GB-month** | **The binding constraint**, because of video (see below) |
| R2 Class A ops (writes, incl. `CreateMultipartUpload`/`UploadPart`) | 1 M/month | Not a concern: ~20-50 ops per GB of video |
| R2 Class B ops (reads) | 10 M/month | Not a concern |
| R2 egress | Free | Downloading reports and videos to other devices costs nothing |
| R2 object size | 5 GiB single PUT; up to ~5 TiB multipart; parts 5 MiB–5 GiB, all equal except the last, max 10,000 | Videos must use **multipart**, which is also what makes uploads resumable |
| R2 incomplete multipart | Auto-aborted after 7 days | A half-finished video upload must be resumed within 7 days or restarted |
| D1 | 10 DBs; 500 MB per DB; 5 GB per account; **100,000 rows written/day**; 5 M rows read/day | Plenty for session and colony rows. Queries fail for the rest of the day once exceeded |
| Workers requests | 100,000/day | Plenty |
| Workers CPU | **10 ms per invocation** | Rules out password hashing in the Worker, one reason login goes to Google/Apple (see decision A) |
| Workers request body | 100 MB | Each video part sent through the Worker must be under 100 MB |

### The video storage problem

The transect recording is a continuous phone video. A 50-100 m swim takes roughly 10-20 minutes. At
typical phone 1080p bitrates (~60 MB/min, **an assumption to measure, not a measured figure**), one
transect is about **0.6-1.2 GB**. **10 GB of free R2 holds only ~8-16 transects in total, across every
diver's account.** Masks and records are tiny next to that.

Mitigations, in order of preference:
1. **Measure first.** Check the real file size of one `TransectRecorder` output before designing around
   an estimate (step 0).
2. **Cap video uploads (decided 2026-09-28, decision G).** The Worker refuses a video upload that would
   take the account past the free tier, so the project never pays for R2 overage. Videos that don't fit
   stay on the phone. If this ever changes, R2 overage is cheap: $0.015/GB-month on the paid plan, or
   about $1.50/month for 100 GB. Raising the cap is a config change, not a redesign.
3. Optionally, compress on-device before upload (e.g. 720p re-encode). This costs battery and time on
   the phone, and changes the footage used as evidence, so it's opt-in, not the default.
4. Make video upload a **separate, per-survey action** from record and mask sync. That way the small,
   high-value data syncs immediately even when a large video can't go up yet (bad signal, quota).

The app shows **cloud storage used / quota** (step 5), so nobody hits the ceiling by
surprise.

## Architecture

```
Flutter app (offline-first)                     Cloudflare
┌──────────────────────────┐     HTTPS      ┌──────────────────────────────┐
│ SQLite (source of truth) │ ─────────────▶ │ Worker  (API, auth check,    │
│  + sync_state columns    │  Bearer JWT    │          owner scoping)      │
│ masks/  recordings/      │                │   ├─ D1: users,              │
│ SyncService (manual)     │ ◀───────────── │   │      sessions, colonies  │
└──────────────────────────┘                │   └─ R2: masks/, videos/     │
          │ sign-in                         └──────────────────────────────┘
          ▼                                              ▲ verify JWT (JWKS)
   Auth provider (see decision A) ───────────────────────┘
```

- **One Worker** (TypeScript) in a new top-level `cloud/` directory next to `mobile/`, deployed with
  Wrangler. D1 and R2 are bindings on that Worker.
- **The phone never holds R2 credentials.** Every upload and download goes through the Worker, which
  checks the user's token and survey ownership before touching D1 or R2.
- **Video upload goes through the Worker's R2 multipart binding** (`createMultipartUpload` /
  `uploadPart` / `resumeMultipartUpload` / `complete`), with parts of **~50 MB**. That's above R2's 5 MiB
  minimum and under the 100 MB request-body limit. Presigned URLs, which would skip the Worker, are the
  fallback if streaming parts through the Worker proves too slow or hits CPU limits. They support PUT,
  are generated server-side, and expire after at most 7 days. Decide in the step-0 spike, not up front.

## Decisions for this sub-plan

**A. Auth: OAuth / OpenID Connect sign-in with Google and Apple, verified by the Worker (decided
2026-09-28).** There are no passwords anywhere in the system, and no Firebase. Cloudflare has no login
product for app end users (Cloudflare Access protects internal apps for an organisation's own staff).
Password login built in the Worker would need password hashing inside the free plan's **10 ms CPU**
limit, plus hand-built email verification and password reset. Delegating identity to Google and Apple
avoids all of that.

- **App:** the `google_sign_in` and `sign_in_with_apple` Flutter packages run the provider's native
  sign-in and return an **ID token** (a signed JWT stating who the user is).
- **Worker (`POST /auth/session`):**
  1. Verifies the ID token's signature against the provider's public keys (JWKS: Google's and Apple's
     published signing-key lists, cached in the Worker). This is one RS256 verification via WebCrypto,
     cheap enough for the CPU limit.
  2. Checks `iss`, `aud` (this app's client IDs), and `exp`.
  3. Finds or creates the `users` row for `(provider, sub)`.
  4. Returns a **ReefSight session token**: an HMAC-SHA256-signed JWT (key held as a Worker secret)
     with a ~30-day expiry.
- **Every other endpoint** accepts only the ReefSight session token. Provider tokens are used once at
  sign-in, never stored server-side.
- **Offline-first still holds.** Sign-in is only needed at sync time. An expired session token just
  means signing in again before the next sync, and never blocks surveying.
- **Why Apple too:** the app ships on iPhone, and Apple's App Store rules generally require Sign in with
  Apple (or an equivalent privacy-focused option) when Google login is offered. Re-check the current
  guideline before submission.
- **Known limitation:** the same person signing in with Google on one phone and Apple on another gets
  two separate accounts. Account linking is out of scope. Divers should stick to one provider.
- **Setup needed (non-code):**
  - A Google Cloud OAuth client for iOS (and Android, if built).
  - A Sign in with Apple capability and Service ID on the Apple Developer account. This is blocked on
    the same account as device testing (`sub-plans/track1-handoff.md`, "Do these first" #2).

**B. Tenant = one diver's account (decided 2026-09-28, chosen for simplicity).** Every D1 row and R2
key is scoped by `owner_id`, the verified user's ID, which the Worker takes from the token, **never from
the request body**. A diver sees only their own surveys, on any phone they sign into.

What this means in practice:
- There are no organisations, invite codes, or join flow.
- Two divers on the same team **can't** see each other's surveys.
- "Multi-device" means one diver on several phones.

Organisation or team sharing can be added later without reshaping the data: introduce a `tenants`
table, move each diver's existing surveys into a one-person tenant, and switch the scoping column. Keep
every query's scoping in one Worker helper, so that later change touches one place.

**C. Surveys are immutable once uploaded, so there's no conflict resolution.** A session is only
created on one phone and never edited after `ended_at`. Sync is therefore **append-only upload plus
read-only download**, never two-way merging. Uploading the same session twice is a no-op (idempotent on
its UUID). This removes the hardest part of offline-first sync.

**The one exception: the exit GPS fix (sub-plan 12, decision 3).** The exit fix is recorded from Summary
after surfacing, so it can land after End Transect, and after this survey has already been uploaded.
It's the only field ever written to a session after `ended_at`, and it's write-once: the five `exit_*`
columns go from null to a value exactly once (`TransectDatabase.recordExitFix` guards with
`exit_lat IS NULL` in the same UPDATE) and are never changed after that. So sync needs exactly one
later update: if the uploaded copy has no exit fix and the local one does, send those five columns.
The Worker should accept that update only while its own `exit_lat` is null, which keeps it write-once
and idempotent. Every other column stays immutable once uploaded.

**D. There's no delete, locally or in the cloud.** This follows sub-plan 6's decision 8: surveys are
irreversible field data. The Worker exposes no delete endpoint. Only the account owner can clean up
by hand, via Wrangler or the dashboard.

**E. Globally unique IDs.** Local `transect_sessions.id` is `INTEGER AUTOINCREMENT`, so two phones
would both have a session 1. Add a **`uuid` column** (UUID v4, generated when the session is created)
and use it as the cloud identity. Colonies are keyed by `(session_uuid, track_id)`, which is already
unique per session.

**F. Incomplete sessions sync too**, flagged as incomplete. That's the same treatment as the Surveys
screen gives them in sub-plan 6. They're still real field data, and backup matters most exactly when a
dive went wrong.

**G. Video uploads are capped; records and masks never are (decided 2026-09-28).**

The Worker enforces two limits, both checked when a video upload **starts** (the app sends the file
size up front):
- **Account-wide ceiling:** `VIDEO_GLOBAL_CAP_BYTES`, default **9 GB**. That leaves ~1 GB of the 10 GB
  free tier for masks and overshoot.
- **Per-diver limit:** `VIDEO_PER_DIVER_CAP_BYTES`, default **2 GB**, roughly 2-3 transects at the
  estimated bitrate. It stops one diver from using everyone's space.

Both are Wrangler `vars`, so changing them is a config edit and redeploy, not a code change. Re-tune
the per-diver default once step 0 measures the real video size.

**How usage is counted:** the Worker reads bytes from **D1**, not from R2. R2 has no cheap
"bucket size" query from a Worker. Completed videos count their `video_bytes`. An in-progress upload
counts its **reserved** bytes, recorded when the upload starts. That way two uploads starting at once
can't both slip under the cap. A reservation is released on completion (replaced by the actual size)
or after 7 days, which matches R2 auto-aborting incomplete multipart uploads.

**Over the cap:** the start request returns **HTTP 413**, with a body saying which limit was hit.
The survey's records and masks are unaffected, since they synced first (step 4 ordering). The
video stays on the phone, marked **"Video not uploaded: cloud limit reached"**, for copying off by hand.
There's no automatic retry and no silent deletion.

## Steps

### 0. Spike (do this before building anything else)
- Record one real transect-length test clip with `TransectRecorder` and note its **size per minute**.
  Update the video-budget numbers above with the measured value.
- A throwaway Worker test: stream one ~50 MB part through a Worker into R2 multipart on the free plan.
  Confirm it works within the free-plan limits. If it doesn't, switch to presigned `UploadPart` URLs.
- Verify a real Google ID token inside a Worker (cached JWKS + RS256 verify via WebCrypto), then issue and
  verify an HMAC session token. Check how much CPU time both use against the 10 ms free-plan limit.
  Apple's token uses the same code path with a different key list, so it can wait until the Apple
  Developer account exists.

### 1. Local schema, migration v3 (`transect_database.dart`)
- `transect_sessions`: add `uuid TEXT` (backfill existing rows with fresh UUIDs in `_upgradeSchema`),
  `synced_at TEXT NULL`, and `video_sync_state TEXT`
  (`none | pending | uploading | done | failed | blocked_quota`).
- New `upload_parts` table for resumable video: `session_uuid`, `upload_id`, `part_number`, `etag`,
  `created_at`. It lets a sync interrupted by lost signal resume from the last finished part. If the
  upload is more than 7 days old, restart it.
- Follow the existing migration pattern (`_schemaVersion` bump, nullable `ADD COLUMN`) and the
  `transect_database_test.dart` style. Test the v2→v3 upgrade on a pre-populated DB.

### 2. Cloud backend (`cloud/`, TypeScript Worker)
- **D1 schema:** `users(id, provider, provider_sub, email, display_name, created_at)` with
  `UNIQUE(provider, provider_sub)`, `sessions(uuid, owner_id,
  started_at, ended_at, tape_length_m, site_name, observer_name, video_key, video_bytes,
  video_reserved_bytes, video_reserved_at, mask_bytes, uploaded_at)`,
  and `colonies(session_uuid, track_id, health_label, health_history_json, size_px, first_seen_at,
  last_seen_at, mask_key)`. `owner_id` is on every session query's `WHERE`, and colony and mask access
  goes through an owned session.
- **Endpoints**, all except `/auth/session` requiring a valid ReefSight session token, and all scoped to
  the caller's own surveys:
  - `POST /auth/session`: exchange a Google or Apple ID token for a session token (decision A). Creates
    the `users` row on first sign-in.
  - `GET /me`
  - `PUT /sessions/:uuid`: upsert the session plus all colony rows in one D1 batch. Idempotent. If the
    UUID already belongs to another user, return 409 instead of overwriting.
  - `PUT /sessions/:uuid/masks/:trackId`: one mask file into R2 at `u/{owner}/s/{uuid}/masks/`
  - `POST /sessions/:uuid/video` with `{ sizeBytes }`: checks both caps (decision G), reserves the
    bytes, starts the multipart upload, or returns 413. Then `PUT …/video/parts/:n` →
    `POST …/video/complete`, which records the actual `video_bytes` and clears the reservation. The
    completed size must not exceed the reserved size.
  - `GET /sessions` (the caller's surveys), `GET /sessions/:uuid` (records),
    `GET /sessions/:uuid/masks/:trackId`, `GET /sessions/:uuid/video` (streamed from R2)
  - `GET /usage`: this diver's video bytes against the per-diver cap, and the account-wide total against
    the global cap, for the quota display
- No delete endpoints (decision D).
- Tests with Vitest plus Miniflare/`@cloudflare/vitest-pool-workers`. The most important test: diver A's
  token can never read or write diver B's session, mask, or video, including by guessing a session UUID.
  Also test the caps:
  - A start that would exceed either cap returns 413.
  - Two concurrent starts can't jointly exceed a cap.
  - An expired reservation frees its space.

### 3. App: auth
- Add `google_sign_in` and `sign_in_with_apple` (decision A). **Settings → Cloud account** (sub-plan 6's
  Settings tab) shows two large buttons: "Continue with Google" and "Continue with Apple". There's no
  sign-up form, password field, or password reset, and no organisation step (decision B).
- Store the ReefSight session token in the platform keychain (`flutter_secure_storage`), not in
  SQLite or plain preferences.
- If sync returns 401 (the session expired), prompt the diver to sign in again, then resume that sync.
- **Using the app never requires an account.** A diver who never signs in can do everything offline
  exactly as today. Sign-in is only needed to sync.

### 4. App: `SyncService` (manual, per survey)
- `lib/services/sync_service.dart`, a plain class with its HTTP client and DB injected so it can be
  tested headlessly, like `transect_recorder.dart`.
- **Sync order for one survey:** (1) records via `PUT /sessions/:uuid` → set `synced_at`; (2) each mask
  file; (3) the video, multipart, resuming from `upload_parts`. Each stage is safe to retry, and a
  failure in the video stage never un-syncs the records. A 413 at video start sets `blocked_quota`,
  counts as a completed sync for records and masks, and isn't retried automatically (decision G).
- Runs only in response to a tap, only with connectivity, and preferably on Wi-Fi. Warn before using
  cellular for a video.
- **Never runs during a live transect.** `LiveTransectScreen` must not trigger any network I/O, which
  keeps it clear of the Spec's compute budget.

### 5. App: UI (builds on sub-plan 6's screens)
- **Surveys tab:** each card gets a sync badge (Local only / Synced / Video pending / Video not uploaded:
  cloud limit reached / Failed · tap to retry), plus a **Sync** action per survey and a **Sync all** button. The diver's own surveys that were
  synced from another phone appear too, marked "From cloud". Opening one downloads its records and masks into
  local SQLite, marked read-only, so its report works offline afterwards. Its video downloads only on
  explicit request.
- **Summary screen:** a sync status line and a Sync button for that survey.
- **Settings → Cloud account:** signed-in user, video storage used (the diver's own against the
  per-diver cap, and the account-wide total against the global cap, from `GET /usage`), and sign out.
- Before starting a video upload, if `GET /usage` already shows the video won't fit, say so and don't
  attempt it. The server's 413 remains the real enforcement.
- Show progress (bytes uploaded / total) for video, with large glove-friendly controls, following
  sub-plan 6 decision 4. Sync happens topside, but it's the same diver with wet hands.

### 6. Tests
- `SyncService` against a fake HTTP server:
  - records-then-masks-then-video ordering
  - retry after failure at each stage
  - resuming a video from its last completed part
  - re-syncing is a no-op
  - a 413 at video start leaves records and masks synced and the video in `blocked_quota`
  - no request is ever made while signed out
- Migration v2→v3 with existing data.
- Worker per-diver isolation tests (step 2).
- The existing test suites stay green.

## Out of scope (this sub-plan)
- **Organisations and team sharing.** Deferred by decision B; the migration path is described there.
- **Web dashboard for LGU users.** For now, "remote report access" means the diver opening their report
  in the app on any phone they're signed into. Sharing a report with someone else needs either the
  existing CSV export or this later web page. A read-only web report page (e.g. Workers static
  assets reading the same D1/R2) is the natural next step, planned separately once the API is stable.
- Automatic or background sync.
- Deleting surveys (decision D).
- Using the central dataset for retraining. The data lands in R2/D1 ready for it, but consent and
  ownership terms for pooling divers' data are a policy question for the project, not for this code.

## Schedule risk (please read)
The defense is on **2026-10-31, ~5 weeks away**. Sub-plan 6 (UI overhaul) isn't started, and this
sub-plan adds a backend, auth, a schema migration, resumable video upload, and new UI. That's roughly as
much work again. Recommended ordering if time runs short:
1. Sub-plan 6 first. The app needs a usable UI before it needs a cloud.
2. Then this sub-plan's **records + masks sync** (steps 0-5 minus video). That delivers backup,
   multi-device access, and the central dataset for the part of the data that fits the free tier
   anyway.
3. **Video upload last.** It's the largest piece, it's the one that exceeds the free tier, and footage
   can be copied off the phone by hand in the meantime.

## Done when
- A diver can use the whole app offline with no account. After signing in, tapping Sync uploads a
  survey's records, masks, and video to Cloudflare, and the upload survives lost signal by resuming.
- A second phone signed into the same account sees that survey in its Surveys tab and opens its report.
- A different diver's account can't see it, and the Worker tests prove it.
- Nothing can be deleted, and no network I/O happens during a live transect.
- Settings shows video storage used against both caps. A video over either cap is refused, and the
  survey's records and masks are unaffected. The account never exceeds the R2 free tier.

## Open questions
None remaining. Resolved 2026-09-28:
- Account per diver (decision B).
- OAuth with Google and Apple (decision A).
- Video capped (decision G).
- Recorded in `ReefSight_Specification.md`, Phase C "Cloud sync".
