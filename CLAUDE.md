# Splits (working name) – Garmin data explorer for Mac

A native macOS app that shows your own Garmin Connect data (activities, sleep, HRV, Body Battery, stress, steps) using Garmin's **Connect Personal API**. Free and open source, distributed from GitHub (signed + notarized), not the App Store.

## Why it's built this way (Garmin's terms)
- Personal API Supplemental Terms §1: a key "may be used only by you in connection with applications, services, or tools that you develop or operate for your own use" and must not be shared with any third party. FAQ: "not intended for commercial applications serving multiple end users."
- So: each user runs Splits on their own Mac with their own key. The key lives in the login keychain (`Keychain.swift`) and is only ever sent to Garmin. There's no Splits server. Keep it free; don't add anything that sends data or keys elsewhere.
- "Garmin" must not be in the product name (trademark). "Works with Garmin Connect" in descriptions is fine.

## API (see github.com/garmin/connect-personal-api-python, the only readable endpoint list; the Swagger page is JS-rendered)
- Base `https://personal.connectapi.garmin.com`. `POST /personalapitoken-service/personal-api/personal-api-key/token` with `Authorization: ApiKey <key>` returns the bearer token **as plain text**; valid 24 h, no refresh token.
- Units are SI (metres, seconds, m/s). Activity types are stable keys (`running`, `indoor_cycling`, `virtual_ride`, `lap_swimming`, and padel is `paddelball`).
- `calendarDate` is **null** on days without data (sleep, HRV…): every DTO field is optional.
- No published rate limits and no rate headers: `GarminClient` sends one request at a time with a 0.35 s gap, retries 429 with backoff, renews the token once on 401.
- A full sync of ~2,000 activities and a year of daily data takes ~30 s.

## Code
- `Garmin/`: `GarminClient` (actor), `API.swift` (DTOs + endpoints), `Keychain`.
- `Store/`: SwiftData models `Activity` (unique `garminId`) and `Day` (unique `yyyy-MM-dd`), `Sync` (first run: all activities in pages of 100, wellness for 365 days in 28-day chunks newest first; later: from the newest stored item, re-reading the last 3 days).
- `Views/`: Today, Activities (Table + inspector), Trends (Swift Charts), Onboarding, Settings. Units follow the Garmin profile (`metric` / `statute_us`).
- Debug: `SPLITS_KEY=$(cat ~/GARMIN_API_KEY) build/Build/Products/Debug/Splits.app/Contents/MacOS/Splits --sync-test` runs a full sync into an in-memory store and prints counts. Never commit keys or real data.

## Build
`xcodegen` (brew install xcodegen), then `xcodebuild -project Splits.xcodeproj -scheme Splits -destination 'platform=macOS' -derivedDataPath build build`.

## Next
- Name. Desktop widgets (Body Battery, sleep, weekly distance). FIT files per activity (routes on a map, laps, charts). Personal records from FIT data. Year in review. Developer ID signing, notarization, Sparkle updates, GitHub releases.
