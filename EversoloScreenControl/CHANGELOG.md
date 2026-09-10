# Changelog

All notable changes to Eversolo Screen Control are documented here.

Version numbering follows [Semantic Versioning](https://semver.org/):

    MAJOR.MINOR.PATCH

    PATCH  (1.0.x)  — Bug fixes, minor corrections, no new behaviour
    MINOR  (1.x.0)  — New features, new settings, backwards-compatible
    MAJOR  (x.0.0)  — Breaking changes (e.g. renamed prefs, restructured config)

---

## [2.2.0] — 2026-09-10

Everything below has accumulated since 1.0.3. The plugin gained the ability to
power the Eversolo on and off, learned to work with players fed through a
bridge, and stopped taking the server's word for what is playing.

### New Features
- **Power the Eversolo on and off from the player's power button.** Optional and
  off by default, per player, under **Control Eversolo power**. Powering off
  sends the same shutdown the Eversolo's own app sends. Powering on is a
  Wake-on-LAN magic packet, because the device is off and nothing is listening
  for anything else.
  - **Wake-on-LAN only works over the wired network port**, and the server has
    to be on the same subnet. Over Wi-Fi the Eversolo will power down and not
    come back. Eversolo document this themselves.
  - The device's MAC address can only be read while it is **on**, so the
    settings page reads it as soon as an address is entered and says so plainly
    while it is still unknown. Tick the box while the device is off and a
    power-off is a one-way trip until you switch it on by hand.
- **A synced group powers each of its own Eversolos.** Press power on one player
  of a sync group and every buddy set to follow it now drives its own device,
  using its own settings. A buddy with the plugin turned off is left alone.
- **The settings page identifies the device.** Type an address and the page asks
  the Eversolo who it is, then shows its name — `DMP-A8 (ManCave)` rather than an
  address echoed back at you. The port is configurable for anyone not on 9529.

### Changes
- **Players fed through a bridge or a virtual player now work.** The address is
  taken from the settings page and nowhere else. It used to fall back to the
  player's own address on the theory that the player might be running on the
  Eversolo itself, which is wrong for exactly the setups that need this most —
  a bridged player reports a placeholder address, so the screen commands went to
  the server rather than the device.
- **The screen is checked against the player, not just against events.** Every
  minute the plugin compares what each enabled player is doing against what it
  believes the screen is doing, and corrects a disagreement. A stop that the
  plugin never witnessed — one that happened across a server restart, or that a
  bridged player never announced — used to leave the screen on for ever with
  nothing able to put it right.
- **The Eversolo is asked directly when the server's state looks stuck.** A
  player can sit in "playing" with a frozen clock when the thing feeding it goes
  quiet, and the screen would follow it and stay on. When the clock stops moving
  the plugin asks the device what it is actually doing and believes the answer.
  This costs one request per stuck player and nothing at all in normal use.
- A device that does not answer is treated as **no opinion**, never as
  "stopped". A missed reply will not blank a screen mid-track.

### Bug Fixes
- Fixed: a reply from the Eversolo arriving late could act on a situation that
  had already passed — blanking a screen that playback had since turned back on,
  or acting for a player whose address had been changed underneath it. Replies
  are now matched to the state that asked for them and discarded otherwise.
- Fixed: the settings page could attach one device's name and Wake-on-LAN MAC to
  a different device's address if the address was changed while a lookup was
  still in flight.
- Fixed: the chosen port was not saved.
- Fixed: a screen-off timer created by the periodic check was not cancelled when
  the plugin shut down.
- Fixed: **Enabled** and **Control Eversolo power** could get into a state where
  they could not be switched off again. The page repairs an affected setting on
  the next view.

---

## [1.0.3] — 2026-07-06

### Bug Fixes
- Fixed: the per-player settings page rendered with all fields blank (a v1.0.2
  regression). v1.0.2 removed the block that populated the template's unprefixed
  `prefs.*` keys, on the mistaken assumption that `SUPER::handler` repopulates
  them. The LMS framework only fills the `pref_`-prefixed keys, which this
  template does not read, so every field came back empty/unchecked. The manual
  population has been restored.

---

## [1.0.2] — 2026-06-26

### Bug Fixes
- Fixed: with more than one Eversolo player, resuming playback on one player
  could cancel another player's pending screen-off timer (the timer was keyed
  by the MAC string, which `Slim::Utils::Timers` compares numerically, so all
  ids collided). Timers are now keyed by the client object.
- Fixed: a **Screen Off Delay** of `0` (immediate off) was treated as "unset"
  and silently became 30 seconds. A configured `0` is now honoured.

### Changes
- Narrowed the playback event subscription to play-state changes only, so
  read-only `playlist` queries no longer wake the callback.
- Removed an unused `SCANNER` log-group assignment from the log category.
- Removed redundant settings-page pref population (the framework already
  repopulates after save).
- Corrected the placeholder homepage URL in `install.xml`.

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
