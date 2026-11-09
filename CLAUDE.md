# Splits (working name) – Garmin data explorer for Mac

A native macOS app that shows your own Garmin Connect data (activities, sleep, HRV, Body Battery, stress, steps) using Garmin's **Connect Personal API**. Free and open source, distributed from GitHub (signed + notarized), not the App Store.

## Why it's built this way (Garmin's terms)
- Personal API Supplemental Terms §1: a key "may be used only by you in connection with applications, services, or tools that you develop or operate for your own use" and must not be shared with any third party. FAQ: "not intended for commercial applications serving multiple end users."
- So: each user runs Splits on their own Mac with their own key. The key lives in the login keychain (`Keychain.swift`) and is only ever sent to Garmin. There's no Splits server. Keep it free; don't add anything that sends data or keys elsewhere.
- "Garmin" must not be in the product name (trademark). "Works with Garmin Connect" in descriptions is fine.

## API (see github.com/garmin/connect-personal-api-python, the only readable endpoint list; the Swagger page is JS-rendered)
- Base `https://personal.connectapi.garmin.com`. `POST /personalapitoken-service/personal-api/personal-api-key/token` with `Authorization: ApiKey <key>` returns the bearer token **as plain text**; valid 24 h, no refresh token.
- Units are SI (metres, seconds, m/s). Activity types are stable keys (`running`, `indoor_cycling`, `virtual_ride`, `lap_swimming`, and padel is `paddelball`).
- Intraday: heart rate via `/wellness-service/wellness/dailyHeartRate?date=` (every 2 min); Body Battery via the daily report with `chunks` (96 = every 6 min, 200 = every 3; without it ~6 points a day). **Not available** (404): intraday stress, calendar, scheduled workouts, races, training plans. `/activity-service/activity/{id}/workouts` does return the planned workout an activity was done against (the user didn't want a calendar built from those).
- Records (`Views/RecordsView.swift`, `Store/Records.swift`): best 1 km/5 km/10 km/half/marathon inside every outdoor run. `RecordFinder` downloads each run's FIT once with `Tracks.track(for:keep: false)` (not saved) and `RecordStore` keeps only the times in Application Support/Bests.json. Efforts faster than 6.7 m/s are GPS glitches and dropped. `SPLITS_KEY=… Splits --progress-test` prints form, streaks and 3 runs' bests.
- Aerobic form (Trends): each outdoor run ≥3 km scaled to one heart rate (the user's median, to 5 bpm): speed × (ref − rest) / (avgHR − rest), with distance + 6 × climb; the line is a 30-day median. Streaks (`Streaks`, on the Trends day grid) count days in a row and weeks with 3+, runs only by default.
- Explorer (`Views/ExplorerView.swift`, `Store/Countries.swift`): each outdoor activity's start point is matched to a country offline with Natural Earth's 1:50m borders (public domain, `Resources/countries.json`: ISO code, English name, continent, label point, outer rings as flat lon/lat). Points just outside a coarse border snap to the nearest one within ~25 km. The map joins countries in the order you crossed into them.
- **Time totals use `Activity.activeSeconds`**: moving time for distance sports, the whole session otherwise. Garmin's moving time for padel/strength/yoga is the few minutes the watch saw you travel (a 90-minute padel match shows ~5).
- Share card (`Views/ShareCard.swift`): 1080×1350, route drawn without a map (privacy). `--card-test < file.zip > card.png`.
- Daily briefing: `Coach.dailyFacts` + `ReportCard` on Today, written once a day after last night's sleep syncs, kept in UserDefaults. The recovery verdict and today's recommendation are decided in code; the on-device model only words them (it can't weigh numbers reliably).
- Menu bar (`Views/MenuBar.swift`): `LiveToday` fetches today's Body Battery, heart rate, daily summary (stress durations) and steps when the panel opens and every 15 min; nothing stored. Skipped under XCTest.
- `calendarDate` is **null** on days without data (sleep, HRV…): every DTO field is optional.
- No published rate limits and no rate headers: `GarminClient` sends one request at a time with a 0.35 s gap, retries 429 with backoff, renews the token once on 401.
- A full sync of ~2,000 activities and a year of daily data takes ~30 s.

## Code
- `Garmin/`: `GarminClient` (actor), `API.swift` (DTOs + endpoints), `Keychain`.
- `Store/`: SwiftData models `Activity` (unique `garminId`) and `Day` (unique `yyyy-MM-dd`), `Sync` (first run: all activities in pages of 100, wellness for 365 days in 28-day chunks newest first; later: from the newest stored item, re-reading the last 3 days).
- Activity files: `GET /download-service/files/activity/{id}` with **`Accept: */*`** (Garmin answers 406 to `application/octet-stream` alone) returns a ZIP with one FIT file. `Zip.swift` (central directory + Compression raw deflate) and `FIT.swift` (own decoder: record 20 and lap 19 messages, compressed timestamps, dev fields skipped) read it; a 1.1 MB file decodes in ~0.2 s. `Tracks` caches FIT files in Application Support/Activities and `TrackAnalysis` makes chart samples, splits and fastest stretches.
- `Views/`: Welcome (animated background, onboarding, first-sync counters), Today (cards + today's Body Battery curve fetched live), Activities (Table; double-click opens `ActivityPage`: header, map with route, HR/pace/elevation charts with a scrubber that moves a marker on the map, splits, fastest stretches, HR zones, training effect), Trends (highlights, 12-month calendar, year vs last year, weekly distance/zones/load, sport mix, sleep stages, HRV, resting HR, records), Settings. Units follow the Garmin profile (`metric` / `statute_us`).
- `Splits --fit-test < file.zip` (Debug) decodes a download from stdin and prints what's in it, with our splits next to the watch's laps.
- Activity page performance: the inline map is a still `MKMapSnapshotter` image with the route and cursor marker drawn on a Canvas using Web Mercator (`RouteSnapshot`; `Splits --map-test < file.zip > map.png` checks they line up). The live `Map` is only in the Explore sheet. Charts use ≤320 samples, each averaging its stretch (`TrackAnalysis`); no work in view bodies (queries go in `.task`).
- Splits and best efforts use **timer time**: the watch stops recording while paused, so gaps over 15 s between records don't count (`TrackAnalysis.pauseGap`). Wall-clock time put a 19-minute coffee stop into the splits; now they match the watch's laps within a second or two.
- Coach (`Store/Coach.swift`): "Coach's take" on the activity page from Apple's **on-device** `SystemLanguageModel` (FoundationModels, macOS 26+, weak-linked so the app still runs on 14). Never `PrivateCloudComputeLanguageModel`: data stays on the Mac. Facts sent: the activity, splits, zones, bests, the previous 10 sessions of the same sport and that morning's sleep/HRV/Body Battery. Written on request, saved in `Activity.coachNote`. `Splits --coach-test` writes one for the newest activity and prints it.
- Debug: `SPLITS_KEY=$(cat ~/GARMIN_API_KEY) build/Build/Products/Debug/Splits.app/Contents/MacOS/Splits --sync-test` runs a full sync into an in-memory store and prints counts. Never commit keys or real data.

## Build
`xcodegen` (brew install xcodegen), then `xcodebuild -project Splits.xcodeproj -scheme Splits -destination 'platform=macOS' -derivedDataPath build build`.

## Next
- Name. Desktop widgets (Body Battery, sleep, weekly distance). FIT files per activity (routes on a map, laps, charts). Personal records from FIT data. Year in review. Developer ID signing, notarization, Sparkle updates, GitHub releases.
