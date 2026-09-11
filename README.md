# Eversolo Screen Control — for Lyrion Music Server

Drives the screen on an **Eversolo DMP-A8 or DMP-A6** from **Lyrion Music Server (LMS)**: the display comes on when music starts, stays awake between tracks, and switches off again a set time after playback stops. Optionally the player's power button shuts the Eversolo down too. It is **per-player**, so only the players you point at an Eversolo are ever touched.

Tested on LMS 9.x against a live DMP-A8; LMS 8.0 and the DMP-A6 use the same control API.

---

## Features at a glance

| Feature | What it gives you | Needs |
|---|---|---|
| **Screen on with the music** | The display lights the moment playback starts on an enabled player | Nothing |
| **No screensaver mid-album** | The ON key is re-sent at every track change, which resets the Eversolo's own screensaver timer so it never cuts in during continuous play | Nothing |
| **Screen off after a delay** | A configurable wait (default 30 s) after pause or stop, cancelled if you start again | Nothing |
| **Power off with the player** | The player's power button shuts the Eversolo down — the same shutdown its own app sends | Nothing |
| **Per-player** | Lives in Player Settings and is enabled per player — every other player is unaffected | Nothing |
| **Synced groups** | Power a sync group and each buddy drives its own Eversolo with its own settings | Nothing |
| **Bridged and virtual players** | HQPlayer Bridge, player groups and UPnP bridges work the same, because the player's own address is never used | Nothing |
| **Named, not numbered** | The settings page asks the device who it is and shows **DMP-A8 (ManCave)** beside the address | Nothing |
| **Self-correcting** | Once a minute the real player state is checked and any disagreement fixed, so a stop lost to a server restart still ends with the screen off | Nothing |
| **Asks the device** | When LMS reports "playing" with a frozen clock, the Eversolo is asked what it is really doing and the screen set to match | Nothing |
| **No network scanning** | You type the address once. No subnet sweep, no SSDP | The Eversolo's IP address |

Everything runs through LMS's non-blocking HTTP, so nothing here can interrupt audio. In normal use the plugin makes no calls to the device beyond the ON and OFF it already sends.

---

## Requirements

| Component | Minimum |
|---|---|
| Lyrion Music Server | 8.0 |
| Eversolo firmware | Any — the HTTP control API is present in every released firmware |
| Network | LMS and the Eversolo on the same local network |

Pure Perl, no extra server software, no external tools — it runs the same on a Raspberry Pi or a NAS.

---

## Installation

**Via repository (recommended).** In LMS go to **Settings → Plugins → Additional Repositories** and add:

```
https://simonarnold002.github.io/LMS-Eversolo-Screen-Control/repo.xml
```

Then install **Eversolo Screen Control** from the plugin list and restart.

**Manual.** Download `EversoloScreenControl.zip` from the [repository](https://github.com/SimonArnold002/LMS-Eversolo-Screen-Control), unzip it into your LMS `Plugins/` directory so it sits as `Plugins/EversoloScreenControl/`, and restart:

```bash
sudo rm -rf /var/lib/squeezeboxserver/Plugins/EversoloScreenControl
sudo unzip EversoloScreenControl.zip -d /var/lib/squeezeboxserver/Plugins/
sudo systemctl restart lyrionmusicserver
```

Your Plugins directory is shown under *LMS → Settings → Information → Plugin Folders*. Common locations:

- Linux (package): `/var/lib/squeezeboxserver/Plugins/`
- Linux (manual): `~/.config/squeezeboxserver/Plugins/`
- macOS: `~/Library/Application Support/Squeezebox/Plugins/`
- Docker: wherever the container maps the Plugins volume

> Install it **one way only**. A copy installed from the repository shadows a manually installed one, and the version you edit is not the version that runs.

---

## Configuration (per player)

Select a player, then go to **Settings → Player → Eversolo Screen Control**:

| Setting | Description | Default |
|---|---|---|
| **Enable Eversolo Screen Control** | Activate screen control for *this* player | Off |
| **Control Eversolo power** | Also drive the Eversolo's power from the player's power button | Off |
| **Eversolo IP Address** | The address of the Eversolo this player feeds | — |
| **Eversolo API Port** | HTTP control port | `9529` |
| **Screen Off Delay (seconds)** | Wait after pause or stop before the screen goes off | `30` |

Only players with **Enable** ticked send anything to a device. Every other player is ignored.

### You tell it where the Eversolo is

Type the address into **Eversolo IP Address** and save. That is the whole of the setup.

There is no network scan. Two were tried and both removed: a sweep of the local subnet, which floods the ARP table and can take the server off the network, and an SSDP search, which was a lot of machinery for a problem nobody has — you know the address, and typing it once is less work than either.

What the plugin does with the address is ask the device who it is, so the settings page can show **DMP-A8 (ManCave)** rather than echoing the address back. That answer arrives asynchronously, so it appears the next time you open the page.

To find the address, on the DMP-A8 touch screen go to **Settings → About** and read it from the network section. Assign a static IP or a DHCP reservation so it stays put.

### Powering the Eversolo off

Tick **Control Eversolo power** and the player's power button shuts the device down, with an HTTP `setPowerOption?tag=poweroff` — the same shutdown the Eversolo's own app sends.

> This is a **one-way** switch. Once the Eversolo is off it drops off the network and its player disappears from LMS, so there is nothing left in LMS to press. Switch it back on at the device.

**Synced players each drive their own Eversolo.** Press power on one player of a sync group and every buddy set to follow it powers its own device too, using its own settings. A buddy with the plugin switched off, or power control unticked, is left alone.

### Bridged and virtual players

The player driving the Eversolo doesn't have to be the Eversolo. **LMS → HQPlayer Bridge → HQPlayer → Eversolo** works exactly like a direct connection: configure the plugin on whichever player you play to, and the screen commands go to the Eversolo at its own address. Bridged and virtual players have no network address of their own, which doesn't matter, because the player's address is never what's used.

### It corrects itself, and it asks the Eversolo

The screen doesn't rely on catching every event. Once a minute each enabled player's actual state is checked and any disagreement fixed — so a player that stopped while the server was restarting, or a stop the bridge never announced, still ends with the screen off.

Nor does it take LMS's word as final. A player fed through a bridge can get stuck reporting "playing" with a frozen clock after the far end stops talking. When the plugin sees that — playing, but the song position hasn't moved — it asks the Eversolo directly what *it* is doing, and sets the screen to match. That question is only asked when it can change the answer: playing with a moving clock, or plainly stopped, are both settled without touching the network.

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
```

Every HTTP request goes through LMS's `Slim::Networking::SimpleAsyncHTTP`, so none of it blocks playback. The endpoints used:

```
http://<IP>:9529/ZidooControlCenter/RemoteControl/sendkey?key=<COMMAND>
http://<IP>:9529/ZidooMusicControl/v2/setPowerOption?tag=poweroff
http://<IP>:9529/ZidooControlCenter/getModel          (name and model, for the settings page)
http://<IP>:9529/ZidooMusicControl/v2/getState        (what the device is really doing)
```

---

## Eversolo HTTP API — full command reference

The device's own remote-key list, recorded here for reference. It is **not** a list of what the plugin does — the plugin sends only `Key.Screen.ON` and `Key.Screen.OFF`, plus `setPowerOption` for power off, which is a different endpoint from `Key.Poweroff` and the one the Eversolo app itself uses.

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
| `Key.DAC.XMOS` | Input: internal player |
| `Key.DAC.BT` / `Key.DAC.USB` / `Key.DAC.SPDIF` / `Key.DAC.COA` | Inputs |
| `Key.OUT.XLR` / `Key.OUT.RCA` / `Key.OUT.HDMI` / `Key.OUT.SPDIF` / `Key.OUT.USB` | Outputs |

---

## Troubleshooting

**The screen doesn't respond.** Verify the API by hand — paste this into a browser: `http://<EVERSOLO_IP>:9529/ZidooControlCenter/RemoteControl/sendkey?key=Key.Screen.OFF`. If the screen goes off, the API works and the address is right.

**Settings save but nothing changes.** LMS loads plugin code at startup only, so a new version needs a restart. If a copy is also installed from the plugin repository, that copy shadows a manually installed one — remove one of them so only a single copy is present.

**The plugin isn't in Player Settings.** Check the folder is named exactly `EversoloScreenControl` under `Plugins/`, that the plugin is enabled in *Settings → Plugins*, and that LMS has been restarted since the files were copied.

**Check the logs.** *LMS → Settings → Advanced → Logging* → set `plugin.eversoloscreencontrol` to DEBUG.

---

## License

MIT — use at your own risk. Not affiliated with Eversolo, Zidoo or Lyrion.
