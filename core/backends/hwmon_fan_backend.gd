extends "res://plugins/fan-manager/core/backends/fan_backend.gd"
class_name HwmonFanBackend

# generic fallback backend using linux hwmon (/sys/class/hwmon), for when no
# vendor-specific backend recognizes the device. single-fan devices just use
# the hwmon device path as fan_id, devices with paired pwm<N>/temp<N>_input
# (handhelds with cpu+gpu fans) get split into "<device path>#<channel>"
# fan_ids, see _resolve_fan_channels()

const FanCurveUtils = preload("res://plugins/fan-manager/core/persistence/fan_curve_utils.gd")
const PwmChannel = preload("res://plugins/fan-manager/core/models/pwm_channel.gd")
const PwmCurvePath = preload("res://plugins/fan-manager/core/models/pwm_curve_path.gd")
const HWMON_DIR := "/sys/class/hwmon"
const MAX_FAN_CHANNELS := 4

# pwm1_enable values from the linux hwmon sysfs docs
enum PwmEnable { MANUAL = 1, AUTOMATIC = 2 }

var _discovered_fans: Array[String] = []
var _last_written_pwm: Dictionary = {}

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

	var enable_mode: int
	match mode:
		"bios":
			enable_mode = PwmEnable.AUTOMATIC
		"custom":
			enable_mode = PwmEnable.MANUAL
		_:
			logger.error("Unknown fan mode '%s'" % mode)
			return false

	logger.debug("set_mode('%s'): writing pwm_enable=%d to %s" % [mode, enable_mode, fans])

	var failed_fans: Array[String] = []
	for fan_id in fans:
		var ch := _get_channel(fan_id)
		if not ch:
			failed_fans.append(fan_id)
			continue
		var wrote = _write_text(ch.pwm_enable_path, str(enable_mode))
		if not wrote:
			failed_fans.append(fan_id)

	if not failed_fans.is_empty():
		logger.error("Failed to set mode '%s' for fan(s): %s" % [mode, ", ".join(failed_fans)])
		return false

	logger.debug("set_mode('%s') succeeded for all %d fan(s)" % [mode, fans.size()])
	return true


# just checks the first discovered channel, they're all kept in sync
func get_current_mode() -> String:
	var fans := _get_or_discover_fans()
	if fans.is_empty():
		return ""

	var channel := _get_channel(fans[0])
	if not channel:
		return ""
	var pwm_enable_value = PwmIo.read_text(channel.pwm_enable_path)

	var mode := ""
	if pwm_enable_value == str(PwmEnable.MANUAL):
		mode = "custom"
	elif pwm_enable_value == str(PwmEnable.AUTOMATIC):
		mode = "bios"
	logger.debug("get_current_mode(): pwm_enable='%s' (from %s) -> '%s'" % [pwm_enable_value, fans[0], mode])
	return mode


func apply_custom_curve(fan_id: String, curve: Dictionary) -> bool:
	if curve.is_empty():
		logger.warn("Cannot apply an empty custom curve to %s" % fan_id)
		return false

	var manual_ok = _ensure_manual_mode(fan_id)
	if not manual_ok:
		logger.error(
			"Cannot apply custom curve to %s: failed to switch pwm1_enable to manual" % fan_id
		)
		return false

	var temperature := read_temperature(fan_id)
	if temperature < 0.0:
		logger.error("Cannot apply custom curve to %s: temperature read failed" % fan_id)
		return false

	var percent := FanCurveUtils.interpolate_value(curve, temperature)
	var pwm_value := PwmIo.percent_to_pwm(percent)
	logger.debug(
		"apply_custom_curve(%s): temp=%.1f°C -> %.1f%% -> pwm=%d" % [fan_id, temperature, percent, pwm_value]
	)

	# this runs every poll tick, skip the write if nothing changed
	var last_pwm = _last_written_pwm.get(fan_id)
	if last_pwm == pwm_value:
		logger.debug(
			"apply_custom_curve(%s): pwm=%d unchanged since last write, skipping" % [fan_id, pwm_value]
		)
		return true

	var channel := _get_channel(fan_id)
	if not channel:
		return false
	var wrote := _write_text(channel.points[0].fan_speed_path, str(pwm_value))
	if wrote:
		_last_written_pwm[fan_id] = pwm_value
		logger.debug(
			"Applied curve to %s: %.1f°C -> %d%% (pwm=%d)" % [fan_id, temperature, percent, pwm_value]
		)
	return wrote


func read_temperature(fan_id: String) -> float:
	var channel := _get_channel(fan_id)
	if not channel:
		return -1.0
	var pwm_temp = PwmIo.read_text(channel.readonly_temp_sensor_path)
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
	var pwm_fan_speed = PwmIo.read_text(channel.readonly_fan_speed_path)
	if pwm_fan_speed.is_empty():
		logger.warn("Unable to read pwm%d for %s" % [channel.channel_id, fan_id])
		return -1.0
	var pwm_int = pwm_fan_speed.to_int()
	var percent := PwmIo.pwm_to_percent(pwm_int)
	logger.debug("read_fan_percent(%s) -> %.1f%% (pwm_fan_speed='%s')" % [fan_id, percent, pwm_fan_speed])
	return percent


# looks for hwmon devices with a matched pwm<N>/temp<N>_input pair that's
# actually writable (existing but read-only channels would just fail later
# at set_mode/apply_custom_curve time). cached once found, retried until
# then since hwmon might not be populated yet this early in boot.
func _get_or_discover_fans() -> Array[String]:
	if not _discovered_fans.is_empty():
		return _discovered_fans

	logger.debug("Discovering fans under %s" % HWMON_DIR)

	var hwmon_path_dir := DirAccess.open(HWMON_DIR)
	if not hwmon_path_dir:
		logger.warn("Unable to open %s" % HWMON_DIR)
		return _discovered_fans

	# logged at the end, for debugging failed detection
	var seen: Array[String] = []

	hwmon_path_dir.list_dir_begin()
	var hwmon_entry := hwmon_path_dir.get_next()
	while hwmon_entry != "":
		if not hwmon_entry.begins_with("."):
			var device_path := HWMON_DIR + "/" + hwmon_entry
			var pwm_channels := _find_channel_ids(device_path, "pwm%d_enable")
			var temp_channels := _find_channel_ids(device_path, "temp%d_input")
			seen.append("%s (pwm=%s temp=%s)" % [hwmon_entry, pwm_channels, temp_channels])

			var channel_numbers := _resolve_fan_channels(pwm_channels, temp_channels)
			var writable_channels := _writable_channels(device_path, channel_numbers)
			var writable_ids = writable_channels.map(func(ch: PwmChannel) -> int: return ch.channel_id)
			logger.debug("%s: pwm_channels=%s temp_channels=%s -> resolved=%s -> writable=%s" % [device_path, pwm_channels, temp_channels, channel_numbers, writable_ids])
			for channel in writable_channels:
				_channels[channel.fan_id] = channel
				_discovered_fans.append(channel.fan_id)
		hwmon_entry = hwmon_path_dir.get_next()
	hwmon_path_dir.list_dir_end()

	logger.info("Scanned %s: %s" % [HWMON_DIR, ", ".join(seen)])
	if _discovered_fans.is_empty():
		logger.warn("No writable hwmon pwm<N>/pwm<N>_enable pair found")

	return _discovered_fans


# channel 1 keeps using the bare device path as fan_id, for backward compat
# with old single-fan saved profiles. anything else gets "<device>#<channel>"
func _build_channel(device_path: String, channel_number: int) -> PwmChannel:
	var channel := PwmChannel.new()
	channel.hwmon_path = device_path
	channel.channel_id = channel_number
	channel.fan_id = (
		device_path if channel_number == 1 else "%s#%d" % [device_path, channel_number]
	)
	channel.pwm_enable_path = "%s/pwm%d_enable" % [device_path, channel_number]
	channel.readonly_temp_sensor_path = "%s/temp%d_input" % [device_path, channel_number]

	var point := PwmCurvePath.new()
	point.temp_path = channel.readonly_temp_sensor_path
	point.fan_speed_path = "%s/pwm%d" % [device_path, channel_number]
	channel.points = [point]
	channel.readonly_fan_speed_path = point.fan_speed_path

	return channel


func _writable_channels(device_path: String, channel_numbers: Array[int]) -> Array[PwmChannel]:
	var writable: Array[PwmChannel] = []
	for number in channel_numbers:
		var channel := _build_channel(device_path, number)
		var enable_writable = PwmIo.is_writable(channel.pwm_enable_path)
		if not enable_writable:
			logger.debug("%s: pwm%d_enable not writable, dropping channel" % [device_path, number])
			continue
		var speed_writable = PwmIo.is_writable(channel.points[0].fan_speed_path)
		if not speed_writable:
			logger.debug("%s: pwm%d not writable, dropping channel" % [device_path, number])
			continue
		writable.append(channel)
	return writable


func _get_channel(fan_id: String) -> PwmChannel:
	if _channels.is_empty():
		_get_or_discover_fans()
	var channel: PwmChannel = _channels.get(fan_id)
	return channel


func _find_channel_ids(device_path: String, name_pattern: String) -> Array[int]:
	var channels: Array[int] = []
	for channel in range(1, MAX_FAN_CHANNELS + 1):
		var channel_path = device_path + "/" + (name_pattern % channel)
		var exists = FileAccess.file_exists(channel_path)
		if not exists:
			break
		channels.append(channel)
	return channels


# only splits into multiple fans when pwm_channels and temp_channels are the
# exact same set, no reliable way to pair them otherwise. falls back to
# channel 1 in any ambiguous case.
func _resolve_fan_channels(pwm_channels: Array[int], temp_channels: Array[int]) -> Array[int]:
	if pwm_channels == temp_channels and pwm_channels.size() > 1:
		return pwm_channels
	# only 1 pwm but multiple temps case
	if 1 in pwm_channels and 1 in temp_channels:
		return [1]
	return []


func _ensure_manual_mode(fan_id: String) -> bool:
	var channel := _get_channel(fan_id)
	if not channel:
		return false

	var pwm_enable_value = PwmIo.read_text(channel.pwm_enable_path)
	if pwm_enable_value == str(PwmEnable.MANUAL):
		logger.debug("%s already in manual pwm control" % fan_id)
		return true

	logger.info("Switching %s to manual pwm control before applying custom curve" % fan_id)
	return _write_text(channel.pwm_enable_path, str(PwmEnable.MANUAL))
