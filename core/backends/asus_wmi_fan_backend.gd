extends "res://plugins/fan-manager/core/backends/fan_backend.gd"
class_name AsusWmiFanBackend

## [FanBackend] for ASUS devices using the asus-wmi driver's native
## fan-curve hwmon interface (e.g. ROG Ally). Uploads a full curve
## table once (no polling needed). fan_id format: "<hwmon device
## path>#<channel>".

## Referenced via preload()'d consts, not bare class_name lookups:
## OGUI loads plugins from a zip, so the global class_name cache is
## never populated.
const HardwareId = preload("res://plugins/fan-manager/core/backends/hardware_id.gd")
const PwmIo = preload("res://plugins/fan-manager/core/backends/pwm_io.gd")
const FanCurveUtils = preload("res://plugins/fan-manager/core/persistence/fan_curve_utils.gd")

const HWMON_DIR := "/sys/class/hwmon"
const HWMON_NAME := "asus_custom_fan_curve"
const MAX_HARDWARE_POINTS := 8

## Upper bound on channels to scan for (CPU/GPU/MID fan).
const MAX_FAN_CHANNELS := 3

## pwm<N>_enable values for asus-wmi's fan curve feature. 1 = custom
## curve; 2/3 both hand control back to firmware, 3 also resets the
## driver's cached curve-point registers. We use BIOS = 2 so cached
## curve data is never discarded.
enum AsusPwmEnable { MANUAL = 1, BIOS = 2, RESET_DEFAULT = 3 }

var _discovered_fans: Array[String] = []


func _init() -> void:
	logger = Log.get_logger("AsusWmiFanBackend")


func is_supported() -> bool:
	return not _get_or_discover_fans().is_empty()


func get_hardware_id() -> String:
	var hardware_id := HardwareId.from_dmi()
	if hardware_id == HardwareId.UNKNOWN:
		logger.warn("Unable to read DMI product/board name, using generic hardware id")
	return hardware_id


func list_fans() -> Array[String]:
	return _get_or_discover_fans()


## Returns fan<channel>_label (e.g. "cpu"/"gpu") for fan_id, falling
## back to "Fan <channel>". The label lives on a different hwmon
## device than the curve controls, so it's searched for separately.
func get_fan_label(fan_id: String) -> String:
	var parts := PwmIo.split_channel_fan_id(fan_id)
	var channel: int = parts["channel"]

	var label := PwmIo.read_text("%s/fan%d_label" % [parts["device"], channel]).strip_edges()
	if label.is_empty():
		label = _find_fan_label_across_hwmon(channel)

	if label.is_empty():
		return "Fan %d" % channel
	return label.to_upper()


## Scans every hwmon device for a fan<channel>_label file, returning
## the first match.
func _find_fan_label_across_hwmon(channel: int) -> String:
	var dir := DirAccess.open(HWMON_DIR)
	if not dir:
		return ""

	var label := ""
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not entry.begins_with("."):
			var candidate := "%s/%s/fan%d_label" % [HWMON_DIR, entry, channel]
			var text := PwmIo.read_text(candidate).strip_edges()
			if not text.is_empty():
				label = text
				break
		entry = dir.get_next()
	dir.list_dir_end()

	return label


func requires_software_polling() -> bool:
	return false


## Reads back the curve currently programmed into the hardware's 8
## points for fan_id. Returns {} if any point is unreadable. Not
## guaranteed to be the original factory curve (BIOS mode doesn't
## reset these registers), just whatever's currently cached.
func get_bios_curve(fan_id: String) -> Dictionary:
	var parts := PwmIo.split_channel_fan_id(fan_id)
	var device: String = parts["device"]
	var channel: int = parts["channel"]

	var curve := {}
	for point_index in range(1, MAX_HARDWARE_POINTS + 1):
		var temp_raw := PwmIo.read_text(
			"%s/pwm%d_auto_point%d_temp" % [device, channel, point_index]
		).strip_edges()
		var pwm_raw := PwmIo.read_text(
			"%s/pwm%d_auto_point%d_pwm" % [device, channel, point_index]
		).strip_edges()

		if temp_raw.is_empty() or pwm_raw.is_empty():
			logger.warn(
				"Unable to read existing fan curve points from %s; returning empty curve" % fan_id
			)
			return {}

		# pwm<N>_auto_point*_temp is a plain Celsius integer (u8),
		# unlike the millidegree convention used by hwmon's temp*_input.
		var temp_c := temp_raw.to_int()
		curve[temp_c] = PwmIo.pwm_to_percent(pwm_raw.to_int())

	return curve


## Sets mode ("bios"/"custom") for every discovered fan channel.
func set_mode(mode: String) -> bool:
	var fans := _get_or_discover_fans()
	if fans.is_empty():
		logger.error("Cannot set mode '%s': no fan devices discovered" % mode)
		return false

	var enable_value: int
	match mode:
		"bios":
			enable_value = AsusPwmEnable.BIOS
		"custom":
			enable_value = AsusPwmEnable.MANUAL
		_:
			logger.error("Unknown fan mode '%s'" % mode)
			return false

	var failed_fans: Array[String] = []
	for fan_id in fans:
		var parts := PwmIo.split_channel_fan_id(fan_id)
		var path := "%s/pwm%d_enable" % [parts["device"], parts["channel"]]
		if not _write_text(path, str(enable_value)):
			failed_fans.append(fan_id)

	if not failed_fans.is_empty():
		logger.error("Failed to set mode '%s' for fan(s): %s" % [mode, ", ".join(failed_fans)])
		return false

	return true


## Returns "bios"/"custom"/"" based on the first discovered channel's
## pwm_enable (every channel is kept in sync, so one is representative).
func get_current_mode() -> String:
	var fans := _get_or_discover_fans()
	if fans.is_empty():
		return ""

	var parts := PwmIo.split_channel_fan_id(fans[0])
	var raw := PwmIo.read_text(
		"%s/pwm%d_enable" % [parts["device"], parts["channel"]]
	).strip_edges()
	if raw == str(AsusPwmEnable.MANUAL):
		return "custom"
	if raw == str(AsusPwmEnable.BIOS) or raw == str(AsusPwmEnable.RESET_DEFAULT):
		return "bios"
	return ""


## Validates, clamps, and reduces curve to 8 points, then uploads it
## to fan_id in one shot.
func apply_custom_curve(fan_id: String, curve: Dictionary) -> bool:
	if curve.is_empty():
		logger.warn("Cannot apply an empty custom curve to %s" % fan_id)
		return false

	if not _ensure_manual_mode(fan_id):
		logger.error(
			"Cannot apply custom curve to %s: failed to switch pwm_enable to manual" % fan_id
		)
		return false

	var parts := PwmIo.split_channel_fan_id(fan_id)
	var device: String = parts["device"]
	var channel: int = parts["channel"]

	var validated := _validate_and_clamp(curve)
	var reduced := _reduce_to_hardware_points(validated)
	var points: Array = reduced.keys()
	points.sort()

	for i in points.size():
		var temp: int = points[i]
		var percent: float = reduced[temp]
		var point_index := i + 1
		var pwm_value := PwmIo.percent_to_pwm(percent)

		# Plain Celsius integer, not millidegrees: see get_bios_curve().
		if not _write_text(
			"%s/pwm%d_auto_point%d_temp" % [device, channel, point_index], str(temp)
		):
			return false
		if not _write_text(
			"%s/pwm%d_auto_point%d_pwm" % [device, channel, point_index], str(pwm_value)
		):
			return false

	logger.info("Uploaded %d-point custom fan curve to %s" % [points.size(), fan_id])
	return true


func read_temperature(fan_id: String) -> float:
	var parts := PwmIo.split_channel_fan_id(fan_id)
	var raw := PwmIo.read_text(
		"%s/temp%d_input" % [parts["device"], parts["channel"]]
	).strip_edges()
	if raw.is_empty():
		logger.warn("Unable to read temp%d_input for %s" % [int(parts["channel"]), fan_id])
		return -1.0
	return raw.to_float() / 1000.0


func read_fan_percent(fan_id: String) -> float:
	var parts := PwmIo.split_channel_fan_id(fan_id)
	var raw := PwmIo.read_text("%s/pwm%d" % [parts["device"], parts["channel"]]).strip_edges()
	if raw.is_empty():
		logger.warn("Unable to read pwm%d for %s" % [int(parts["channel"]), fan_id])
		return -1.0
	return PwmIo.pwm_to_percent(raw.to_int())


## Discovers hwmon devices named "asus_custom_fan_curve" and enumerates
## their pwm<N> channels. Cached once found; retried until then (hwmon
## may not be populated yet this early in boot).
func _get_or_discover_fans() -> Array[String]:
	if not _discovered_fans.is_empty():
		return _discovered_fans

	var discovered: Array[String] = []
	var dir := DirAccess.open(HWMON_DIR)
	if not dir:
		logger.warn("Unable to open %s" % HWMON_DIR)
		return discovered

	# Logs every device/name considered, for debugging failed detection.
	var seen: Array[String] = []

	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not entry.begins_with("."):
			var device_path := HWMON_DIR + "/" + entry
			var name := PwmIo.read_text(device_path + "/name").strip_edges()
			seen.append("%s -> '%s'" % [entry, name])
			if name == HWMON_NAME:
				for channel in range(1, MAX_FAN_CHANNELS + 1):
					if FileAccess.file_exists("%s/pwm%d_enable" % [device_path, channel]):
						discovered.append("%s#%d" % [device_path, channel])
		entry = dir.get_next()
	dir.list_dir_end()

	logger.info(
		"Scanned %s: %s (looking for name == '%s')" % [HWMON_DIR, ", ".join(seen), HWMON_NAME]
	)
	if discovered.is_empty():
		logger.warn(
			"No hwmon device named '%s' found; AsusWmiFanBackend will report unsupported" % HWMON_NAME
		)
	else:
		logger.info("Found fans via hwmon %s" % ", ".join(discovered))

	_discovered_fans = discovered
	return _discovered_fans


## Switches fan_id to manual curve control (pwm<N>_enable=1) if not
## already set, since writes are otherwise ignored.
func _ensure_manual_mode(fan_id: String) -> bool:
	var parts := PwmIo.split_channel_fan_id(fan_id)
	var path := "%s/pwm%d_enable" % [parts["device"], parts["channel"]]

	var raw := PwmIo.read_text(path).strip_edges()
	if raw == str(AsusPwmEnable.MANUAL):
		return true

	logger.info("Switching %s to manual fan curve control" % fan_id)
	return _write_text(path, str(AsusPwmEnable.MANUAL))


## Clamps curve values to 0-100% and forces a non-decreasing sweep
## left to right, since the kernel doesn't validate uploaded curves.
func _validate_and_clamp(curve: Dictionary) -> Dictionary:
	var normalized := FanCurveUtils.normalize_keys(curve)
	var points: Array = normalized.keys()
	points.sort()

	var validated := {}
	var running_max := 0.0
	for point in points:
		var value: float = clampf(float(normalized[point]), 0.0, 100.0)
		if value < running_max:
			value = running_max
		running_max = value
		validated[point] = value

	return validated


## Reduces curve to at most MAX_HARDWARE_POINTS entries, keeping the
## hottest points and dropping the coldest.
func _reduce_to_hardware_points(curve: Dictionary) -> Dictionary:
	var points: Array = curve.keys()
	points.sort()

	if points.size() <= MAX_HARDWARE_POINTS:
		return curve

	var kept := points.slice(points.size() - MAX_HARDWARE_POINTS, points.size())

	var reduced := {}
	for point in kept:
		reduced[point] = curve[point]
	return reduced


func _write_text(path: String, text: String) -> bool:
	var wrote := PwmIo.write_text(path, text)
	if wrote and not PwmIo.dry_run:
		logger.debug("Wrote '%s' to %s" % [text, path])
	elif not wrote:
		logger.error("Unable to write to %s (permission denied or missing udev rule?)" % path)
	return wrote
