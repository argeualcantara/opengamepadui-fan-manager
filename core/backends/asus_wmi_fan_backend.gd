extends "res://plugins/fan-manager/core/backends/fan_backend.gd"
class_name AsusWmiFanBackend

## [FanBackend] for ASUS devices using the asus-wmi driver's native
## fan-curve hwmon interface (e.g. ROG Ally). Uploads a full curve
## table once (no polling needed). fan_id format: "<hwmon device
## path>#<channel>".

const FanCurveUtils = preload("res://plugins/fan-manager/core/persistence/fan_curve_utils.gd")
const PwmChannel = preload("res://plugins/fan-manager/core/models/pwm_channel.gd")
const PwmCurvePath = preload("res://plugins/fan-manager/core/models/pwm_curve_path.gd")
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

## fan_id -> PwmChannel, populated by _get_or_discover_fans().
var _channels: Dictionary = {}


func _init() -> void:
	logger = Log.get_logger("FanManager AsusWmiFanBackend")


## Returns this channel's label, resolved once at discovery time (see
## _resolve_fan_label()) instead of re-scanning hwmon on every call.
func get_fan_label(fan_id: String) -> String:
	var ch := _get_channel(fan_id)
	if not ch:
		return "Fan"
	return ch.fan_label


## Reads fan<channel>_label (e.g. "cpu"/"gpu") for device_path/channel,
## falling back to "Fan <channel>". The label lives on a different
## hwmon device than the curve controls, so it's searched for
## separately via _find_fan_label_across_hwmon() when not found
## directly on device_path.
func _resolve_fan_label(device_path: String, channel: int) -> String:
	var label := PwmIo.read_text("%s/fan%d_label" % [device_path, channel]).strip_edges()
	if label.is_empty():
		label = _find_fan_label_across_hwmon(channel)

	if label.is_empty():
		logger.debug(
			"_resolve_fan_label(%s#%d): no label found, using generic 'Fan %d'"
			% [device_path, channel, channel]
		)
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
	var ch := _get_channel(fan_id)
	if not ch:
		return {}

	var curve := {}
	for point in ch.points:
		var temp_raw := PwmIo.read_text(point.temp_path).strip_edges()
		var pwm_raw := PwmIo.read_text(point.fan_speed_path).strip_edges()

		if temp_raw.is_empty() or pwm_raw.is_empty():
			logger.warn(
				"Unable to read existing fan curve points from %s; returning empty curve" % fan_id
			)
			return {}

		# pwm<N>_auto_point*_temp is a plain Celsius integer (u8),
		# unlike the millidegree convention used by hwmon's temp*_input.
		var temp_c := temp_raw.to_int()
		curve[temp_c] = PwmIo.pwm_to_percent(pwm_raw.to_int())

	logger.debug("get_bios_curve(%s) -> %s" % [fan_id, curve])
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

	if not _write_mode_to_fans(mode, enable_value, fans):
		return false
	logger.debug("set_mode('%s') succeeded for all %d fan(s)" % [mode, fans.size()])

	return true


func _write_mode_to_fans(mode: String, enable_value: int, fans: Array[String]) -> bool:
	logger.debug("set_mode('%s'): writing pwm_enable=%d to %s" % [mode, enable_value, fans])

	var failed_fans: Array[String] = []
	for fan_id in fans:
		var ch := _get_channel(fan_id)
		if not ch or not _write_text(ch.enable_path, str(enable_value)):
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

	var ch := _get_channel(fans[0])
	if not ch:
		return ""
	var raw := PwmIo.read_text(ch.enable_path).strip_edges()

	var mode := ""
	if raw == str(AsusPwmEnable.MANUAL):
		mode = "custom"
	elif raw == str(AsusPwmEnable.BIOS) or raw == str(AsusPwmEnable.RESET_DEFAULT):
		mode = "bios"
	logger.debug("get_current_mode(): pwm_enable='%s' (from %s) -> '%s'" % [raw, fans[0], mode])
	return mode


## Validates, clamps, and reduces curve to 8 points, uploads it to
## fan_id, then writes pwm<N>_enable=1 unconditionally. The kernel
## driver (fan_curve_enable_store() in asus-wmi.c) only pushes its
## internally cached curve points to the EC when pwm_enable=1 is
## written; writing curve points alone just updates that cache and
## marks it dirty, so pwm_enable must be (re)written after every point
## upload, even if it was already 1, or the new points never reach the
## EC.
func apply_custom_curve(fan_id: String, curve: Dictionary) -> bool:
	if curve.is_empty():
		logger.warn("Cannot apply an empty custom curve to %s" % fan_id)
		return false

	var ch := _get_channel(fan_id)
	if not ch:
		return false

	var validated := _validate_and_clamp(curve)
	# Reduces to this channel's actual point count, not the
	# MAX_HARDWARE_POINTS constant: _build_channel() may have found
	# fewer than 8 real pwm_auto_point<N> files on some hardware, and
	# indexing ch.points[i] below would go out of bounds otherwise.
	var reduced := _reduce_to_hardware_points(validated, ch.points.size())

	if not _upload_points(fan_id, ch, reduced):
		return false

	if not _write_text(ch.enable_path, str(AsusPwmEnable.MANUAL)):
		logger.error("Uploaded curve to %s but failed to write pwm_enable to trigger it" % fan_id)
		return false

	logger.info("Uploaded %d-point custom fan curve to %s and triggered pwm_enable" % [reduced.size(), fan_id])
	return true


func _upload_points(fan_id: String, ch: PwmChannel, reduced: Dictionary) -> bool:
	var temps: Array = reduced.keys()
	temps.sort()
	logger.debug("apply_custom_curve(%s): uploading points %s" % [fan_id, reduced])

	for i in temps.size():
		var temp: int = temps[i]
		var percent: float = reduced[temp]
		var pwm_value := PwmIo.percent_to_pwm(percent)
		var point: PwmCurvePath = ch.points[i]

		# Plain Celsius integer, not millidegrees: see get_bios_curve().
		if not _write_text(point.temp_path, str(temp)):
			return false
		if not _write_text(point.fan_speed_path, str(pwm_value)):
			return false

	return true


func read_temperature(fan_id: String) -> float:
	var ch := _get_channel(fan_id)
	if not ch:
		return -1.0
	var raw := PwmIo.read_text(ch.temp_sensor_path).strip_edges()
	if raw.is_empty():
		logger.warn("Unable to read temp%d_input for %s" % [ch.channel_id, fan_id])
		return -1.0
	var celsius := raw.to_float() / 1000.0
	logger.debug("read_temperature(%s) -> %.1f°C (raw='%s')" % [fan_id, celsius, raw])
	return celsius


func read_fan_percent(fan_id: String) -> float:
	var ch := _get_channel(fan_id)
	if not ch:
		return -1.0
	var raw := PwmIo.read_text(ch.fan_speed_readback_path).strip_edges()
	if raw.is_empty():
		logger.warn("Unable to read pwm%d for %s" % [ch.channel_id, fan_id])
		return -1.0
	var percent := PwmIo.pwm_to_percent(raw.to_int())
	logger.debug("read_fan_percent(%s) -> %.1f%% (raw='%s')" % [fan_id, percent, raw])
	return percent


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
				logger.debug("hwmon found %s in %s" % [HWMON_NAME, HWMON_DIR])
				for channel in range(1, MAX_FAN_CHANNELS + 1):
					var pwm_path_channel = "%s/pwm%d_enable" % [device_path, channel]
					logger.debug("checking PWM_ENABLE_PATH -> %s" % pwm_path_channel)
					if FileAccess.file_exists(pwm_path_channel):
						var ch := _build_channel(device_path, channel)
						_channels[ch.fan_id] = ch
						discovered.append(ch.fan_id)
		entry = dir.get_next()
	dir.list_dir_end()

	logger.info(
		"Scanned %s: %s" % [HWMON_DIR, ", ".join(seen)]
	)
	if discovered.is_empty():
		logger.warn(
			"No hwmon device named '%s' found; AsusWmiFanBackend will report unsupported" % HWMON_NAME
		)
	else:
		logger.info("Found fans via hwmon %s" % ", ".join(discovered))

	_discovered_fans = discovered
	return _discovered_fans


## Builds a PwmChannel for device_path/channel, with all 8 hardware
## curve points and the fan label resolved up front. fan_id always
## uses the "<device>#<channel>
func _build_channel(device_path: String, channel: int) -> PwmChannel:
	var ch := PwmChannel.new()
	ch.hwmon_path = device_path
	ch.channel_id = channel
	ch.fan_id = "%s#%d" % [device_path, channel]
	ch.enable_path = "%s/pwm%d_enable" % [device_path, channel]
	ch.temp_sensor_path = "%s/temp%d_input" % [device_path, channel]
	ch.fan_speed_readback_path = "%s/pwm%d" % [device_path, channel]
	ch.fan_label = _resolve_fan_label(device_path, channel)

	# Stops at the first missing point, same assumption
	# HwmonFanBackend._find_channel_ids() makes for
	# pwm<N>_enable/temp<N>_input: these are sequential hardware
	# registers.
	var points: Array[PwmCurvePath] = []
	for point_index in range(1, MAX_HARDWARE_POINTS + 1):
		var temp_path := "%s/pwm%d_auto_point%d_temp" % [device_path, channel, point_index]
		var fan_speed_path := "%s/pwm%d_auto_point%d_pwm" % [device_path, channel, point_index]
		if not PwmIo.path_exists(temp_path) or not PwmIo.path_exists(fan_speed_path):
			logger.debug(
				"%s#%d: pwm_auto_point%d missing, stopping at %d point(s)"
				% [device_path, channel, point_index, points.size()]
			)
			break
		var point := PwmCurvePath.new()
		point.temp_path = temp_path
		point.fan_speed_path = fan_speed_path
		points.append(point)
	ch.points = points

	return ch


## Looks up the PwmChannel for fan_id, populating _channels first if
## discovery hasn't run yet. Logs and returns null for an unknown
## fan_id (e.g. a stale one from an old saved profile, no longer among
## the currently discovered channels) instead of letting callers
## dereference null.
func _get_channel(fan_id: String) -> PwmChannel:
	if _channels.is_empty():
		_get_or_discover_fans()
	var ch: PwmChannel = _channels.get(fan_id)
	if not ch:
		logger.warn("No discovered channel for fan_id '%s'" % fan_id)
	return ch


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


## Reduces curve to at most max_points entries (defaults to
## MAX_HARDWARE_POINTS; callers with a specific channel should pass
## its actual ch.points.size(), which can be lower on hardware that
## doesn't expose all 8 pwm_auto_point<N> files), keeping the hottest
## points and dropping the coldest.
func _reduce_to_hardware_points(curve: Dictionary, max_points: int = MAX_HARDWARE_POINTS) -> Dictionary:
	var points: Array = curve.keys()
	points.sort()

	if points.size() <= max_points:
		return curve

	var kept := points.slice(points.size() - max_points, points.size())

	var reduced := {}
	for point in kept:
		reduced[point] = curve[point]
	return reduced
