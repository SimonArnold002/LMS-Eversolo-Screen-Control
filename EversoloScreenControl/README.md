# Eversolo Screen Control — Lyrion Music Server Plugin

A **per-player** plugin for Lyrion Music Server (LMS) that controls the screen on an Eversolo DMP-A8 (or DMP-A6) streaming DAC via its built-in HTTP API.

## What it does

- **Screen ON** — instantly when music starts playing on a player with the feature enabled.
- **Screen ON refresh** — re-sent on every song change, which resets the Eversolo's own screensaver timer so it never kicks in during continuous playback.
- **Screen OFF** — after a configurable delay (default 30 s) when playback pauses or stops.
- **Power OFF / ON** — optional. The player's own power button shuts the Eversolo down, and wakes it again with Wake-on-LAN.

The plugin is **per-player**: it appears in the **Player Settings** menu (alongside DSD Player, etc.) and can be independently enabled or disabled for each player in LMS. Players that aren't connected to an Eversolo simply leave it disabled — they're completely unaffected.

---

## Requirements

| Component | Minimum version |
|---|---|
| Lyrion Music Server | 8.0 |
| Eversolo firmware | Any (HTTP control API is present in all released firmware) |
| Network | LMS and Eversolo on the same local network |

---

## Installation

1. **Locate your LMS Plugins directory:**
   - Linux (package): `/var/lib/squeezeboxserver/Plugins/`
   - Linux (manual): `~/.config/squeezeboxserver/Plugins/`
   - macOS: `~/Library/Application Support/Squeezebox/Plugins/`
   - Docker: wherever your container maps the Plugins volume
   - Or check: *LMS → Settings → Information → Plugin Folders*

2. **Copy the `EversoloScreenControl` folder** so the layout looks like this:

   ```
   Plugins/
   └── EversoloScreenControl/
       ├── Plugin.pm
       ├── PlayerSettings.pm
       ├── install.xml
       ├── strings.txt
       └── HTML/
           └── EN/
               └── plugins/
                   └── EversoloScreenControl/
                       └── settings/
                           └── basic.html
   ```

3. **Restart LMS.**

4. Go to *LMS → Settings → Plugins*, find **Eversolo Screen Control** in the list, tick to enable it, and restart LMS if prompted.

---

## Configuration (per player)

After the plugin is active, select a player and go to:

> **Settings → Player → Eversolo Screen Control**

You'll see these settings for the currently selected player:

| Setting | Description | Default |
|---|---|---|
| **Enable Eversolo Screen Control** | Activate screen control for *this* player | Off |
| **Control Eversolo power** | Also drive the Eversolo's power from the player's power button | Off |
| **Eversolo IP Address** | The address of the Eversolo this player feeds | — |
| **Eversolo API Port** | HTTP control port | `9529` |
| **Screen Off Delay (seconds)** | Wait time after pause/stop before screen off | `30` |

Only players where **Enable** is ticked trigger Eversolo commands. All other players are ignored.

### You tell it where the Eversolo is

Type the Eversolo's IP address into **Eversolo IP Address** and save. That is the whole of the setup.

There is no network scan. Two were tried and both removed: a sweep of the local subnet, which floods the ARP table and can take the server off the network, and an SSDP search, which was a lot of machinery for a problem nobody has — you know the address, and typing it once is less work than any of it.

What the plugin does do with the address is ask the device who it is, so the settings page can show you **DMP-A8 (ManCave)** beside the box rather than echoing the address back. That answer arrives asynchronously, so it appears the next time you open the page.

### Powering the Eversolo on and off

Tick **Control Eversolo power** and the player's power button in LMS drives the device itself:

- **Off** — an HTTP `setPowerOption?tag=poweroff`, the same shutdown the Eversolo's own app sends.
- **On** — a Wake-on-LAN magic packet, because a device that is off cannot answer HTTP.

Two things follow from that, and both are worth knowing before you tick the box:

- **Wake-on-LAN is wired-only.** Over Wi-Fi the Eversolo's network interface is not listening while it is off, so it will power down and not come back. Use Ethernet.
- **The MAC address is learned while the device is on.** The plugin reads it from the device the first time it identifies it, because by the time it needs waking it is too late to ask. So open the settings page once with the Eversolo switched on; if the MAC isn't known yet, the page says so.

**Synced players each drive their own Eversolo.** If you press power on one player of a sync group, every buddy set to follow it powers its own device too, using its own settings. A buddy that has the plugin switched off, or power control unticked, is left alone.

### Bridged and virtual players

The player driving the Eversolo doesn't have to be the Eversolo. **LMS → HQPlayer Bridge → HQPlayer → Eversolo** works exactly like a direct connection: the plugin is configured on whichever player you play to, and the screen commands go to the Eversolo at its own address. Bridged and virtual players (HQPlayer Bridge, player groups, UPnP bridges) have no network address of their own — that's fine, because the player's address isn't what's used.

### It corrects itself, and it asks the Eversolo

The screen doesn't rely on catching every event. Once a minute the plugin checks each enabled player's actual state and fixes any disagreement — so a player that stopped while the server was restarting, or a stop the bridge never announced, still ends with the screen off.

It also doesn't take LMS's word as final. A player fed through a bridge can get stuck reporting "playing" with a frozen clock after the far end stops talking. When the plugin sees that — playing, but the song position hasn't moved — it asks the Eversolo directly what *it* is doing, and sets the screen to match.

That question is only asked when it can change the answer: playing with a moving clock, or plainly stopped, are both settled without touching the network. In normal use the plugin makes no calls to the device at all beyond the ON and OFF it already sends.

### Finding your Eversolo's IP

On the DMP-A8 touch screen: **Settings → About** — the IP is shown under the network section. For reliability, assign a static IP or DHCP reservation on your router.

---

## How it works

```
Music starts playing
    → cancel any pending "screen off" timer
    → send Key.Screen.ON to Eversolo

New song starts (track change)
    → cancel any pending "screen off" timer
    → re-send Key.Screen.ON  (resets Eversolo screensaver timer)

Music pauses or stops
    → start a 30-second timer

Timer fires (and player is still paused/stopped)
    → send Key.Screen.OFF to Eversolo

Music resumes before timer fires
    → timer is cancelled, screen stays on

Player powered off      (only with "Control Eversolo power")
    → send setPowerOption?tag=poweroff to Eversolo

Player powered on       (only with "Control Eversolo power")
    → broadcast a Wake-on-LAN magic packet to the Eversolo's MAC
```

All HTTP requests use LMS's `Slim::Networking::SimpleAsyncHTTP` (non-blocking), so they never interrupt audio playback.

The Eversolo API endpoints used:

```
http://<IP>:9529/ZidooControlCenter/RemoteControl/sendkey?key=<COMMAND>
http://<IP>:9529/ZidooMusicControl/v2/setPowerOption?tag=poweroff
http://<IP>:9529/ZidooControlCenter/getModel          (name, MAC, model)
http://<IP>:9529/ZidooMusicControl/v2/getState        (what the device is really doing)
```

Wake-on-LAN is not an HTTP call: it is a UDP magic packet broadcast to ports 9 and 7.

---

## Eversolo HTTP API — Full command reference

This is the device's own remote-key list, recorded here for reference. It is **not** a list of what the plugin does — the plugin sends only `Key.Screen.ON` and `Key.Screen.OFF`, and (for power off) `setPowerOption`, which is a different endpoint from `Key.Poweroff` and the one the Eversolo app itself uses.

| Key | Function |
|---|---|
| `Key.Screen.ON` | Turn screen on |
| `Key.Screen.OFF` | Turn screen off |
| `Key.Screen.Display` | Cycle screen display mode |
| `Key.MediaPlay` | Play |
| `Key.MediaPause` | Pause |
| `Key.MediaPlay.Pause` | Toggle play/pause |
| `Key.MediaNext` | Next track |
| `Key.MediaPrev` | Previous track |
| `Key.VolumeUp` / `Key.VolumeDown` | Volume |
| `Key.Mute` | Mute toggle |
| `Key.Poweroff` | Power off |
| `Key.Reboot` | Reboot |
| `Key.DAC.XMOS` | Input: Internal player |
| `Key.DAC.BT` / `Key.DAC.USB` / `Key.DAC.SPDIF` / `Key.DAC.COA` | Inputs |
| `Key.OUT.XLR` / `Key.OUT.RCA` / `Key.OUT.HDMI` / `Key.OUT.SPDIF` / `Key.OUT.USB` | Outputs |

---

## Troubleshooting

**Screen doesn't respond:**
- Verify the API manually — paste this in a browser:
  `http://<EVERSOLO_IP>:9529/ZidooControlCenter/RemoteControl/sendkey?key=Key.Screen.OFF`
  If the screen turns off, the API works.

**Power on does nothing:**
- The Eversolo must be on **wired Ethernet** — Wake-on-LAN cannot reach it over Wi-Fi.
- The plugin needs the device's MAC, which it can only read while the device is on. Switch the Eversolo on, open the player's Eversolo settings page once, and the MAC is learned and stored.

**Settings save but nothing changes:**
- LMS loads plugin code at startup only, so a new version needs a restart. If a copy is also installed from the plugin repository, that copy shadows a manually installed one — uninstall it and reinstall so only one copy is present.

**Check logs:**
- Enable debug logging: *LMS → Settings → Advanced → Logging* → set `plugin.eversoloscreencontrol` to DEBUG.

**Plugin doesn't appear in Player Settings:**
- Make sure the folder is named exactly `EversoloScreenControl` under `Plugins/`.
- Restart LMS after copying files.
- Check that the plugin is enabled in *Settings → Plugins*.

---

## License

MIT — use at your own risk. Not affiliated with Eversolo, Zidoo, or Lyrion.
