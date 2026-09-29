# CLAUDE.md

Guidance for Claude Code when working in this repository.

## REVIEW LEDGER

### DISPROVEN — beliefs the code suggested and a measurement killed

Re-raise one only by disproving the evidence it cites.

| belief | what the measurement showed |
|---|---|
| `$prefs->setPlayerDefault(...)` sets a per-player default | **There is no such method in LMS.** `Slim::Utils::Prefs::Base::AUTOLOAD` (Base.pm:319 in 9.0) installs an accessor for any unknown name, so the call became `set('setPlayerDefault', <the pref NAME>)`: one junk namespace pref holding the last name passed, and **no default applied to any player**. Measured live 2026-09-28 — `plugin.eversoloscreencontrol:setPlayerDefault` was `"home_power"`. Shipped this way through 2.3.0. Fixed: `%CLIENT_DEFAULTS` + `client($client)->init`, applied to attached players at init and to each `client new`; `initPlugin` removes the junk pref. Grepped the fleet: no other repo CALLS it (HQPlayer Bridge and Platin Bridge only had dead test stubs) |
| the suites would have caught that | `t_plugin.pl` **defined a fake `setPlayerDefault`** on its prefs stub, and `t_settings.pl` a no-op one, so 174 assertions passed against a defaults block that did nothing. Both removed, and `t_plugin.pl` now asserts the method does NOT exist. The original `Plugin.pm` no longer loads against the corrected harness |
| `client new` cannot resolve its client | It can. `Client::new` puts the client in `%clientHash` (Client.pm:310) **before** notifying (:315), and `notifyFromArray` carries the object — so `$request->client` is live there. (Unlike `client forget`, where `->client` really is always undef) |
| `forgetTimer` runs a pending timer's callback | It does NOT. `Client::forgetClient` calls `Timers::forgetTimer`, which fires `$timer->cb->(EV_KILL)` — and the wrapper in `Timers.pm::_makeTimer` **returns on EV_KILL before calling `$subptr`**. So `_turnScreenOff` never ran on a forget and never cleared `%offPending{$id}`: reconcile then skipped that id for ever (`next if $offPending{$id}` in the not-playing branch), and the discarded client object was retained. `_onForget` now clears `%offPending`, `%screenState`, `%lastElapsed`, `%playbackRevision` and the `$id/...` keys of `%warnedPlaceholder`, before the `home_power` check, for every forgotten player |
| a `=~` assertion in these suites can fail | **It could not.** A regex match in LIST context yields the EMPTY LIST on failure, so `ok($html =~ /re/, 'label')` reached `ok` as `('label')` — a truthy `$cond` and an undef label — and a FAILED assertion printed `PASS` with a blank name. All 17 such call sites (t_page.pl only) now force boolean context with `!!`, and `ok` counts a missing label as a FAILURE rather than dying. Found 2026-09-29 by anti-testing; every `ok($x =~ ...)` written before that date passed vacuously |
| `client forget` means a user removed a player | **It usually means LMS's own timer.** `Slimproto.pm`'s `$forget_disconnected_time = 300` arms on every slimproto socket close and `forget_disconnected_client` then issues `['client','forget']`. An Eversolo on **SqueezeConnect** is a slimproto player, so switching the device off produced a forget 5 minutes later. Meanwhile the deliberate removal it was written for never arrives this way: **nothing in `lms-material` issues a forget** (grepped 2026-09-29: 95 js/pm files, zero occurrences, and `player` matches as a control), and no handler in LMS's Perl tree issues one either — only a hardware front-panel menu (`Buttons/Settings.pm:1033`) and an internal Jive cleanup that calls `forgetClient` DIRECTLY and notifies nobody. `_onForget` is now state-only |
| a plugin can tidy its Material Home tile away on uninstall | **It cannot, for two independent reasons.** (1) LMS has no uninstall hook: `PluginManager::_needsUninstall` is `rmtree` + `$prefs->remove`, run at startup before plugins load, and the only per-plugin callbacks are `initPlugin`/`postinitPlugin` (:391) and `shutdownPlugin` (:419). (2) Material's Home list is saved with `setLocalStorageVal("topItems", …)` — it lives in each **browser's localStorage**, so nothing server-side can reach it. `loadCustomPinned` only ever ADDS, and never prunes an entry whose action has gone. After an uninstall the action disappears from `$PLUGIN_CUSTOM_ACTIONS` (in-memory, rebuilt each start) so it stops being offered, but an already-pinned tile stays and opens a 404. It carries `menu: [RENAME_ACTION, UNPIN_ACTION]`, so the user can unpin it by hand — the same as any other plugin's shortcut. Nothing to fix; do not propose an uninstall hook |
| `$prefs->allClients` order is stable | It is `keys %{...}` (Namespace.pm:244), randomised per process. `_powerDevices` fills each field from the first player that has one, so it now sorts on `clientid` first — otherwise two players on one device handed the page a different port, name or MAC per restart. `t_plugin.pl`'s stub deliberately yields them in REVERSE order so anything order-dependent fails there |

### Settled

- **The power page's optimistic row must survive an answer already in flight.** A
  status answer computed before a press lands after it, and applying it put the row
  back to `off` and re-enabled the button — the press looked inert and a re-tap sent
  the command twice. The script stamps each poll with a press counter (`era` /
  `pressed`) and discards a stale answer; it is the NEXT poll that replaces the
  optimistic state. A tick arriving while a poll is in flight now reschedules
  instead of dropping out of the loop.
- **`Power.pm` keeps no copy of its path.** `init` used to store `$PATH` and nothing
  ever read it. The page posts to `/jsonrpc.js`, never back to itself; holding the
  path would be the first thread of the coupling the module header forbids.
- **The power page keeps the keyboard.** `render()` empties and rebuilds the card
  list on every 2–5s poll and again on the arming tap, which threw away the focused
  button — so the two-tap power-off could not be completed from the keyboard at all.
  Each button now carries `data-id`, and `render` notes the focused id and puts focus
  back, matching on the id rather than through a selector an address would have to
  survive being quoted into.
- **A Wake-on-LAN packet that never left is not a wake.** `_sendWake` discarded the
  `setsockopt` and `send` returns and returned 1 regardless, so a failed send armed
  the 120s `WAKE_GRACE` over a device that was never signalled — and nothing answers
  a magic packet, so it was invisible. It now counts successful sends across the four
  targets, warns per failure, and returns 0 when none got out. Still no rig where
  `send` is known to fail; this closes the reporting hole, not an observed outage.
- **`Plugin.pm` declares `Slim::Utils::Strings` itself.** It calls
  `Slim::Utils::Strings::string` once (the Home tile's title). The server always has
  that module loaded, so this was never a live failure — but the file states the rule
  at its own head, and the suites had no `%INC` entry for it.

### Round 2026-09-28 (of 6495b74, `origin/dev..HEAD` = 2.3.0)

5 findings, all 5 verified against LMS 9.0 source + the live rig and all 5 FIXED,
UNCOMMITTED, not built, not installed. Suites 174 → **193** assertions, all green.

### Round 2026-09-29 (of the same tree plus round 1's fixes)

3 findings, all verified against the local LMS 9.0 tree and all 3 FIXED: the
`%offPending` leak on `client forget`, the power page losing keyboard focus on every
poll, and `_sendWake` reporting success for a packet that never left. Suites 193 →
**200**.

A fourth thing fell out of anti-testing and is fixed too: **every `=~` assertion in
`t_page.pl` was incapable of failing** (the list-context row above), which means both
rounds' source-level assertions had been passing vacuously. All of them were
re-anti-tested afterwards and every one does now catch its bug — round 1's five
press-counter assertions included. Anti-testing is not optional in this repo: two
rounds of green were partly meaningless without it.

Still UNCOMMITTED, not built, not installed.

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

**Current version: 2.3.0**

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

**2026-09-28: that route now exists on `dev`** — the power page below. Built and
suite-tested, NOT yet verified live. The README section is written at the merge
to `main` like every other README change, not on a dev build, so the README is
still correct to omit it until then.

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

### The power page and its Material Home tile (dev, 2026-09-28, unverified live)

**Why it exists:** once an Eversolo is off its LMS player disappears, and with it
the only button that ever sent the wake packet. The page needs no player.

- **Opt-in per player** — `home_power` (default 0), a third checkbox on the
  player's settings page ("Power button on Material's Home screen"). A player
  qualifies with `enabled` + `power_control` + `home_power`. Simon's call: the
  tile must be something a user asks for, not something every install gets.
- **`Power.pm`** — a raw handler at `/eversolopower` (the path is owned by
  `Plugin.pm` and handed to `init`; the module calls nothing in `Plugin.pm`). One
  card per device, one button: on → two taps to switch off (the first arms it for
  4s — NOT `confirm()`, which an embedded webview may never show), off → one tap
  to wake. States: `on`, `off`, `waking`, `stopping`. Polls every 5s, every 2s
  while a press is settling, and not at all while the page is hidden.
- **The heredoc is `<<'HTML'`, NOT interpolating.** Labels go in by `%%TOKEN%%`
  substitution, HTML-escaped, and reach the script as `data-*` on `<body>`. This
  sidesteps the whole Perl-eats-the-JS-backslash trap HQPlayer Bridge's `Live.pm`
  documents. Keep it that way.
- **Two CLI commands, server-level** (no player): `eversolopower status` →
  `count`, `devices_loop[{id,name,state,canwake}]`; `eversolopower set id:<ip>
  to:on|off`. A press names a device and the address, port and MAC are read back
  from the prefs — nothing from the page is trusted as an address.
- **Devices come from `$prefs->allClients`**, which returns the stored prefs of
  EVERY player the namespace has seen, connected or not (read-only, not
  migrated). A device is its address, so two players on one Eversolo list it
  once, taking the MAC and name from whichever player learned them.
- **On = answers `getModel`.** An Eversolo that is off has nothing listening at
  all, so "no answer" is off. A press is believed over the device's answer for
  `WAKE_GRACE` (120s) / `STOP_GRACE` (60s) — `%powerPending`, keyed by address —
  so a booting device reads "switching on", not "off".
- **ASYNC ORDER in `_powerStatusQuery`.** LMS's `setStatusDone` calls
  `executeDone` when the status is processing, and `execute()` calls it again
  unless the status is STILL processing — so a probe answering synchronously
  after `setStatusProcessing` fires the callback TWICE. Processing is declared
  after the loop, only if something is outstanding. `t_plugin.pl` pins it with a
  stub that has LMS's semantics.
- **The Home tile** is a `pinned` custom action with `iframe` (inline dialog, like
  HQPlayer Bridge's), registered from `_syncHomeTile` at `postinitPlugin` and on a
  `setChange` of `home_power`/`power_control`/`enabled`. Material's registry
  PUSHES with no unregister and no de-dupe, so the action hashref is kept in
  `$homeTile` and registered at most once per server run (never reset in
  shutdown); withdrawing it DELETES its `iframe`, because `loadCustomPinned` skips
  an action with neither `iframe` nor `weblink`. Material fetches the registry per
  page load (`material-skin plugin-actions`), so a change shows after a Material
  refresh. A tile already on a Home screen stays until the user unpins it —
  Material only ever adds tiles — and a tap on it then shows the "none" message.
- **Off from the page** also drops the pending screen-off of every connected
  player whose `eversolo_ip` is that device, as a player's own power-off does.
- **THE GRACE WINDOW COVERS BOTH SURFACES.** `%powerPending` used to be stamped
  only by the page's own button, so a wake from the PLAYER's power button left
  the page showing the device Off with a live "switch on" button for the whole
  ~60s boot, and a player power-off left it showing On while the device shut
  down. Both directions now go through one `_markPowerPending`, keyed by
  address. A wake is only believed if `_sendWake` says the packet actually left.
- **AN ADDRESS IS PART OF QUALIFYING** (Simon's call, 2026-09-29). `_homePowerOn`
  requires a non-empty `eversolo_ip` as well as the three ticks, through the one
  `_deviceAddress` helper the device list also uses — while the two gates
  disagreed, a player with the boxes ticked and no address was offered a tile
  that opened a page saying no player had the box ticked. `eversolo_ip` is
  therefore in the `setChange` list: filling the address in afterwards is what
  offers the tile. `t_plugin.pl` reads that list out of this file's source
  rather than mirroring it, so it cannot drift.
- **THE TICK IS THE ONLY THING THAT CONTROLS THE TILE** (Simon's call,
  2026-09-29). A player qualifies while `home_power` is on; untick it and
  `_syncHomeTile` withdraws the action. `_onForget` does **not** clear it — see
  the Review Ledger: `client forget` is overwhelmingly LMS's own 300s
  disconnect timer, which an Eversolo on SqueezeConnect triggers every time it
  is switched off, and the deliberate removal it was written for is not
  reachable from Material or the LMS web UI at all. `_onForget` survives as
  state-only cleanup (`%offPending` and friends), which a forget really does
  leak. **Keyed on `$request->clientid`, NEVER `->client`**: the notification
  arrives after `forgetClient`, so `->client` is always undef — HQPlayer Bridge
  shipped exactly that bug (its ledger, `_onForget could never fire`).
- **A tile already pinned to a Home screen can only be removed by the user.**
  It is in that browser's `localStorage`, so neither this plugin nor Material's
  server half can take it away — true when the box is unticked and true after
  the plugin is uninstalled. Unpin is on the tile's own menu. Do not try to fix
  this; see the Review Ledger row.
- **Material's only reader of `pinned` is `loadCustomPinned`** (grepped
  2026-09-28, JS and Plugin.pm), so an action stripped of `iframe` is inert.

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
nothing to pick from. The page's six fields are `pref_eversolo_ip`,
`pref_eversolo_port`, `pref_screen_off_delay` and the three checkboxes
`pref_enabled`, `pref_power_control` and `pref_home_power` (the power page
opt-in — saved by this page, acted on by `Plugin.pm` through a pref change
callback, so this module still calls nothing there); every one is range-checked in `handler`
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
├── Power.pm             # The power page (/eversolopower), a raw handler - no player needed
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
  (62 assertions). It stubs the LMS pieces `PlayerSettings.pm` touches, loads
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

  Since 2026-09-28 it also drives the power page's server half (87 assertions
  in all; the forget path through the real `setChange` carrier, with a stub
  request whose `->client` is undef as LMS's is): the Home tile registered once and only on opt-in, withdrawn and
  restored in place; the device list built from DISCONNECTED players' prefs and
  de-duplicated by address; `eversolopower status` completing exactly once
  whether its probes answer later or inline (the stub `Stub::Query` carries
  LMS's real `setStatusDone`/`execute` semantics — that is what makes the
  double-callback trap testable); and `eversolopower set` refusing anything not
  opted in, waking by the stored MAC, and holding `waking`/`stopping` until the
  device agrees.

- `perl tools/t_page.pl` — renders the REAL `Power.pm` page (28 assertions)
  against the REAL `strings.txt`: every `%%TOKEN%%` filled, every label the
  script reads present on `<body>`, labels escaped out of their attribute, the
  body sent as UTF-8 octets with a status code set, and the two command names the
  page calls matching the ones `Plugin.pm` registers. `ESC_POWER` points it at a
  mutated copy.
  It also pins the press counter that keeps an in-flight status answer from
  undoing a press (see the Review Ledger).

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
