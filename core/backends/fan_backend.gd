@abstract
extends RefCounted
class_name FanBackend

# base class for fan backends, one per hardware family (generic hwmon,
# vendor EC, etc). register new ones with FanBackendRegistry.
#
# is_supported/get_hardware_id/list_fans/_write_text live here since they
# were identical between AsusWmiFanBackend and HwmonFanBackend, everything
# else is different enough per backend to override.

const HardwareId = preload("res://plugins/fan-manager/core/utils/hardware_id.gd")
const PwmIo = preload("res://plugins/fan-manager/core/utils/pwm_io.gd")

var logger := Log.get_logger("FanManager FanBackend")


func is_supported() -> bool:
	var fans = _get_or_discover_fans()
	var supported := not fans.is_empty()
	logger.debug("is_supported() -> %s" % supported)
	return supported


func get_hardware_id() -> String:
	var hardware_id := HardwareId.from_dmi()
	if hardware_id == HardwareId.UNKNOWN:
		logger.warn("Unable to read DMI product/board name, using generic hardware id")
	return hardware_id


func list_fans() -> Array[String]:
	var fans := _get_or_discover_fans()
	logger.debug("list_fans() -> %s" % [fans])
	return fans


func get_fan_label(_fan_id: String) -> String:
	return "Fan"


func get_bios_curve(_fan_id: String) -> Dictionary:
	return {}


func set_mode(_mode: String) -> bool:
	return false


func get_current_mode() -> String:
	return ""


func apply_custom_curve(_fan_id: String, _curve: Dictionary) -> bool:
	return false


func read_temperature(_fan_id: String) -> float:
	return -1.0


func read_fan_percent(_fan_id: String) -> float:
	return -1.0


# true if the engine has to keep polling/rewriting the target speed, vs
# uploading a curve table once and letting the hardware run it on its own
func requires_software_polling() -> bool:
	return true


func _get_or_discover_fans() -> Array[String]:
	return []


func _write_text(path: String, text: String) -> bool:
	var wrote := PwmIo.write_text(path, text)
	if wrote and not PwmIo.dry_run:
		logger.debug("Wrote '%s' to %s" % [text, path])
	elif not wrote:
		logger.error("Unable to write to %s (permission denied or missing udev rule?)" % path)
	return wrote
