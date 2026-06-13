# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Project

**EversoloScreenControl** is a per-player plugin for **Lyrion Music Server (LMS)**
that controls the display on an **Eversolo DMP-A8** (or DMP-A6) streaming DAC
via the device's built-in HTTP control API.

- Turns the Eversolo screen **ON** when playback starts.
- Re-asserts **ON** at every track change to reset the device's own screensaver counter.
- Turns the screen **OFF** after a configurable delay when playback pauses or stops.

The plugin is **per-player**, not global. It appears in the **Player Settings**
menu (alongside DSD Player, etc.) and is enabled/disabled independently for each
LMS player. Players not attached to an Eversolo simply leave it off and are unaffected.

**Current version: 1.0.1**

## How it works

- Subscribes to LMS playback events through `Slim::Control::Request::subscribe`.
- `play` / `playlist newsong` → send `Key.Screen.ON`.
  - ON is re-sent on **every** `playlist newsong` (track change) rather than on a
    polling timer. This is deliberate: it resets the Eversolo's internal
    screensaver countdown at each new song during continuous playback.
- `pause` / `stop` → start an off-timer; when it fires, send `Key.Screen.OFF`.
  - If playback resumes before the timer fires, the timer is cancelled and the
    screen stays on.
- All HTTP calls are **non-blocking** via `Slim::Networking::SimpleAsyncHTTP`.
  Never use a blocking HTTP call — it will stall the LMS event loop.

### Eversolo HTTP API

- Protocol: HTTP GET, no auth.
- Default port: **9529**.
- Endpoint: `http://<IP>:9529/ZidooControlCenter/RemoteControl/sendkey?key=<COMMAND>`
- Commands used: `Key.Screen.ON`, `Key.Screen.OFF`.
  (This is the Zidoo remote-control API that Eversolo's firmware exposes.)

### IP resolution

The Eversolo runs the Squeezelite player, so the player's IP **is** the Eversolo's IP.

- `auto_detect_ip` (per-player pref, **default on**): the live IP is resolved at
  command-send time via `$client->ip()` inside the `_resolveIP()` helper. This
  follows DHCP changes automatically — do not cache the IP at config time.
- When `auto_detect_ip` is off, the manually entered `ip` pref is used instead
  (for the rare case where the Eversolo is on a different address from the player).

This live-resolution behaviour was the fix for the v1.0.1 bug, where a stored IP
went stale after a DHCP lease change. **Keep IP resolution lazy.** Don't reintroduce
a cached-at-startup IP.

## Per-player architecture (critical)

Everything is keyed per player so multiple Eversolo devices coexist cleanly:

- **Preferences:** always `$prefs->client($client)` — stored against the player's
  MAC address. Never use global `$prefs->get()` for per-player config.
- **Screen state:** the `%screenState` hash is keyed by `$client->id()` (MAC).
- **Timers:** every `setTimer` / `killTimers` uses the player object / id as key,
  so one player's off-timer is independent of another's.
- **Settings module:** `needsClient` must return `1` so the page renders under
  Player Settings rather than as a global settings page.

When adding any new state or preference, follow the same per-player keying. A bare
global would break multi-device setups.

## Repository layout

```
EversoloScreenControl/
├── Plugin.pm            # Core logic: event subscriptions, ON/OFF, _resolveIP(), timers
├── Settings.pm          # Per-player settings page (needsClient => 1)
├── install.xml          # LMS plugin metadata + <version> (creator: CrystalGipsy)
├── strings.txt          # Localised UI strings (PLUGIN_EVERSOLO_*)
├── CHANGELOG.md         # Semantic-versioned history
├── README.md            # Install + usage docs
└── HTML/EN/plugins/EversoloScreenControl/
    ├── settings/        # Settings page template(s)
    └── html/images/     # icon.png + sized/themed variants (64/128/256, light/dark)
```

## Versioning (Semantic Versioning)

`MAJOR.MINOR.PATCH`

- **PATCH (1.0.x)** — bug fixes, no behaviour change.
- **MINOR (1.x.0)** — new features / settings, backwards-compatible.
- **MAJOR (x.0.0)** — breaking changes (e.g. renamed prefs that lose existing config).

When bumping the version, update **all three** in the same change:
1. `<version>` in `install.xml` (this is what LMS compares to offer updates).
2. `PLUGIN_VERSION` constant in `Plugin.pm` (logged at startup).
3. A new dated section at the top of `CHANGELOG.md`.

## Packaging

The deliverable is a zip of the plugin folder:

```
cd /path/to/parent
zip -r EversoloScreenControl.zip EversoloScreenControl/
```

Icons are generated from the Eversolo "e" brandmark SVG → PNG at 64/128/256 px
in light (black) and dark (white) variants. The Material skin picks them up from
the `html/images/` path automatically.

## Conventions & gotchas

- Perl, targeting LMS **8.0+** (`maxVersion` 9.*).
- Logging via `Slim::Utils::Log`; guard with `main::INFOLOG && $log->is_info` etc.
- All UI text lives in `strings.txt` under `PLUGIN_EVERSOLO_*` keys — don't
  hard-code user-facing strings in the modules.
- Never block the event loop: HTTP is always `SimpleAsyncHTTP`.
- Don't cache the device IP — resolve it live (see IP resolution above).
- `creator` field in `install.xml` is `CrystalGipsy`.
