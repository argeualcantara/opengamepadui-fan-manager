extends "res://plugins/fan-manager/core/backends/fan_backend.gd"
class_name HwmonFanBackend

## Generic [FanBackend] fallback based on the Linux hwmon sysfs
## interface (/sys/class/hwmon), used when no hardware-specific backend
## recognizes the device. Single-fan devices use the bare hwmon device
## path as fan_id; devices with matched pwm<N>/temp<N>_input pairs (e.g.
## CPU+GPU handhelds) split into "<device path>#<channel>" fan_ids,
## see _resolve_fan_channels().
##

const FanCurveUtils = preload("res://plugins/fan-manager/core/persistence/fan_curve_utils.gd")
const PwmChannel = preload("res://plugins/fan-manager/core/models/pwm_channel.gd")
const PwmCurvePath = preload("res://plugins/fan-manager/core/models/pwm_curve_path.gd")
const HWMON_DIR := "/sys/class/hwmon"
## Upper bound on channels to scan for.
const MAX_FAN_CHANNELS := 4

## pwm1_enable values, per the Linux hwmon sysfs-interface documentation.
enum PwmEnable { MANUAL = 1, AUTOMATIC = 2 }

var _discovered_fans: Array[String] = []
var _last_written_pwm: Dictionary = {}

## fan_id -> PwmChannel, populated by _get_or_discover_fans().
var _channels: Dictionary = {}


func _init() -> void:
	logger = Log.get_logger("FanManager HwmonFanBackend")


func get_bios_curve(_fan_id: String) -> Dictionary:
	logger.warn(
		"Generic hwmon backend cannot read a BIOS fan curve table; returning empty curve"
	)
	return {}


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
		_:
			logger.error("Unknown fan mode '%s'" % mode)
			return false

	logger.debug("set_mode('%s'): writing pwm_enable=%d to %s" % [mode, enable_value, fans])

	var failed_fans: Array[String] = []
	for fan_id in fans:
		var ch := _get_channel(fan_id)
		if not ch or not _write_text(ch.enable_path, str(enable_value)):
			failed_fans.append(fan_id)

	if not failed_fans.is_empty():
		logger.error("Failed to set mode '%s' for fan(s): %s" % [mode, ", ".join(failed_fans)])
		return false

	logger.debug("set_mode('%s') succeeded for all %d fan(s)" % [mode, fans.size()])
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
	if raw == str(PwmEnable.MANUAL):
		mode = "custom"
	elif raw == str(PwmEnable.AUTOMATIC):
		mode = "bios"
	logger.debug("get_current_mode(): pwm_enable='%s' (from %s) -> '%s'" % [raw, fans[0], mode])
	return mode


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
	logger.debug(
		"apply_custom_curve(%s): temp=%.1f°C -> %.1f%% -> pwm=%d" % [fan_id, temperature, percent, pwm_value]
	)

	# Skip if the target hasn't changed since last time (runs every poll tick).
	if _last_written_pwm.get(fan_id) == pwm_value:
		logger.debug(
			"apply_custom_curve(%s): pwm=%d unchanged since last write, skipping" % [fan_id, pwm_value]
		)
		return true

	var ch := _get_channel(fan_id)
	if not ch:
		return false
	var wrote := _write_text(ch.points[0].fan_speed_path, str(pwm_value))
	if wrote:
		_last_written_pwm[fan_id] = pwm_value
		logger.debug(
			"Applied curve to %s: %.1f°C -> %d%% (pwm=%d)" % [fan_id, temperature, percent, pwm_value]
		)
	return wrote


func read_temperature(fan_id: String) -> float:
	var ch := _get_channel(fan_id)
	if not ch:
		return -1.0
	var raw := _read_text(ch.temp_sensor_path).strip_edges()
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
	var raw := _read_text(ch.fan_speed_readback_path).strip_edges()
	if raw.is_empty():
		logger.warn("Unable to read pwm%d for %s" % [ch.channel_id, fan_id])
		return -1.0
	var percent := _pwm_to_percent(raw.to_int())
	logger.debug("read_fan_percent(%s) -> %.1f%% (raw='%s')" % [fan_id, percent, raw])
	return percent


## Discovers hwmon devices exposing at least a matched pwm1/temp1_input
## pair (see _resolve_fan_channels() for the multi-fan split), where
## both pwm<N>_enable and pwm<N> are actually writable (see
## _writable_channels()),  a channel that merely exists but can't be
## written to isn't controllable, and reporting it as supported would
## only surface as a failure later, at set_mode()/apply_custom_curve()
## time. Cached once found; retried until then (hwmon may not be
## populated yet this early in boot).
func _get_or_discover_fans() -> Array[String]:
	if not _discovered_fans.is_empty():
		return _discovered_fans

	logger.debug("Discovering fans under %s" % HWMON_DIR)

	var discovered: Array[String] = []
	var dir := DirAccess.open(HWMON_DIR)
	if not dir:
		logger.warn("Unable to open %s" % HWMON_DIR)
		return discovered

	# Logs every device considered, for debugging failed detection.
	var seen: Array[String] = []

	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not entry.begins_with("."):
			var device_path := HWMON_DIR + "/" + entry
			var pwm_channels := _find_channel_ids(device_path, "pwm%d_enable")
			var temp_channels := _find_channel_ids(device_path, "temp%d_input")
			seen.append(
				"%s (pwm=%s temp=%s)" % [entry, pwm_channels, temp_channels]
			)

			var channel_numbers := _resolve_fan_channels(pwm_channels, temp_channels)
			var writable_channels := _writable_channels(device_path, channel_numbers)
			logger.debug(
				"%s: pwm_channels=%s temp_channels=%s -> resolved=%s -> writable=%s"
				% [
					device_path, pwm_channels, temp_channels, channel_numbers,
					writable_channels.map(func(ch: PwmChannel) -> int: return ch.channel_id),
				]
			)
			for ch in writable_channels:
				_channels[ch.fan_id] = ch
				discovered.append(ch.fan_id)
		entry = dir.get_next()
	dir.list_dir_end()

	logger.info("Scanned %s: %s" % [HWMON_DIR, ", ".join(seen)])
	if discovered.is_empty():
		logger.warn("No writable hwmon pwm<N>/pwm<N>_enable pair found")

	_discovered_fans = discovered
	return _discovered_fans


## Builds a PwmChannel for device_path/channel_number, resolving
## fan_id per this backend's own id convention: bare device path for
## channel 1 (backward compatible with old single-fan saved profiles),
## "<device>#<channel>" otherwise.
func _build_channel(device_path: String, channel_number: int) -> PwmChannel:
	var ch := PwmChannel.new()
	ch.hwmon_path = device_path
	ch.channel_id = channel_number
	ch.fan_id = (
		device_path if channel_number == 1 else "%s#%d" % [device_path, channel_number]
	)
	ch.enable_path = "%s/pwm%d_enable" % [device_path, channel_number]
	ch.temp_sensor_path = "%s/temp%d_input" % [device_path, channel_number]

	var point := PwmCurvePath.new()
	point.temp_path = ch.temp_sensor_path
	point.fan_speed_path = "%s/pwm%d" % [device_path, channel_number]
	ch.points = [point]
	ch.fan_speed_readback_path = point.fan_speed_path

	return ch


## Verifies if a given pwm channel actually has write permissions
## if ch.enable_path or ch.points[0].fan_speed_path has no write
## permissions returns false.
func _writable_channels(device_path: String, channel_numbers: Array[int]) -> Array[PwmChannel]:
	var writable: Array[PwmChannel] = []
	for number in channel_numbers:
		var ch := _build_channel(device_path, number)
		if not PwmIo.is_writable(ch.enable_path):
			logger.debug("%s: pwm%d_enable not writable, dropping channel" % [device_path, number])
			continue
		if not PwmIo.is_writable(ch.points[0].fan_speed_path):
			logger.debug("%s: pwm%d not writable, dropping channel" % [device_path, number])
			continue
		writable.append(ch)
	return writable


## Looks up the PwmChannel for fan_id, populating _channels first if
## discovery hasn't run yet.
func _get_channel(fan_id: String) -> PwmChannel:
	if _channels.is_empty():
		_get_or_discover_fans()
	var ch: PwmChannel = _channels.get(fan_id)
	if not ch:
		logger.warn("No discovered channel for fan_id '%s'" % fan_id)
	return ch


## Returns channel numbers (1..MAX_FAN_CHANNELS) for which
## "<device_path>/<name_pattern % N>"
func _find_channel_ids(device_path: String, name_pattern: String) -> Array[int]:
	var channels: Array[int] = []
	for channel in range(1, MAX_FAN_CHANNELS + 1):
		if not FileAccess.file_exists(device_path + "/" + (name_pattern % channel)):
			break
		channels.append(channel)
	return channels


## Splits into multiple fans only when pwm_channels and temp_channels
## are the exact same set (no reliable way to pair them otherwise).
## Falls back to channel 1 only in any ambiguous case.
func _resolve_fan_channels(pwm_channels: Array[int], temp_channels: Array[int]) -> Array[int]:
	if pwm_channels == temp_channels and pwm_channels.size() > 1:
		return pwm_channels
	if 1 in pwm_channels and 1 in temp_channels:
		return [1]
	return []


## Switches fan_id to manual pwm control (pwm<N>_enable=1) if not
## already set, since writes are otherwise silently discarded.
func _ensure_manual_mode(fan_id: String) -> bool:
	var ch := _get_channel(fan_id)
	if not ch:
		return false

	var raw := _read_text(ch.enable_path).strip_edges()
	if raw == str(PwmEnable.MANUAL):
		logger.debug("%s already in manual pwm control" % fan_id)
		return true

	logger.info("Switching %s to manual pwm control before applying custom curve" % fan_id)
	return _write_text(ch.enable_path, str(PwmEnable.MANUAL))


func _interpolate_curve(curve: Dictionary, temperature: float) -> float:
	return FanCurveUtils.interpolate_value(curve, temperature)


func _percent_to_pwm(percent: float) -> int:
	return PwmIo.percent_to_pwm(percent)


func _pwm_to_percent(pwm_value: int) -> float:
	return PwmIo.pwm_to_percent(pwm_value)


func _read_text(path: String) -> String:
	return PwmIo.read_text(path)
