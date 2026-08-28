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

**Current version: 1.3.0**

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

Eversolo's firmware is a fork of Zidoo's, so it speaks the Zidoo control API.
**Check that API before guessing at an endpoint** — the reference is Zidoo's own
developer docs plus the open-source client `wizmo2/zidoo-player`. A guessed
`getDeviceInfo` path shipped in 1.2.0 and 404'd on every device.

- Protocol: HTTP GET, no auth (an optional `X-Auth-PSK` header exists; unused).
- Default port: **9529**. Root: `/ZidooControlCenter/`.
- **Send a key:** `RemoteControl/sendkey?key=<COMMAND>` → `{"status":200}`.
  Commands used: `Key.Screen.ON`, `Key.Screen.OFF`.
- **Identify a device:** `getModel` → `{"status":200,"model":"...",
  "net_mac":"...","wif_mac":"...","firmware":"...","androidversion":"...",
  "language":"...","ram":"...","flash":"..."}`. This is what the network scan
  probes; `status` 200 plus `model` is the signature.

### Address resolution (critical)

**The Eversolo's address is a property of the DEVICE, not of the player.** The
plugin is configured on whatever player feeds that Eversolo, and that player may
be a bridge sitting anywhere on the network — LMS → HQPlayer Bridge → HQPlayer →
Eversolo is a supported chain. The player's own IP is therefore irrelevant except
in the one case where the two happen to be the same box (a Squeezelite running on
the Eversolo itself).

`_resolveIP()` ladder, in order:

1. **`eversolo_ip` configured for this player — always wins.** Hardcode it and
   nothing else is consulted. This is the answer for any bridged player, and for
   a network with more than one Eversolo.
2. **A device found by the network scan.** Exactly one match is used outright, so
   a bridged player works with no configuration at all. More than one and the
   plugin refuses to guess — it warns and the settings page asks.
3. **The player's own IP**, only when `auto_detect_ip` is on and the address is
   real (`isPlaceholderIP()` rejects loopback, `0.0.0.0`, `::`, `::1`, empty).

Do not reorder these. An earlier build put the player's IP first, which silently
sent commands to whatever the bridge reported — the HQPlayer host, then the LMS
server itself once the bridge switched to `INADDR_LOOPBACK`.

Bridged/virtual players (HQPlayer Bridge, LMS-Groups, UPnP bridges) have no
SlimProto socket and report whatever placeholder their creator passed to the
`Slim::Player::Client` constructor. Never detect this by player `model` or by
`tcpsock` — bridges set `tcpsock(1)` precisely to look connected. Judge the
address.

Resolution stays lazy — resolved at send time, never cached at config time. That
was the v1.0.1 fix for a stored IP going stale after a DHCP lease change.

### Network scan (Discovery.pm)

Finds Eversolos by asking the same control API the plugin drives:
`GET http://<ip>:9529/ZidooControlCenter/getModel` → JSON with `"status":200`
and a model. A responder on that port IS the device, so there is no vendor
discovery protocol to speak and nothing to install. Matching is deliberately
loose (any JSON body that is not an explicit non-200) so a firmware that moves
a field does not go undiscovered; a non-JSON answer is somebody else's web
server and is rejected.

- Candidates are the /24 around each of the server's own IPv4 addresses
  (`Slim::Utils::IPDetect::IP`, `Slim::Utils::Network::hostAddr`), loopback
  excluded. A device on another subnet is out of reach — that is what the
  address field is for.
- Non-blocking throughout: `SimpleAsyncHTTP`, 2s timeout, **20 probes in flight**
  (`CONCURRENCY`). 253 of 254 probes fail — the error callback must stay silent,
  no logging and no retry, or a sweep floods the log.
- **Single-flight.** A second caller during a sweep is parked in `@WAITING` and
  answered from the first sweep's result; a settings-page reload must never put
  a second 254-probe pass on the wire.
- Runs `STARTUP_SCAN_DELAY` (20s) after init, then every `RESCAN_INTERVAL`
  (1h), and on demand from the settings page's Scan button. The rescan timer is
  keyed on `undef` — one scan for the whole server, not one per player.

### Reconcile pass (critical)

The event subscription alone is **not sufficient**, and this was a real bug: the
plugin could only turn a screen off in response to a stop it witnessed, so a
stop it never saw left the screen on with nothing able to correct it. Three ways
that happens: a stop across a server restart (`shutdownPlugin` kills the pending
off-timer and the event is gone), a stop a bridged player never announced, and
the screen state being lost with the process.

`_reconcile()` runs `STARTUP_RECONCILE_DELAY` (15s) after init and every
`RECONCILE_INTERVAL` (60s) after that. For each **enabled** player it compares
`Slim::Player::Source::playmode()` against `%screenState` and repairs only a
disagreement:

- playing, screen off or unknown → assert ON
- not playing, screen on or unknown → schedule the off-timer as a stop would
- not playing, screen known off → nothing (one hash lookup, no traffic)

A player **absent** from `%screenState` is UNKNOWN, not off — that is what makes
the pass assert the screen after a restart instead of assuming it is right.

`%offPending` exists because `Slim::Utils::Timers` has **no way to ask whether a
timer is pending** (`killTimers` only reports what it removed). Without it the
reconcile would stack a second off-timer on every pass. Set it in
`_onPauseOrStop`, clear it in `_turnScreenOff` and in `_onPlay`.

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
├── Discovery.pm         # Non-blocking subnet sweep for Eversolos on the control API
├── PlayerSettings.pm    # Per-player settings page (needsClient => 1)
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
