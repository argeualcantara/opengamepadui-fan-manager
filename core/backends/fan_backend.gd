@abstract
extends RefCounted
class_name FanBackend

## Base class for fan control backends: one implementation per family
## of hardware (e.g. generic hwmon, or a vendor-specific EC). Register
## new backends with [FanBackendRegistry].

var logger := Log.get_logger("FanManager FanBackend")


## Returns true if this backend can control the current hardware.
func is_supported() -> bool:
	return false


## Returns a stable id for the detected hardware, used as the
## persistence key for saved fan curves (e.g. DMI product/board name).
func get_hardware_id() -> String:
	return ""


## Returns the ids of the controllable fans on this hardware. May
## return more than one; callers must not assume size() == 1.
func list_fans() -> Array[String]:
	return []


## Human-readable label for fan_id (e.g. "CPU", "GPU"). Falls back to
## a generic name when the backend has no better one.
func get_fan_label(_fan_id: String) -> String:
	return "Fan"


## Returns the BIOS/firmware fan curve for fan_id, as {temperature °C:
## speed % (int, 0-100)}. Used to seed the custom curve editor when no
## saved profile exists yet.
func get_bios_curve(_fan_id: String) -> Dictionary:
	return {}


## Switches the backend into mode ("bios" or "custom"). Returns false
## if unsupported or the switch failed.
func set_mode(_mode: String) -> bool:
	return false


## Returns the mode ("bios"/"custom") the hardware is currently
## configured for, without writing anything. Returns "" if unknown.
func get_current_mode() -> String:
	return ""


## Applies curve ({temperature: speed %}) to fan_id. Temperature keys
## may be int or numeric String (JSON persistence uses string keys);
## implementations must tolerate both.
func apply_custom_curve(_fan_id: String, _curve: Dictionary) -> bool:
	return false


## Reads the current temperature (°C) for fan_id's sensor. Returns a
## negative value on read failure.
func read_temperature(_fan_id: String) -> float:
	return -1.0


## Reads the current fan speed (0-100%) for fan_id. Returns a negative
## value on read failure.
func read_fan_percent(_fan_id: String) -> float:
	return -1.0


## Returns true if CustomCurveEngine must keep polling and re-writing
## the target speed for this backend, vs. uploading a whole curve
## table once and letting the hardware follow it on its own. Defaults
## to true.
func requires_software_polling() -> bool:
	return true
