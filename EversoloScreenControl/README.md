# Eversolo Screen Control — Lyrion Music Server Plugin

A **per-player** plugin for Lyrion Music Server (LMS) that controls the screen on an Eversolo DMP-A8 (or DMP-A6) streaming DAC via its built-in HTTP API.

## What it does

- **Screen ON** — instantly when music starts playing on a player with the feature enabled.
- **Screen ON refresh** — re-sent on every song change, which resets the Eversolo's own screensaver timer so it never kicks in during continuous playback.
- **Screen OFF** — after a configurable delay (default 30 s) when playback pauses or stops.

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
| **Eversolo IP Address** | IP of the DMP-A8 this player connects to | — |
| **Eversolo API Port** | HTTP control port | `9529` |
| **Screen Off Delay (seconds)** | Wait time after pause/stop before screen off | `30` |

Only players where **Enable** is ticked and an **IP** is entered will trigger Eversolo commands. All other players are ignored.

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
```

All HTTP requests use LMS's `Slim::Networking::SimpleAsyncHTTP` (non-blocking), so they never interrupt audio playback.

The Eversolo API endpoint used:

```
http://<IP>:9529/ZidooControlCenter/RemoteControl/sendkey?key=<COMMAND>
```

---

## Eversolo HTTP API — Full command reference

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

**Check logs:**
- Enable debug logging: *LMS → Settings → Advanced → Logging* → set `plugin.eversoloscreencontrol` to DEBUG.

**Plugin doesn't appear in Player Settings:**
- Make sure the folder is named exactly `EversoloScreenControl` under `Plugins/`.
- Restart LMS after copying files.
- Check that the plugin is enabled in *Settings → Plugins*.

---

## License

MIT — use at your own risk. Not affiliated with Eversolo, Zidoo, or Lyrion.
