# lenovo-battery-tray

Tray icon + global hotkeys + CLI for Lenovo consumer laptops: charge mode (Normal / Conservation / Rapid Charge) and Fn+Q power mode. No admin rights. No Lenovo Vantage needed. No install of anything — Windows PowerShell 5.1, in-box. ~110-150 MB RAM (F5.4).

## Install

Download the release zip, extract, run `install.ps1`. It drops a Startup shortcut so the tray starts at login; nothing else on the system is touched.

Uninstall: run `uninstall.ps1` (removes the Startup shortcut and stops any running tray, unless `-KeepRunning` is passed).

## Hotkeys

Defaults, changeable in `config.json`:

| Combo | Action |
|---|---|
| Ctrl+Alt+6 | toggle-conservation |
| Ctrl+Alt+7 | toggle-rapid |
| Ctrl+Alt+8 | power-step (cycle Fn+Q power mode) |

Config path: `%LOCALAPPDATA%\lenovo-battery-tray\config.json`

```json
{
  "hotkeys": { "Ctrl+Alt+6": "toggle-conservation", "Ctrl+Alt+7": "toggle-rapid", "Ctrl+Alt+8": "power-step" }
}
```

## CLI

`src\lenovo-battery.ps1 <command>`:

| Command | Effect |
|---|---|
| `get` | print current charge mode |
| `set Normal\|Conservation\|RapidCharge` | set charge mode |
| `toggle-conservation` | flip Conservation on/off |
| `toggle-rapid` | flip Rapid Charge on/off |
| `caps` | print supported charge-mode capabilities |
| `power-get` | print current Fn+Q power mode |
| `power-set -Mode Auto\|Cool\|Performance` | set power mode |
| `power-step` | cycle power mode (skips modes not available on this model) |
| `diag` | print diagnostic lines for bug reports |

## Compatibility

| Model | Status | Notes |
|---|---|---|
| IdeaPad Slim 9 14ITL5 (82D2) | verified | reference machine, all commands tested |
| Other IdeaPad / Yoga / Slim / ThinkBook with `ACPI\VPC2004` driver | expected, unverified — please report | run `diag` and open an issue with the output |
| Legion / LOQ | not supported | use [Lenovo Legion Toolkit](https://github.com/BartoszCichecki/LenovoLegionToolkit) instead |
| ThinkPad | not supported | different EC protocol entirely |

The conservation-mode charge threshold (the % band it holds the battery within) is fixed by firmware per model and is not adjustable by this tool, or by Vantage — Lenovo's own guides put it anywhere from roughly 55–60% on older models to 75–80% on current ones, depending on generation.

## Report an issue

Run `src\lenovo-battery.ps1 diag` and paste its full output into a new issue using the issue template — include your model and MTM (System Information, or the sticker on the base).

## How it works

Charge mode goes through the `\\.\EnergyDrv` device via a documented IOCTL (`0x831020F8`); power mode goes through the `LITSSVC` Windows service's control-code interface. Both work without admin rights on the reference machine. Constants were taken from the MIT-licensed [OpenLenovoSettings](https://github.com/dantmnf/OpenLenovoSettings) project and the Linux kernel's `ideapad-laptop.c` driver. Lenovo Legion Toolkit (GPL-3) was read only as a reference for behavior; no code from it was copied.

## Roadmap

- v0.2: auto-switch charge mode on AC plug/unplug or battery %
- C# port distributed via winget, if there's demand for it

## Licence

MIT — see [LICENSE](LICENSE).
