# Splits

Your watch's data, on your Mac. Activities, sleep, HRV, energy and more, in a fast native app. Works with Garmin Connect.

Splits uses the Garmin Connect Personal API with **your own** Personal API key, for your own personal use. The key is kept in your Mac's keychain and only sent to that API; everything Splits downloads stays on your Mac. There's no account, no server and no tracking.

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

## Legal
Splits is an independent app. It is not made, sponsored, endorsed or approved by Garmin Ltd. or its subsidiaries. Garmin and Garmin Connect are trademarks of Garmin Ltd. or its subsidiaries, named only to say which service Splits works with.

Splits is not a medical device and its numbers and AI-written notes are not medical advice. It is provided as is, without warranty, under the [MIT License](LICENSE). Full notices: [LEGAL.md](LEGAL.md).
