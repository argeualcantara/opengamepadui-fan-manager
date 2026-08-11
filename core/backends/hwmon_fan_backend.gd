extends "res://plugins/fan-manager/core/backends/fan_backend.gd"
class_name HwmonFanBackend

## Generic [FanBackend] fallback based on the Linux [code]hwmon[/code]
## sysfs interface (/sys/class/hwmon). Used when no hardware-specific
## backend recognizes the current device.
##
## A device exposing a single controllable fan is the common case: its
## fan_id is just the hwmon device directory path (e.g.
## "/sys/class/hwmon/hwmon3"), covering most desktop motherboards. When
## a device exposes multiple pwm<N>/temp<N>_input pairs for the exact
## same set of channel numbers (common on handhelds with independent
## CPU/GPU fans: ROG Ally, GPD Win, Legion Go, MSI Claw, etc.), each
## channel becomes its own fan_id, "<device path>#<channel>" (same
## format AsusWmiFanBackend already uses) — see
## _resolve_fan_channels() for exactly when that split happens versus
## falling back to the single-fan case.
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

## Generic hwmon devices can expose more than 2 independent channels in
## principle; this is only an upper bound to stop scanning at (same
## role as AsusWmiFanBackend.MAX_FAN_CHANNELS), not an assumption about
## how many any real device has.
const MAX_FAN_CHANNELS := 4

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


## Only checks the first discovered fan: set_mode() always keeps every
## channel in sync (same rationale as AsusWmiFanBackend), so any one of
## them is representative.
func get_current_mode() -> String:
	var fans := _get_or_discover_fans()
	if fans.is_empty():
		return ""

	var parts := PwmIo.split_channel_fan_id(fans[0])
	var raw := PwmIo.read_text(
		"%s/pwm%d_enable" % [parts["device"], parts["channel"]]
	).strip_edges()
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

	var parts := PwmIo.split_channel_fan_id(fan_id)
	var wrote := _write_text("%s/pwm%d" % [parts["device"], parts["channel"]], str(pwm_value))
	if wrote:
		_last_written_pwm[fan_id] = pwm_value
		logger.debug(
			"Applied curve to %s: %.1f°C -> %d%% (pwm=%d)" % [fan_id, temperature, percent, pwm_value]
		)
	return wrote


func read_temperature(fan_id: String) -> float:
	var parts := PwmIo.split_channel_fan_id(fan_id)
	var raw := _read_text("%s/temp%d_input" % [parts["device"], parts["channel"]]).strip_edges()
	if raw.is_empty():
		logger.warn("Unable to read temp%d_input for %s" % [parts["channel"], fan_id])
		return -1.0
	return raw.to_float() / 1000.0


func read_fan_percent(fan_id: String) -> float:
	var parts := PwmIo.split_channel_fan_id(fan_id)
	var raw := _read_text("%s/pwm%d" % [parts["device"], parts["channel"]]).strip_edges()
	if raw.is_empty():
		logger.warn("Unable to read pwm%d for %s" % [parts["channel"], fan_id])
		return -1.0
	return _pwm_to_percent(raw.to_int())


## Discovers hwmon devices exposing at least a matched pwm1/temp1_input
## pair, splitting a device into multiple independent fan_ids
## ("<device path>#<channel>") when it exposes pwm<N>/temp<N>_input for
## the exact same set of channels (see _resolve_fan_channels()).
## Cached once a non-empty result is found; retried on every call until
## then, since hwmon may not be fully populated yet this early in boot.
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
			var pwm_channels := _find_channels(device_path, "pwm%d_enable")
			var temp_channels := _find_channels(device_path, "temp%d_input")
			seen.append(
				"%s (pwm=%s temp=%s)" % [entry, pwm_channels, temp_channels]
			)

			var channels := _resolve_fan_channels(pwm_channels, temp_channels)
			if channels.size() > 1:
				for channel in channels:
					discovered.append("%s#%d" % [device_path, channel])
			elif channels.size() == 1:
				# Backward compatible with every fan_id already saved
				# by FanCurveStore for single-fan hardware (the common
				# case): the bare device path, no "#channel" suffix.
				discovered.append(device_path)
		entry = dir.get_next()
	dir.list_dir_end()

	logger.info("Scanned %s: %s" % [HWMON_DIR, ", ".join(seen)])
	if discovered.is_empty():
		logger.warn("No hwmon device exposing a matched pwm<N>/temp<N>_input pair found")

	_discovered_fans = discovered
	return _discovered_fans


## Returns the channel numbers (1..MAX_FAN_CHANNELS) for which
## "<device_path>/<name_pattern % N>" exists, e.g.
## _find_channels(path, "pwm%d_enable") -> [1, 2] if pwm1_enable and
## pwm2_enable both exist but pwm3_enable doesn't. Stops at the first
## gap, same discovery style as AsusWmiFanBackend.
func _find_channels(device_path: String, name_pattern: String) -> Array[int]:
	var channels: Array[int] = []
	for channel in range(1, MAX_FAN_CHANNELS + 1):
		if not FileAccess.file_exists(device_path + "/" + (name_pattern % channel)):
			break
		channels.append(channel)
	return channels


## Only splits a device into multiple independent fans when pwm<N> and
## temp<N>_input exist for the exact same set of channels: there's no
## reliable cross-vendor convention for pairing them otherwise (unlike
## AsusWmiFanBackend, which controls one specific, well-documented
## driver) — see REQUIREMENTS.md §5. Falls back to the single
## historical fan (channel 1 only) in any ambiguous case, e.g. pwm2
## exists but temp2_input doesn't: channel counts must match too, not
## just channel 1 being present, since a bare size comparison would
## accept a device with pwm=[1,2], temp=[1,3] (same count, different
## channels) as if it were safely paired.
func _resolve_fan_channels(pwm_channels: Array[int], temp_channels: Array[int]) -> Array[int]:
	if pwm_channels == temp_channels and pwm_channels.size() > 1:
		return pwm_channels
	if 1 in pwm_channels and 1 in temp_channels:
		return [1]
	return []


## Ensures the given fan's pwm is under manual control (pwm1_enable=1)
## before a custom value is written to it. Without this, drivers that
## are still in automatic mode (2) silently discard direct pwm writes
## on their next update tick, making apply_custom_curve() a no-op.
func _ensure_manual_mode(fan_id: String) -> bool:
	var parts := PwmIo.split_channel_fan_id(fan_id)
	var path := "%s/pwm%d_enable" % [parts["device"], parts["channel"]]

	var raw := _read_text(path).strip_edges()
	if raw == str(PwmEnable.MANUAL):
		return true

	logger.info("Switching %s to manual pwm control before applying custom curve" % fan_id)
	return _write_text(path, str(PwmEnable.MANUAL))


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
