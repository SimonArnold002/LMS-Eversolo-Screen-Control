# Changelog

All notable changes to Eversolo Screen Control are documented here.

Version numbering follows [Semantic Versioning](https://semver.org/):

    MAJOR.MINOR.PATCH

    PATCH  (1.0.x)  — Bug fixes, minor corrections, no new behaviour
    MINOR  (1.x.0)  — New features, new settings, backwards-compatible
    MAJOR  (x.0.0)  — Breaking changes (e.g. renamed prefs, restructured config)

---

## [1.0.1] — 2026-06-05

### Bug Fixes
- Fixed: Plugin stopped working when the Eversolo's IP address changed via
  DHCP. The IP was stored once on first use and never updated.

### Changes
- Added **Auto-detect Eversolo IP** option (on by default). When enabled,
  the plugin reads the player's live IP via `$client->ip()` at the moment
  each command is sent, so it automatically follows DHCP changes.
- The manual IP field is now only used when auto-detect is unticked
  (for setups where the Eversolo is on a different address from the player).
- Settings page now shows the current live player IP for reference.

---

## [1.0.0] — 2026-06-02

Initial release.

### Features
- Per-player plugin — appears in Player Settings menu (like DSD Player)
- Enable/disable independently for each LMS player
- Sends `Key.Screen.ON` to Eversolo HTTP API when playback starts
- Re-sends `Key.Screen.ON` on every song change (`playlist newsong`) to
  reset the Eversolo's own screensaver timer during continuous playback
- Sends `Key.Screen.OFF` after a configurable delay when playback pauses
  or stops (default 30 seconds)
- Safety check: if playback resumes before the off-timer fires, the
  timer is cancelled and the screen stays on
- Auto-populates the Eversolo IP address from the player's IP on first
  use (since Squeezelite on the Eversolo shares the same IP)
- All HTTP calls are non-blocking (`Slim::Networking::SimpleAsyncHTTP`)
- Configurable per player: IP address, port, screen-off delay
- Eversolo brandmark icon for plugin list and Material skin
