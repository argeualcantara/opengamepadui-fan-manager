@abstract
extends RefCounted
class_name FanBackend

## Base class for fan control backends.
##
## A FanBackend implements fan detection and control for one specific
## family of hardware (e.g. a generic hwmon device, or a vendor-specific
## embedded controller). New hardware support is added by implementing
## this interface and registering the backend with [FanBackendRegistry]:
## no changes to the UI or persistence layer should be required.

var logger := Log.get_logger("FanBackend")


## Returns true if this backend recognizes and can control the current
## hardware. Called by [FanBackendRegistry] during detection.
func is_supported() -> bool:
	return false


## Returns a stable identifier for the detected hardware, used as the
## persistence key for saved fan curves. Must remain stable across
## reboots (e.g. derived from DMI product/board name, not hwmon index).
func get_hardware_id() -> String:
	return ""


## Returns the IDs of the controllable fans/devices found on this
## hardware. May return more than one (REQUIREMENTS.md §5: v1 assumed
## a single fan per device; tasks/14-suporte-multiplas-fans.md lifted
## that for backends that genuinely have more than one, e.g. a ROG
## Ally's separate CPU/GPU fan channels). Callers must not assume
## `size() == 1`.
func list_fans() -> Array[String]:
	return []


## Human-readable label for the given fan_id (e.g. "CPU", "GPU"), used
## by the UI's per-fan tabs when a backend reports more than one fan.
## Falls back to a generic name when the backend has no better one.
func get_fan_label(_fan_id: String) -> String:
	return "Fan"


## Returns the fan curve currently configured by the BIOS/firmware for
## the given fan, as a Dictionary mapping temperature (°C) to fan speed
## (int, 0-100%). Used to seed the custom curve editor the first time a
## user enters Custom Mode without a saved profile.
func get_bios_curve(_fan_id: String) -> Dictionary:
	return {}


## Returns true if this hardware exposes a fan curve controlled by the
## operating system, distinct from BIOS and custom modes.
func supports_os_mode() -> bool:
	return false


## Switches the backend into the given mode ("bios", "os", or "custom").
## Returns false if the mode is not supported or the switch failed.
func set_mode(_mode: String) -> bool:
	return false


## Reads which mode the hardware is *currently* configured for
## ("bios"/"os"/"custom"), without writing anything. Returns "" if it
## can't be determined. Used on a genuinely first run (no persisted
## active_mode yet) to adopt whatever the hardware/BIOS already had
## configured instead of overwriting it with an assumed default.
func get_current_mode() -> String:
	return ""


## Applies a custom fan curve to the given fan. The curve maps
## temperature (°C) to fan speed (int, 0-100%). Temperature keys may be
## int or numeric String: the latter is what a curve loaded straight
## from JSON persistence (REQUIREMENTS.md §3) will contain, since JSON
## object keys are always strings. Implementations must tolerate both.
func apply_custom_curve(_fan_id: String, _curve: Dictionary) -> bool:
	return false


## Reads the current temperature (°C) for the given fan's sensor.
## Returns a negative value on read failure.
func read_temperature(_fan_id: String) -> float:
	return -1.0


## Reads the current fan speed (0-100%) for the given fan.
## Returns a negative value on read failure.
func read_fan_percent(_fan_id: String) -> float:
	return -1.0


## Returns true if applying a custom curve requires CustomCurveEngine to
## keep polling temperature and re-writing the target speed in
## software. Most hwmon interfaces only accept one instantaneous
## duty-cycle value, so this defaults to true. Backends that can upload
## a whole curve table into hardware (e.g. a vendor EC that follows the
## curve on its own once written) should override this to false: the
## engine still attaches and applies every edit through this backend
## (it's always the source of truth for the working curve), it just
## skips the steady-state re-poll timer, since the hardware reacts to
## temperature changes on its own.
func requires_software_polling() -> bool:
	return true
