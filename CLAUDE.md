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

**Current version: 2.2.0**

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
- **What is it doing:** `ZidooMusicControl/v2/getState` → `{"status":200,
  "state":N,...}` with N = 0 idle, 3 playing, 4 paused. Same field Eversolo's
  own app and the Home Assistant integration (hchris1/Eversolo) read.
- **Identify a device:** `getModel` → `{"status":200,"model":"...",
  "net_mac":"...","wif_mac":"...","firmware":"...","androidversion":"...",
  "language":"...","ram":"...","flash":"..."}`. This is what the network scan
  probes; `status` 200 plus `model` is the signature.

**Power (implemented in 2.1.0, verified working on a DMP-A8):** Eversolo's
firmware adds a power group on top of Zidoo's — `ZidooMusicControl/v2/getPowerOption`
lists the actions as `{tag,name}` pairs, `setPowerOption?tag=poweroff|reboot|screen`
performs one. There is **no power-on endpoint and cannot be**: the device is off
and nothing is listening. Eversolo's own app sends a Wake-on-LAN magic packet to
`net_mac`, and so does this plugin. Reference: the Home Assistant integration
`hchris1/Eversolo`, which drives this same API.

Off and on are therefore **asymmetric, and that asymmetry drives the design**:

- **Off** is HTTP to a known address — the same call the Eversolo app makes.
- **On** is a UDP magic packet to `<subnet>.255` and `255.255.255.255`, ports 9
  and 7, sent through a non-blocking `IO::Socket::INET` with `SO_BROADCAST`. No
  module to install (see the no-extra-installs rule).

Two constraints fall out of that and both are user-visible:

- **WoL is wired-only.** Eversolo document that it does not work over Wi-Fi, and
  the server must share the device's subnet. Over Wi-Fi the device powers down
  and does not come back.
- **`net_mac` can only be read while the device is ON**, and by the time it needs
  waking it is too late to ask. So `PlayerSettings::_lookup` stores `eversolo_mac`
  whenever it identifies a device, and the settings page says so when the MAC is
  still unknown — otherwise "power on does nothing" has no visible cause.

**Wake-on-LAN is DELIBERATELY UNDOCUMENTED (2026-09-11).** The code still sends
the packet and `t_power.pl` still pins it byte for byte — nothing was removed. But
the public `README.md` describes power control as **one-way, off only**, and does
not mention WoL, the wired-only constraint or the MAC at all. Reason: once the
Eversolo is off its LMS player disappears, so there is **no button left in LMS to
press** — the wake path has no route in from the UI, and documenting it only sets
up a feature the user cannot reach. Do NOT report the README as missing the WoL
section, and do not "restore" it; if a route in ever exists (a standalone wake
action, a settings-page button), that is what makes it documentable again.

Power is opt-in per player (`power_control`, default off) because ticking it
hands a device's mains state to a player button.

**Synced players (2.2.0).** LMS applies `syncPower` to a sync group's buddies by
calling their power methods directly, so a buddy never raises a power Request of
its own and a subscriber only ever hears from the player the user pressed. The
power callback therefore mirrors LMS's own target set — the pressed player, plus
each `syncedWith` buddy whose server-side `syncPower` is on — and re-reads the
plugin preferences of each one. Every player still decides for itself: a buddy
with `enabled` or `power_control` off is skipped, and a buddy with its own
Eversolo powers that device down rather than the pressed player's.

### Address resolution

**The stored address, and nothing else.** `_resolveIP()` reads `eversolo_ip` for
the player and returns it. That is the whole ladder.

It used to be four rungs, and one of them could fall back to the **player's own
IP address**, on the theory that a Squeezelite might be running on the Eversolo
itself. That was wrong in the case that actually matters: a player fed through a
bridge reports whatever placeholder its creator passed to the constructor —
HQPlayer Bridge reports `127.0.0.1` — so commands went to the LMS server rather
than to any Eversolo. The Eversolo's address is a property of the DEVICE, and a
player's own address is never evidence of it, so it is not consulted at all.

Discovery does not resolve anything at send time either. When the settings page
sees exactly one Eversolo on the network and nothing stored, it **writes that
address to the pref** — so what the page shows and what the plugin sends to are
the same single value, and there is no second "automatic" state that can drift
out of step with the stored one. Two devices and nothing stored: the user picks,
and nothing is sent until they do.

Deleted with the ladder: `auto_detect_ip`, `isPlaceholderIP()`,
`eversolo_last_ip`, and the bridged-player messaging on the settings page.
(`eversolo_mac` went too, then came back in 2.1.0 for Wake-on-LAN — it is now
learned from the device rather than guessed from the player.) A
bridged player needs no special handling now — it was only ever special because
the plugin was looking at the player's address.

### There is no device discovery, and there must not be

The Eversolo's address is typed into the player's settings page. That is the
whole of it. Two attempts at finding devices automatically were removed on
2026-08-30, in one day:

1. **A /24 sweep** — 254 HTTP probes per subnet. It **took the server off the
   network**: probing addresses where nothing exists makes the kernel ARP for
   every one, and a few hundred unresolved neighbour entries wedges the box.
   LMS became unreachable and had to be restarted with the plugin removed.
   Lowering the concurrency does not make this safe — the ARP flood is the
   problem, not the socket count.
2. **An SSDP M-SEARCH.** Safe, and it worked (the device answers with
   `friendlyName: DMP-A8(ManCave)` in under 3s). Removed anyway, because it was
   machinery for a problem the user does not have: they know the address, and
   typing it once is less work than any of it.

`tools/t_discovery.pl` and `tools/t_settings.pl` both fail if an address range,
a multicast, or a `scan` sub reappears in either module. Do not reintroduce
discovery; if it is ever asked for, SSDP is the mechanism — never a sweep.

Worth recording, because it wasted a day: the sweep never worked even before it
broke things. `_candidates()` derived the /24 from `Slim::Utils::IPDetect::IP()`
— and `Slim::Utils::Network::hostAddr()` is not a second opinion, it is
literally `return Slim::Utils::IPDetect::IP();`. That answers **127.0.0.1** on a
containerised server. Loopback is skipped, so the candidate list came back empty
and the sweep returned without probing anything. Never trust the server's idea
of its own address.

### What the device tells us (Discovery.pm)

The module is now three calls against a **known** address, all non-blocking:

- `identify($ip, $port, $cb)` → `GET /ZidooControlCenter/getModel`, parsed into a
  record. The settings page uses it to put a name beside the address.
- `describe($rec)` → `DMP-A8 (ManCave)`.
- `deviceState($ip, $port, $cb)` → `play`/`pause`/`stop`/undef, used by the
  reconcile pass.

A real DMP-A8 on firmware v1.5.75 answers (captured live, embedded verbatim in
`tools/t_discovery.pl`):

```json
{"status":200,"model":"DMP-A8","disModel":"DMP-A8","deviceName":"ManCave",
 "ip":"192.168.1.197","net_mac":"80:0a:80:5e:2b:7b","firmware":"v1.5.75",
 "ableRemoteBoot":true,"ableRemoteShutdown":true,"ableRemoteSleep":false, ...}
```

**`deviceName`** is the name set on the device itself — every unit answers
`"model":"DMP-A8"`, so the model alone identifies nothing. `net_mac` and
`ableRemoteBoot` are parsed too, for the Wake-on-LAN work noted above.

The name lookup is asynchronous, so it cannot fill in the page that triggered
it: the name is **stored in `eversolo_name`** and shows from the next view on.
It is asked once per address, not once per page load, and the stored name is
cleared the moment the address changes — a name must never sit beside another
device's address.

### The settings page (critical)

**It must not call into `Plugin.pm`.** 1.5.0 did — `isPlaceholderIP()` and
`_resolveIP()` — without ever `use`-ing that module, relying on LMS having
loaded it. When that call failed, `handler` died half way through and **LMS
still rendered the page with whatever had been filled in by then**: radios
unchecked, no devices, no address, and nothing saved (the save happens in
`SUPER::handler`, which is the last statement in the handler and never ran). It
looked like a settings bug. It was a dead handler. The page now depends on
`Discovery` and its own prefs, and nothing else.

**There is no device picker.** The address is a plain text field. The radio
group that used to sit here (`eversolo_choice`, one row per discovered device
plus a `__manual__` row, arbitrated by a `_picker` sub) went with the discovery
code on 2026-08-30 and is not coming back — with nothing to discover there is
nothing to pick from. The page's five fields are `pref_eversolo_ip`,
`pref_eversolo_port`, `pref_screen_off_delay` and the two checkboxes
`pref_enabled` and `pref_power_control`; every one is range-checked in `handler`
and falls back to its default rather than storing a value the plugin would have
to defend against later (port to 9529, delay to 30).

Above them the page shows what the device said about itself — the name from
`eversolo_name` and, when power control is on, whether `eversolo_mac` is known
yet. Both are read-only, and both are cleared the instant the address changes: a
name or a Wake-on-LAN MAC must never sit beside a different device's address.

Two more things the page has to get right:

- **Checkbox arrays.** A checkbox with a hidden `0` partner posts BOTH values
  when ticked, and LMS hands that over as an arrayref. Stored raw it becomes
  `['0','1']`, which is truthy for ever after — a toggle that can never be
  turned off. `_checkbox()` collapses it on save and repairs a pref already in
  that state on read. (Simon's server had exactly this, from 1.5.0.)
- **Save before render.** The chosen address is written to prefs inside
  `handler`, before the picker is drawn, rather than left to `SUPER::handler` at
  the end — otherwise the page redraws the state it had before the save. The
  same applies to an auto-adopted address: it must also be written back into
  `$params->{pref_eversolo_ip}`, or `SUPER::handler` overwrites the adoption
  with the empty value that triggered it.

Form fields are named `pref_<name>`: `Slim::Web::Settings::handler` saves
`$params->{'pref_' . $pref}`, and logs an ERROR per field per save if handed a
bare name. The checkboxes are `<label>`-wrapped because Material Skin does not
draw a bare one at all.

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

### Two-way state, and when the device is asked (critical)

LMS's player state is **not** authoritative. A player fed through a bridge can
be stranded in `play` with a frozen song clock when the far end stops talking —
observed live: `mode=play, elapsed=100` unchanged over minutes while nothing was
playing, because the HQPlayer Bridge's status subscription had gone silent. The
screen followed LMS and stayed on. No amount of event handling fixes that,
because the state being reacted to is itself wrong.

So the reconcile also consults the device — but **only when it can change the
answer**, because polling a device once a minute for ever is exactly what this
plugin must not do:

- LMS says playing and the clock is **moving** → trust it, no call.
- LMS says not playing → assert off, no call.
- LMS says playing and the clock is **frozen between two passes** → LMS is
  stale. Ask `/ZidooMusicControl/v2/getState` once and believe the answer:
  `state` 3 playing, 4 paused, 0 idle.

That is at most one HTTP call per stuck player per interval, and none at all in
normal operation. `%lastElapsed` holds the sampled position that drives it.

A device that does not answer returns **undef, meaning "no opinion"** — never
"stopped". A missed reply must not blank a screen mid-track.

In the stale case the command is sent regardless of `%screenState`: the belief
about the screen is precisely what has just been shown to be unreliable.

**An answer must not outlive the question that asked it (2.2.0).** The device is
asked over non-blocking HTTP, so the world can move on before the reply lands: a
`pause` observed a moment ago must not blank a screen that a later `play` has
since turned on, and a reply addressed to an old device address, a disabled
player or an unloaded plugin must not act at all. Two counters bound that.
`%playbackRevision` is bumped per player on every playback notification, and
`$lifecycleRevision` on every init and shutdown; both are captured when the
question is sent and re-checked in the callback, alongside the player's current
address, port, `enabled` preference and live play mode. Anything that changed
mid-flight discards the answer rather than acting on it. `PlayerSettings::_lookup`
carries the same guard, and there it matters more: a late `getModel` reply could
otherwise attach one device's Wake-on-LAN MAC to a different device's address.

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
├── Discovery.pm         # Asks ONE known address who it is (getModel/getState); no scanning
├── PlayerSettings.pm    # Per-player settings page (needsClient => 1)
├── install.xml          # LMS plugin metadata + <version> (creator: CrystalGipsy)
├── strings.txt          # Localised UI strings (PLUGIN_EVERSOLO_*)
├── CHANGELOG.md         # Semantic-versioned history
└── HTML/EN/plugins/EversoloScreenControl/
    ├── settings/        # Settings page template(s)
    └── html/images/     # icon.png + sized/themed variants (64/128/256, light/dark)

README.md                # Install + usage docs — at the ROOT, like every other repo here,
                         # and NOT part of the zip. The source the docs page is built from.
README.html              # Generated: the GitHub Pages docs page (house style)
index.html               # Generated: a meta-refresh redirect to README.html
tools/                   # Standalone Perl test suites (no LMS, no device) — see Tests
                         # plus make_readme_html.py, the docs generator
```

**Docs page.** `python3 tools/make_readme_html.py` from the repo root rebuilds
`README.html` + `index.html` from `README.md`. The version badge is read live from
`install.xml`, so a regen always shows the current release and nothing is hardcoded.
The "Features at a glance" table becomes the card grid; every other table stays a
table. Keep each list item on ONE line — the converter treats a wrapped continuation
line as a new paragraph and breaks the list.

## Tests

`tools/` holds standalone Perl suites that need no LMS and no device — run them
from the repo root:

- `perl tools/t_discovery.pl` — what the plugin makes of a device's answer (22
  assertions). The `getModel` body it parses is the **verbatim response from the
  live DMP-A8**, so the assertions track real firmware rather than a guess at
  its shape. It also carries the guard that **no discovery code exists**.
  `ESC_DISCOVERY` points it at a mutated copy.

- `perl tools/t_power.pl` — the Wake-on-LAN magic packet, byte for byte (12
  assertions): 6 × `0xFF` then the MAC 16 times, 102 bytes, and the MAC
  normalised from whatever separators the device reports. A packet is one
  `pack` away from silently wrong, and a wrong one fails invisibly — nothing
  answers a broadcast.

- `perl tools/t_settings.pl` — **runs the real settings handler end to end**
  (54 assertions). It stubs the LMS pieces `PlayerSettings.pm` touches, loads
  the actual module, and drives `handler()` through every state a user puts it
  in, asserting each invariant AND that the handler **ran to completion** each
  time — `SUPER_RAN` proves it, because the SUPER call is the handler's last
  statement.

  This exists because 1.5.0 shipped broken while every check passed: `perl -c`
  compiles a module, it does not execute it, so it cannot see a handler that
  dies half way. **Nothing had ever run the handler.** Anti-tested by
  reintroducing that exact bug (a call into an unloaded `Plugin.pm`), which
  took the suite from its then-45 green to **19 passed, 26 failed**. Point
  `ESC_SETTINGS` at a mutated copy to anti-test any assertion.

- `perl tools/t_plugin.pl` — the **stateful** `Plugin.pm` paths, which no other
  suite reaches (6 assertions). It stubs the LMS pieces `Plugin.pm` touches,
  loads the real module and drives it through the three cases that only appear
  once state outlives a single call: a device-state answer arriving after a
  later playback event, an off-timer created by reconcile while the screen state
  is still unknown and then cancelled at shutdown, and a power press on a synced
  group reaching exactly the buddies LMS itself would power. Each of those is a
  race or a cross-player interaction, so each passes trivially against code that
  does nothing — the assertions check that the unguarded path WOULD have acted.
  `ESC_PLUGIN` points it at a mutated copy.

## Versioning (Semantic Versioning)

`MAJOR.MINOR.PATCH`

- **PATCH (1.0.x)** — bug fixes, no behaviour change.
- **MINOR (1.x.0)** — new features / settings, backwards-compatible.
- **MAJOR (x.0.0)** — breaking changes (e.g. renamed prefs that lose existing config).

When bumping the version, update **all four** in the same change:
1. `<version>` in `install.xml` (this is what LMS compares to offer updates).
2. `version="…"` in `repo.xml` — the plugin manager reads this one, and it must
   match `install.xml` or the update it offers is not the build it installs.
3. `PLUGIN_VERSION` constant in `Plugin.pm` (logged at startup).
4. `<sha>` in `repo.xml`, recomputed with `shasum EversoloScreenControl.zip`
   AFTER the zip is rebuilt. It is the checksum the download is verified
   against, so a stale one fails the install outright.

**Bump on every rebuild.** LMS keys "is there an update" on the version number
alone, so a rebuilt zip carrying the old number is refused and the user keeps
running the previous build with no error to show for it.

`CHANGELOG.md` and `README.md` are **not** part of a dev build. They are written
once, at the merge to `main`, as a single section headed with the released
version covering everything since the last release — main is the only channel
users install from, so a section per dev build is noise. This file is the
exception: it is the dev record and is updated on every build.

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
