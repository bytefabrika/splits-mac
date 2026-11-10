# Splits

Your Garmin data, on your Mac. Activities, sleep, HRV, Body Battery and more, in a fast native app.

Splits uses Garmin's Connect Personal API with **your own** Personal API key. The key is kept in your Mac's keychain and only ever sent to Garmin; everything Splits downloads stays on your Mac. There's no account and no server.

## Get started
1. In Garmin Connect on the web, open **Settings → Personal API Key**, create a key and copy it.
2. Open Splits and paste the key.

## Build from source
```
brew install xcodegen
xcodegen
open Splits.xcodeproj
```

## Data
- Country borders: [Natural Earth](https://www.naturalearthdata.com), public domain.
- Cities: [GeoNames](https://www.geonames.org), licensed under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). Bundled in `Splits/Resources/cities.json` (towns of 15,000 people or more; name, country, position, population, province, capital).

Both are bundled, so finding where an activity was never leaves your Mac.

Not affiliated with Garmin. Garmin and Garmin Connect are trademarks of Garmin Ltd.
