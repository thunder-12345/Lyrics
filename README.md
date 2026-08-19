# Lyrics

CarPlay lyrics for a 2019 Honda CR-V, driven by whatever's actually playing —
works with any music app, including ones that don't publish now-playing
metadata (e.g. an unofficial/cracked client), because it identifies audio
by listening to it (ShazamKit) instead of reading an app's metadata or
talking to Spotify's API.

## How it works

1. **`LyricsBroadcastExtension`** — a Broadcast Upload Extension. You start it
   once via the system picker in the app; it then keeps running in the
   background regardless of which app you switch to, receiving the phone's
   system audio output (never the mic).
2. **ShazamKit** identifies the track on-device, free, no rate limit.
3. Match results cross into the main app via an **App Group** + a Darwin
   notification (the extension and app are separate processes).
4. **LRCLIB** (free, no key) supplies synced lyrics; **Lyrics.ovh** (free, no
   key) is a plain-text fallback when LRCLIB has nothing for a track.
5. The main app stays alive in the background via a silent looped audio
   buffer, and drives an **ActivityKit Live Activity** that iOS surfaces on
   the CarPlay Dashboard.

Full design rationale and the current risk/edge-case register live in
`/Users/jayant/.claude/plans/nifty-yawning-charm.md`.

## Current status

- Builds clean for iOS Simulator (`xcodegen generate` then `xcodebuild`) —
  all three targets compile, including ShazamKit/ActivityKit linking.
- Launches and runs on Simulator without crashing (confirms the SwiftUI UI,
  App Group reads, silent-audio keep-alive, and Darwin notification wiring
  are all sound).
- **Not yet validated**: ReplayKit app-audio capture, real ShazamKit
  matching, and CarPlay Live Activity surfacing — none of these function in
  Simulator and need your physical iPhone + the CR-V.

## Setup steps

1. Open `Lyrics.xcodeproj` in Xcode (already generated via XcodeGen from
   `project.yml` — if you ever hand-edit target/capability config, edit
   `project.yml` and rerun `xcodegen generate` rather than editing the
   `.xcodeproj` directly, or your changes will be overwritten next generate).
2. Copy `Lyrics/Secrets.xcconfig.example` to `Lyrics/Secrets.xcconfig`,
   fill in `GITHUB_TOKEN` and `NOW_PLAYING_GIST_ID`, and add that xcconfig to
   the Lyrics target build settings for local Debug/Release builds. Do not
   commit `Lyrics/Secrets.xcconfig`.
   - `GEMINI_API_KEY` is optional — only needed for the Translated display
     mode (see below). Get a free key at https://aistudio.google.com/apikey
     (no card required for the free tier) and set it the same way. Without
     it, Original and Transliterated modes still work fully; Translated
     just won't be selectable.
3. Export the same values before starting the Mac relay:
   `export GITHUB_TOKEN=...` and `export NOW_PLAYING_GIST_ID=...`.
4. In **Signing & Capabilities**, for **each** of the 3 targets (Lyrics,
   LyricsBroadcastExtension, LyricsWidget): set Team to your personal Apple
   ID. Confirm App Groups shows enabled on all three, not just the main app.
   If the `com.jayant.*` bundle ID prefix collides with something already
   registered, change `bundleIdPrefix` in `project.yml` and rerun
   `xcodegen generate`.
5. Connect your iPhone via USB, select it as the run destination, build and
   run. Simulators can't do ReplayKit broadcast capture or real audio, so
   real testing needs the device from here on.
6. **Phase A check**: play music in your third-party app, open Lyrics, tap
   the broadcast picker button, choose "LyricsBroadcastExtension," start,
   then switch back to your music app. Watch Console.app (Window → Devices
   and Simulators, or the standalone Console app with your iPhone selected)
   filtered to subsystem `com.jayant.lyrics.broadcast` — confirms whether
   audio is actually reaching the extension and whether ShazamKit gets a
   real match. This is the one thing that determines whether the whole
   approach works for your specific app.
7. Once Phase A checks out, either keep iterating via Xcode/USB, or
   Product → Archive and sideload the build through AltStore the same way
   your music app is installed, for day-to-day driving use.
8. Test the Live Activity on your iPhone's Lock Screen first (should appear
   automatically once a match + lyrics succeed), then connect to the CR-V
   via CarPlay and check whether it surfaces on the Dashboard — this is the
   single biggest open unknown in the whole design and can only be confirmed
   this way.

## Lyrics display modes

Three toggle-able display modes, side by side in the app UI:

- **Original** — exactly what LRCLIB/Lyrics.ovh returns, no transform.
- **Transliterated** — same words, phonetically romanized into Latin script
  via Apple's on-device ICU transliterator. Free, offline, instant — no
  `GEMINI_API_KEY` needed. Meaning is unchanged, only the script.
- **Translated** — actual English meaning via the Gemini API, batched one
  request per song (not per line) and cached to disk so replaying a song
  doesn't re-spend API quota. Requires `GEMINI_API_KEY`.

For a detected-English track, Transliterated/Translated are disabled
automatically (detected on-device via `NLLanguageRecognizer`, no network
call) since they'd be near no-ops.

## Rebuilding the project

```bash
cd /Users/jayant/Lyrics
xcodegen generate
```

Run this after any change to `project.yml`, or after adding/removing Swift
files (XcodeGen picks up whole folders, so new files in `Lyrics/`,
`LyricsBroadcastExtension/`, `LyricsWidget/`, or `Shared/` are included
automatically — no project.yml change needed for those).
