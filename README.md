# Fan Manager

An [OpenGamepadUI](https://github.com/ShadowBlip/OpenGamepadUI) plugin for
monitoring and controlling system fan curves.

# Warning

This is still under development, USE AT YOUR OWN RISK!

## Development

Clone this repository next to `OpenGamepadUI`:

```
shadowblip/
├── OpenGamepadUI
└── fan-manager-ogui
```

Then, from this directory:

```
make build
```

This symlinks the plugin into `OpenGamepadUI/plugins/fan-manager`. From
the `OpenGamepadUI` directory, run `make edit` to open the project in the
Godot editor with the plugin loaded.

## Testing on real hardware

`PwmIo.dry_run` (`core/backends/pwm_io.gd`) defaults to `true`: every
sysfs write any backend would make (`pwm1_enable`, `pwm1_auto_point*`,
etc.) is logged instead: exact path and exact value, one line per
attribute: and nothing is actually written to the fan hardware. This
is the single choke point both `HwmonFanBackend` and
`AsusWmiFanBackend` write through, so nothing on real hardware can be
mutated while it's `true`. Reads are unaffected (mode detection,
adopting the hardware's current curve, etc. all still work normally).

Set `PwmIo.dry_run = false` in code only once you've reviewed the
`[DRY RUN] would write '...' to ...` log lines for a session and
they look correct.

## Packaging

```
make dist
```

Produces `fan-manager.zip`, which can be dropped into
`~/.local/share/opengamepadui/plugins`.
