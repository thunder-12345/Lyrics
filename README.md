# Lyrics

Live synced lyrics on the CarPlay dashboard of a 2019 Honda CR-V, driven by
whatever is playing on the Mac. It works with any music app that publishes
macOS Now Playing info, including ones that don't expose an API (e.g. an
unofficial Spotify web client).

## How it works

iOS doesn't let an app read what another app is playing, but macOS does. So
the Mac reads Now Playing and hands it to the phone through a private GitHub
Gist.

```
Music app (Mac)
  -> macOS Now Playing (private MediaRemote API)
  -> mac-relay/update_nowplaying.sh   polls every 0.25s via nowplaying-cli
  -> private GitHub Gist              nowplaying.json, written on track change
  -> iPhone app                       polls the gist (1s, 0.25s in bursts)
       -> LRCLIB / Lyrics.ovh         synced lyrics, plain-text fallback
       -> Transliteration / Gemini    optional display modes
  -> ActivityKit Live Activity        updated ~4x/sec by LyricsSyncEngine
  -> CarPlay Dashboard                iOS surfaces the Live Activity itself
```

1. **Mac relay** (`mac-relay/update_nowplaying.sh`) reads title, artist,
   elapsed time, duration and playback rate with `nowplaying-cli`, and PATCHes
   a private gist only when the track changes. A pause has to last about 5
   seconds before it counts, so brief blips don't flash "Paused" on CarPlay.
   It runs as a long-lived loop under launchd (`KeepAlive`), because
   `StartInterval` firings get coalesced by macOS and made new songs feel slow.
2. **`NowPlayingGistClient`** polls the gist with an authenticated API request
   plus a cache-busting query parameter (GitHub caches unauthenticated and raw
   responses for a minute or more).
3. **`LyricsSyncEngine`** detects track changes, fetches lyrics, and picks the
   current line from the elapsed time, ticking every 0.25s.
4. **LRCLIB** (free, no key) supplies synced lyrics. **Lyrics.ovh** (free, no
   key) is a plain-text fallback when LRCLIB has nothing for a track.
5. **`SilentAudioKeepAlive`** loops a silent audio buffer under the `.playback`
   category with `.mixWithOthers`, so the app isn't suspended in the background
   and keeps updating the Live Activity. It handles interruptions and route
   changes (calls, CarPlay reconnecting, Bluetooth switching).
6. **`LiveActivityController`** owns the ActivityKit `Activity`, and the
   `LyricsWidget` extension renders it. iOS shows it on the CarPlay Dashboard
   on its own; the app never talks to CarPlay directly.

## Project layout

| Path | Purpose |
| --- | --- |
| `Lyrics/` | Main app: sync engine, API clients, Live Activity controller, UI |
| `LyricsWidget/` | Widget extension that renders the Live Activity |
| `Shared/` | Code shared by both targets (`TrackMatch`, activity attributes) |
| `LyricsTests/` | Unit tests |
| `mac-relay/` | Mac script and launchd plist example |
| `project.yml` | XcodeGen spec; the `.xcodeproj` is generated from it |

## Setup

### 1. GitHub gist and token

1. Create a **secret gist** containing a file named `nowplaying.json` (any
   placeholder content is fine, e.g. `{}`). Copy its ID from the URL.
2. Create a GitHub personal access token with the `gist` scope.

### 2. Secrets for the iOS app

Copy `Lyrics/Secrets.xcconfig.example` to `Lyrics/Secrets.xcconfig` and fill in
`GITHUB_TOKEN` and `NOW_PLAYING_GIST_ID`. Do not commit `Secrets.xcconfig`.

`GEMINI_API_KEY` is optional and only needed for the Translated display mode
(see below). Get a free key at https://aistudio.google.com/apikey (no card
required for the free tier). Without it, Original and Transliterated still work.

### 3. Mac relay

```bash
brew install nowplaying-cli

export GITHUB_TOKEN=...
export NOW_PLAYING_GIST_ID=...
bash mac-relay/update_nowplaying.sh
```

To run it at login, copy `mac-relay/com.jayant.lyrics.nowplaying.plist.example`
to `~/Library/LaunchAgents/com.jayant.lyrics.nowplaying.plist`, fill in the
token and gist ID, fix the script path if the repo lives elsewhere, then:

```bash
launchctl load ~/Library/LaunchAgents/com.jayant.lyrics.nowplaying.plist
```

The relay logs timing to `/tmp/lyrics_nowplaying_timing.log`.

### 4. Build and run the app

1. Open `Lyrics.xcodeproj` in Xcode. If you change target or capability
   config, edit `project.yml` and rerun `xcodegen generate` instead of editing
   the `.xcodeproj`, or your changes are overwritten.
2. In **Signing & Capabilities**, set your Team on the `Lyrics` and
   `LyricsWidget` targets. If the `com.jayant.*` bundle ID prefix collides with
   something already registered, change `bundleIdPrefix` in `project.yml` and
   regenerate.
3. Make sure Live Activities are enabled for the app in iOS Settings.
4. Run on a physical iPhone. Live Activities and background audio behave
   differently on Simulator, and CarPlay surfacing can only be confirmed on a
   real phone connected to the car.

## Lyrics display modes

Three toggle-able display modes in the app UI:

- **Original**: exactly what LRCLIB/Lyrics.ovh returns, no transform.
- **Transliterated**: same words, romanized into Latin script via Apple's
  on-device ICU transliterator. Free, offline, instant; no `GEMINI_API_KEY`
  needed. Meaning is unchanged, only the script.
- **Translated**: English meaning via the Gemini API, batched one request per
  song (not per line) and cached to disk so replaying a song doesn't spend more
  API quota. Requires `GEMINI_API_KEY`.

For a detected-English track, Transliterated and Translated are disabled
automatically (detected on-device with `NLLanguageRecognizer`, no network call)
since they would be near no-ops.

## Rebuilding the project

```bash
cd /Users/jayant/Lyrics
xcodegen generate
```

Run this after any change to `project.yml`, or after adding or removing Swift
files. XcodeGen picks up whole folders, so new files in `Lyrics/`,
`LyricsWidget/` or `Shared/` need no `project.yml` change.

## Running tests

`LyricsTests` covers everything that doesn't need a physical device or real
network access: LRCLIB response parsing and synced-line lookup, the
LRCLIB-to-Lyrics.ovh fallback, Gemini request/response handling, ICU
transliteration, `TrackMatch` position math, and the on-disk localization cache.
Network clients take an injected `URLSession`, stubbed in tests via
`URLProtocolStub`, so no live calls are made and no API quota is spent.

```bash
xcodebuild -project Lyrics.xcodeproj -scheme Lyrics \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

Or Cmd+U in Xcode. Because `@testable import Lyrics` needs the test bundle to
host inside the app, `ContentView` skips starting the real sync engine and
keep-alive when `XCTestConfigurationFilePath` is set. Otherwise every test run
would poll the real gist and spend Gemini quota.

CI (`.github/workflows/ci.yml`) builds and runs the tests on every push to
`main` and on pull requests, using the placeholder values from
`Secrets.xcconfig.example`.

## Known limitations

- The Mac has to be on, awake and running the relay for lyrics to update.
- The relay uses `nowplaying-cli`, which relies on a private macOS API that
  Apple could change.
- Latency is bounded by the gist round trip: the relay write plus the phone's
  next poll.
- Whether the Live Activity appears on the CarPlay Dashboard depends on iOS,
  not on this app.
