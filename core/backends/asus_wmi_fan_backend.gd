extends "res://plugins/fan-manager/core/backends/fan_backend.gd"
class_name AsusWmiFanBackend

## ROG Ally and friends — asus-wmi's native fan-curve hwmon interface.
## Uploads the whole table at once, no polling. fan_id is
## "<hwmon path>#<channel>".

const FanCurveUtils = preload("res://plugins/fan-manager/core/persistence/fan_curve_utils.gd")
const PwmChannel = preload("res://plugins/fan-manager/core/models/pwm_channel.gd")
const PwmCurvePath = preload("res://plugins/fan-manager/core/models/pwm_curve_path.gd")
const HWMON_DIR := "/sys/class/hwmon"
const ASUS_WMI_CUSTOM_CURVE_HWMON_NAME := "asus_custom_fan_curve"
const MAX_HARDWARE_POINTS := 8
const MAX_FAN_CHANNELS := 3 # cpu/gpu/mid, upper bound for the scan

enum AsusPwmEnable { MANUAL = 1, BIOS = 2, RESET_DEFAULT = 3 }

var _discovered_fans: Array[String] = []

## fan_id -> PwmChannel, populated by _get_or_discover_fans().
var _channels: Dictionary = {}


func _init() -> void:
	logger = Log.get_logger("FanManager AsusWmiFanBackend")


func get_fan_label(fan_id: String) -> String:
	var channel := _get_channel(fan_id)
	if not channel:
		return "Fan"
	return channel.fan_label


# Try to find fan label if exists in any hwmon
# fallsback to 'Fan <channel_'
func _resolve_fan_label(device_path: String, channel_id: int) -> String:
	var fan_label := PwmIo.read_text("%s/fan%d_label" % [device_path, channel_id]).strip_edges()

	if fan_label.is_empty():
		var hwmon_dir := DirAccess.open(HWMON_DIR)
		if hwmon_dir:
			hwmon_dir.list_dir_begin()
			var hwmon_entry := hwmon_dir.get_next()

			while hwmon_entry != "":
				if not hwmon_entry.begins_with("."):
					var hwmon_fan_label := "%s/%s/fan%d_label" % [HWMON_DIR, hwmon_entry, channel_id]
					var hwmon_fan_label_text := PwmIo.read_text(hwmon_fan_label).strip_edges()
					if not hwmon_fan_label_text.is_empty():
						fan_label = hwmon_fan_label_text
						break
				hwmon_entry = hwmon_dir.get_next()
			hwmon_dir.list_dir_end()

	if fan_label.is_empty():
		logger.debug("could not resolve fan label for %s#%d: using generic 'Fan %d'" % [device_path, channel_id, channel_id])
		return "Fan %d" % channel_id
	return fan_label.to_upper()


func requires_software_polling() -> bool:
	return false


# Not really "the BIOS curve" BIOS mode never resets these
# registers, so this just reads back whatever's cached. Empty dict if
# any point comes back unreadable.
func get_bios_curve(fan_id: String) -> Dictionary:
	var channel := _get_channel(fan_id)
	if not channel:
		return {}

	var curve := {}
	for point in channel.points:
		var point_temp := PwmIo.read_text(point.temp_path).strip_edges()
		var point_pwm := PwmIo.read_text(point.fan_speed_path).strip_edges()

		if point_temp.is_empty() or point_pwm.is_empty():
			logger.warn(
				"Unable to read existing fan curve points from %s; returning empty curve" % fan_id
			)
			return {}

		# Asus pwm<N>_auto_point*_temp is a plain Celsius integer (u8),
		# unlike the millidegree convention used by hwmon's temp*_input.
		var temp_c := point_temp.to_int()
		curve[temp_c] = PwmIo.pwm_to_percent(point_pwm.to_int())

	logger.debug("get_bios_curve(%s) -> %s" % [fan_id, curve])
	return curve


func set_mode(mode: String) -> bool:
	var fans := _get_or_discover_fans()
	if fans.is_empty():
		logger.error("Cannot set mode '%s': no fan devices discovered" % mode)
		return false

	var enable_mode: int
	match mode:
		"bios":
			enable_mode = AsusPwmEnable.BIOS
		"custom":
			enable_mode = AsusPwmEnable.MANUAL
		_:
			logger.error("Unknown fan mode '%s'" % mode)
			return false

	var failed_fans: Array[String] = []
	for fan_id in fans:
		var channel := _get_channel(fan_id)
		if not channel or not _write_text(channel.pwm_enable_path, str(enable_mode)):
			failed_fans.append(fan_id)

	if not failed_fans.is_empty():
		logger.error("Failed to set mode '%s' for fan(s): %s" % [mode, ", ".join(failed_fans)])
		return false

	logger.debug("set_mode('%s'): wrote pwm_enable=%d for fan(s): %s" % [mode, enable_mode, fans])
	return true


# Just checks the first channel — they're always kept in sync, so one
# is as good as all of them.
func get_current_mode() -> String:
	var fans := _get_or_discover_fans()
	if fans.is_empty():
		return ""

	var channel := _get_channel(fans[0])
	if not channel:
		return ""
	var pwm_enable_value := PwmIo.read_text(channel.pwm_enable_path).strip_edges()

	var mode := ""
	if pwm_enable_value == str(AsusPwmEnable.MANUAL):
		mode = "custom"
	elif pwm_enable_value == str(AsusPwmEnable.BIOS) or pwm_enable_value == str(AsusPwmEnable.RESET_DEFAULT):
		mode = "bios"
	logger.debug("get_current_mode(): pwm_enable='%s' (from %s) -> '%s'" % [pwm_enable_value, fans[0], mode])
	return mode


func apply_custom_curve(fan_id: String, curve: Dictionary) -> bool:
	if curve.is_empty():
		logger.warn("Cannot apply an empty custom curve to %s" % fan_id)
		return false

	var channel := _get_channel(fan_id)
	if not channel:
		return false

	var validated := _validate_and_clamp(curve)
	# asus_custom_fan_curve always exposes 8 points per channel (fixed
	# by the driver, confirmed from its kernel source) — no need to
	# pass channel.points.size() here.
	var reduced := _reduce_to_hardware_points(validated)

	var temps: Array = reduced.keys()
	temps.sort()
	for i in temps.size():
		var temp: int = temps[i]
		var pwm_value := PwmIo.percent_to_pwm(reduced[temp])
		var point: PwmCurvePath = channel.points[i]
		# Plain Celsius integer, not millidegrees — see get_bios_curve().
		if not _write_text(point.temp_path, str(temp)):
			return false
		if not _write_text(point.fan_speed_path, str(pwm_value)):
			return false

	if not _write_text(channel.pwm_enable_path, str(AsusPwmEnable.MANUAL)):
		logger.error("Uploaded curve to %s but failed to write pwm_enable to trigger it" % fan_id)
		return false

	logger.info("Uploaded %d-point custom fan curve to %s and triggered pwm_enable" % [reduced.size(), fan_id])
	return true


func read_temperature(fan_id: String) -> float:
	var channel := _get_channel(fan_id)
	if not channel:
		return -1.0
	var pwm_temp := PwmIo.read_text(channel.readonly_temp_sensor_path).strip_edges()
	if pwm_temp.is_empty():
		logger.warn("Unable to read temp%d_input for %s" % [channel.channel_id, fan_id])
		return -1.0
	var celsius := pwm_temp.to_float() / 1000.0
	logger.debug("read_temperature(%s) -> %.1f°C (pwm_temp='%s')" % [fan_id, celsius, pwm_temp])
	return celsius


func read_fan_percent(fan_id: String) -> float:
	var channel := _get_channel(fan_id)
	if not channel:
		return -1.0
	var pwm_fan_speed := PwmIo.read_text(channel.readonly_fan_speed_path).strip_edges()
	if pwm_fan_speed.is_empty():
		logger.warn("Unable to read pwm%d for %s" % [channel.channel_id, fan_id])
		return -1.0
	var percent := PwmIo.pwm_to_percent(pwm_fan_speed.to_int())
	logger.debug("read_fan_percent(%s) -> %.1f%% (pwm_fan_speed='%s')" % [fan_id, percent, pwm_fan_speed])
	return percent


func _get_or_discover_fans() -> Array[String]:
	if not _discovered_fans.is_empty():
		return _discovered_fans

	var hwmon_dir := DirAccess.open(HWMON_DIR)
	if not hwmon_dir:
		logger.warn("Unable to open %s" % HWMON_DIR)
		return _discovered_fans

	var seen: Array[String] = []  # for the warn below, if nothing matches

	hwmon_dir.list_dir_begin()
	var hwmon_entry := hwmon_dir.get_next()
	while hwmon_entry != "":
		if not hwmon_entry.begins_with("."):
			var device_path := HWMON_DIR + "/" + hwmon_entry
			var device_name := PwmIo.read_text(device_path + "/name").strip_edges()
			seen.append("%s -> '%s'" % [hwmon_entry, device_name])
			if device_name == ASUS_WMI_CUSTOM_CURVE_HWMON_NAME:
				for channel_id in range(1, MAX_FAN_CHANNELS + 1):
					if FileAccess.file_exists("%s/pwm%d_enable" % [device_path, channel_id]):
						var fan_channel := _build_channel(device_path, channel_id)
						_channels[fan_channel.fan_id] = fan_channel
						_discovered_fans.append(fan_channel.fan_id)
		hwmon_entry = hwmon_dir.get_next()
	hwmon_dir.list_dir_end()

	if _discovered_fans.is_empty():
		logger.warn("No '%s' hwmon device found (saw: %s)" % [ASUS_WMI_CUSTOM_CURVE_HWMON_NAME, ", ".join(seen)])
	else:
		logger.info("Found fans via hwmon: %s" % ", ".join(_discovered_fans))

	return _discovered_fans


func _build_channel(device_path: String, channel_id: int) -> PwmChannel:
	var fan_channel := PwmChannel.new()
	fan_channel.hwmon_path = device_path
	fan_channel.channel_id = channel_id
	fan_channel.fan_id = "%s#%d" % [device_path, channel_id]
	fan_channel.pwm_enable_path = "%s/pwm%d_enable" % [device_path, channel_id]
	fan_channel.readonly_temp_sensor_path = "%s/temp%d_input" % [device_path, channel_id]
	fan_channel.readonly_fan_speed_path = "%s/pwm%d" % [device_path, channel_id]
	fan_channel.fan_label = _resolve_fan_label(device_path, channel_id)

	var points: Array[PwmCurvePath] = []
	for point_index in range(1, MAX_HARDWARE_POINTS + 1):
		var temp_path := "%s/pwm%d_auto_point%d_temp" % [device_path, channel_id, point_index]
		var fan_speed_path := "%s/pwm%d_auto_point%d_pwm" % [device_path, channel_id, point_index]
		if not PwmIo.path_exists(temp_path) or not PwmIo.path_exists(fan_speed_path):
			logger.debug(
				"%s#%d: pwm_auto_point%d missing, stopping at %d point(s)"
				% [device_path, channel_id, point_index, points.size()]
			)
			break
		var pwm_curve_path := PwmCurvePath.new()
		pwm_curve_path.temp_path = temp_path
		pwm_curve_path.fan_speed_path = fan_speed_path
		points.append(pwm_curve_path)
	fan_channel.points = points

	return fan_channel


func _get_channel(fan_id: String) -> PwmChannel:
	if _channels.is_empty():
		_get_or_discover_fans()
	var channel: PwmChannel = _channels.get(fan_id)
	if not channel:
		logger.warn("No discovered channel for fan_id '%s'" % fan_id)
	return channel


# Normalize curve values and force non-decreasing coldest to hottest.
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


# Keeps the hottest points, drops the coldest.
func _reduce_to_hardware_points(curve: Dictionary) -> Dictionary:
	var points: Array = curve.keys()
	points.sort()

	if points.size() <= MAX_HARDWARE_POINTS:
		return curve

	var kept := points.slice(points.size() - MAX_HARDWARE_POINTS, points.size())

	var reduced_curve := {}
	for point in kept:
		reduced_curve[point] = curve[point]
	return reduced_curve
