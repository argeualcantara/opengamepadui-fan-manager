extends "res://plugins/fan-manager/core/backends/fan_backend.gd"
class_name HwmonFanBackend

## Generic [FanBackend] fallback based on the Linux [code]hwmon[/code]
## sysfs interface (/sys/class/hwmon). Used when no hardware-specific
## backend recognizes the current device.
##
## Assumes a single controllable fan exposed as [code]pwm1[/code] with a
## paired [code]temp1_input[/code] sensor, which covers most handhelds
## and desktop motherboards. Fan IDs returned by this backend are the
## hwmon device directory path (e.g. "/sys/class/hwmon/hwmon3").
##
## Cross-file plugin types below are referenced via preload()'d consts,
## not bare class_name lookups: OGUI loads plugins from a zip at
## runtime (ProjectSettings.load_resource_pack()), which never
## populates Godot's global class_name cache, so bare names like
## `HardwareId` fail to resolve outside the file that declares them.
## See tasks/17-fix-class-name-resolution-em-plugin-empacotado.md.
const HardwareId = preload("res://plugins/fan-manager/core/backends/hardware_id.gd")
const PwmIo = preload("res://plugins/fan-manager/core/backends/pwm_io.gd")
const FanCurveUtils = preload("res://plugins/fan-manager/core/persistence/fan_curve_utils.gd")

const HWMON_DIR := "/sys/class/hwmon"

## pwm1_enable values, per the Linux hwmon sysfs-interface documentation.
enum PwmEnable { MANUAL = 1, AUTOMATIC = 2 }

var _discovered_fans: Array[String] = []
var _last_written_pwm: Dictionary = {}


func _init() -> void:
	logger = Log.get_logger("HwmonFanBackend")


func is_supported() -> bool:
	return not _get_or_discover_fans().is_empty()


func get_hardware_id() -> String:
	var hardware_id := HardwareId.from_dmi()
	if hardware_id == HardwareId.UNKNOWN:
		logger.warn("Unable to read DMI product/board name, using generic hardware id")
	return hardware_id


func list_fans() -> Array[String]:
	return _get_or_discover_fans()


func get_bios_curve(_fan_id: String) -> Dictionary:
	logger.warn(
		"Generic hwmon backend cannot read a BIOS fan curve table; returning empty curve"
	)
	return {}


func supports_os_mode() -> bool:
	return false


func set_mode(mode: String) -> bool:
	var fans := _get_or_discover_fans()
	if fans.is_empty():
		logger.error("Cannot set mode '%s': no fan devices discovered" % mode)
		return false

	var enable_value: int
	match mode:
		"bios":
			enable_value = PwmEnable.AUTOMATIC
		"custom":
			enable_value = PwmEnable.MANUAL
		"os":
			logger.warn("Generic hwmon backend does not support OS mode")
			return false
		_:
			logger.error("Unknown fan mode '%s'" % mode)
			return false

	var failed_fans: Array[String] = []
	for fan_id in fans:
		if not _write_text(fan_id + "/pwm1_enable", str(enable_value)):
			failed_fans.append(fan_id)

	if not failed_fans.is_empty():
		logger.error("Failed to set mode '%s' for fan(s): %s" % [mode, ", ".join(failed_fans)])
		return false

	return true


func get_current_mode() -> String:
	var fans := _get_or_discover_fans()
	if fans.is_empty():
		return ""

	var raw := PwmIo.read_text(fans[0] + "/pwm1_enable").strip_edges()
	if raw == str(PwmEnable.MANUAL):
		return "custom"
	if raw == str(PwmEnable.AUTOMATIC):
		return "bios"
	return ""


func apply_custom_curve(fan_id: String, curve: Dictionary) -> bool:
	if curve.is_empty():
		logger.warn("Cannot apply an empty custom curve to %s" % fan_id)
		return false

	if not _ensure_manual_mode(fan_id):
		logger.error(
			"Cannot apply custom curve to %s: failed to switch pwm1_enable to manual" % fan_id
		)
		return false

	var temperature := read_temperature(fan_id)
	if temperature < 0.0:
		logger.error("Cannot apply custom curve to %s: temperature read failed" % fan_id)
		return false

	var percent := _interpolate_curve(curve, temperature)
	var pwm_value := _percent_to_pwm(percent)

	# Skip the write (and the log line) if the target hasn't changed
	# since last time: this runs every poll tick (default 2s), so
	# without this check both the hardware write and the log would
	# repeat forever even when nothing actually changed.
	if _last_written_pwm.get(fan_id) == pwm_value:
		return true

	var wrote := _write_text(fan_id + "/pwm1", str(pwm_value))
	if wrote:
		_last_written_pwm[fan_id] = pwm_value
		logger.debug(
			"Applied curve to %s: %.1f°C -> %d%% (pwm=%d)" % [fan_id, temperature, percent, pwm_value]
		)
	return wrote


func read_temperature(fan_id: String) -> float:
	var raw := _read_text(fan_id + "/temp1_input").strip_edges()
	if raw.is_empty():
		logger.warn("Unable to read temp1_input for %s" % fan_id)
		return -1.0
	return raw.to_float() / 1000.0


func read_fan_percent(fan_id: String) -> float:
	var raw := _read_text(fan_id + "/pwm1").strip_edges()
	if raw.is_empty():
		logger.warn("Unable to read pwm1 for %s" % fan_id)
		return -1.0
	return _pwm_to_percent(raw.to_int())


## Discovers hwmon devices exposing both pwm1 and temp1_input. Cached
## once a non-empty result is found; retried on every call until then,
## since hwmon may not be fully populated yet this early in boot.
func _get_or_discover_fans() -> Array[String]:
	if not _discovered_fans.is_empty():
		return _discovered_fans

	var discovered: Array[String] = []
	var dir := DirAccess.open(HWMON_DIR)
	if not dir:
		logger.warn("Unable to open %s" % HWMON_DIR)
		return discovered

	# Diagnostic: log every hwmon device considered, so a failed
	# detection is debuggable from a log alone instead of a bare "no
	# backend supports this hardware" with nothing to act on.
	var seen: Array[String] = []

	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not entry.begins_with("."):
			var device_path := HWMON_DIR + "/" + entry
			var has_pwm1 := FileAccess.file_exists(device_path + "/pwm1")
			var has_temp1 := FileAccess.file_exists(device_path + "/temp1_input")
			seen.append("%s (pwm1=%s temp1_input=%s)" % [entry, has_pwm1, has_temp1])
			if has_pwm1 and has_temp1:
				discovered.append(device_path)
		entry = dir.get_next()
	dir.list_dir_end()

	logger.info("Scanned %s: %s" % [HWMON_DIR, ", ".join(seen)])
	if discovered.is_empty():
		logger.warn("No hwmon device exposing both pwm1 and temp1_input found")

	_discovered_fans = discovered
	return _discovered_fans


## Ensures the given fan's pwm is under manual control (pwm1_enable=1)
## before a custom value is written to it. Without this, drivers that
## are still in automatic mode (2) silently discard direct pwm writes
## on their next update tick, making apply_custom_curve() a no-op.
func _ensure_manual_mode(fan_id: String) -> bool:
	var raw := _read_text(fan_id + "/pwm1_enable").strip_edges()
	if raw == str(PwmEnable.MANUAL):
		return true

	logger.info("Switching %s to manual pwm control before applying custom curve" % fan_id)
	return _write_text(fan_id + "/pwm1_enable", str(PwmEnable.MANUAL))


func _interpolate_curve(curve: Dictionary, temperature: float) -> float:
	return FanCurveUtils.interpolate_value(curve, temperature)


func _percent_to_pwm(percent: float) -> int:
	return PwmIo.percent_to_pwm(percent)


func _pwm_to_percent(pwm_value: int) -> float:
	return PwmIo.pwm_to_percent(pwm_value)


func _read_text(path: String) -> String:
	return PwmIo.read_text(path)


func _write_text(path: String, text: String) -> bool:
	var wrote := PwmIo.write_text(path, text)
	if wrote and not PwmIo.dry_run:
		logger.debug("Wrote '%s' to %s" % [text, path])
	elif not wrote:
		logger.error("Unable to write to %s (permission denied or missing udev rule?)" % path)
	return wrote
