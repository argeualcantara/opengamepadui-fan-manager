# Fan Manager

An [OpenGamepadUI](https://github.com/ShadowBlip/OpenGamepadUI) plugin for
monitoring and controlling system fan curves, right from the quick bar.

## Warning

Still under active development. Fan control means writing to your
hardware; a bad curve can mean a hot, loud, or throttling device. Use
at your own risk, and read the "Making it actually control your fans"
section below before you expect anything to happen on real hardware.

## What it does

The plugin adds a card to OpenGamepadUI's quick bar with a dropdown for
two modes:

- **BIOS mode**: leaves fan control to the manufacturer logic. This is the safe default and what your device runs if not using other software to manage fan curves.
- **Custom mode**: you control the curve yourself: one slider per
  temp from 10°C to 100°C, one curve per fan (some handhelds have separate CPU/GPU fans, shown as tabs). Moving a slider only edits
  a draft in memory; nothing is written to hardware or disk until you press **Apply**.

> #### Switching modes and pressing Apply both take effect immediately. First time changing to custom comes with a predefined balanced curve.

### Per-game curves

There's a toggle for per-game curves. With it off, there's a single
curve/mode that always applies, no matter what you're running. With it
on, the plugin tracks whichever game (or Steam's own home screen) is
currently running and remembers a separate mode + curve for each one:
switch games and the fan settings switch with it, automatically.

The first time it sees a game it's never configured before, it starts
that game in **BIOS mode** with a predefined curve ready to go in **Custom mode**  if you switch it to custom, new games never inherit a curve from another context.

Turning per-game curves off snaps you back to the single shared curve.
Turning it back on should load the saved curves for the current context if it exists, otherwise it load the default fan curve.

## Making it actually control your fans

Two separate things both need to be true before flipping a mode/curve
actually changes anything on your hardware:

**1. "Write to hardware" has to be turned on.**

By default the plugin runs in a dry-run mode: every write it would make gets logged (exact sysfs path, exact value) but nothing actually touches the hardware. 

This is on purpose, so you can watch a session's
logs and sanity-check what it *would* have done.
You can turn dry-run on/off via plugin settings menu, for now every time the plugin (re)loads it as dry-run true, so this isn't a "set once and forget"
switch yet.

This decision was made to test as many devices as possible first before leaving dry-run false as default.

**2. The privileged write helper has to be installed.**

The sysfs files that actually control your fans are owned by root:root.
The plugin tries a direct write first and falls back to a small systemd service + polkit rule that's **authorized to write only to this plugin's own set of fan attributes**, with the value validated before it touches anything. 

Until that service/rule is installed, the
fallback has nothing to fall back to, and any write to real hardware
just fails and gets logged as such. The three files it needs live in
`policy/`.

If you haven't set up the privileged helper yet, "write to hardware"
being on will just get you failed writes in the log instead of the
dry-run message — check the log either way if a curve doesn't seem to
be taking effect.

## Safety unload

If the plugin gets disabled, uninstalled, or reloaded while you're in custom mode, it reverts your fans to BIOS mode on the way out, so you never end up stuck on a static custom curve with nothing left running
to keep applying it. 

Your saved per-game settings aren't touched by this, it's a hardware revert only.

## Supported hardware

Currently there are two backends implemented, tried in this order, first one that matches wins:

- **ASUS WMI custom fan curve**: needs the `asus-wmi-sensors` driver exposing its `asus_custom_fan_curve` hwmon device. 

    Applies an 8 point temp/fan speed saving the 8 hottest temperatures; the curve to the hardware in one shot; it does not need polling to work.

- **Generic hwmon** — works on anything exposing a plain `pwmN`/`tempN_input` pair, but has no native curve support, so the plugin sets a polling mechanism to read the temperature and re-applies the current point every 5 seconds while in custom mode.

If neither is detected, the plugin still loads but mode switching is
disabled (you'll see a "no backend available" message instead of the
dropdown).

## Development

`local-deploy.sh` rebuilds the zip, drops it into
`~/.local/share/opengamepadui/plugins`, and installs the privileged write helper's systemd service + polkit rule from `policy/` (skipped if all three are already present).

### Tests

`tests/` is a standalone GUT, both get downloaded fresh in CI (see `.github/workflows/test.yml`).

```
./tests/run-tests.sh
```

Sets up whatever's missing (downloads GUT if `tests/addons/gut` isn't there yet, (re)creates the `tests/plugins/fan-manager` symlink if it's missing or wrong) and runs the suite. 
Assumes `godot` is on your PATH; point it at a specific binary with `GODOT_BIN=/path/to/godot ./run-tests.sh`.

### Releases

Simple release pipeline pubishes with the command: 
```
make dist
```

Produces `fan-manager.zip`, and a release on github.
