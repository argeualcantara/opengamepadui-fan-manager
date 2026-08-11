extends "res://plugins/fan-manager/core/backends/fan_backend.gd"
class_name AsusWmiFanBackend

## [FanBackend] for ASUS devices using the `asus-wmi` kernel driver's
## native fan-curve hwmon interface (e.g. the ROG Ally handheld). See
## tasks/11-backend-asus-wmi-rog-ally.md for the research this is
## based on, and tasks/14-suporte-multiplas-fans.md for the multi-fan
## support below (confirmed on real ROG Ally hardware: the hwmon
## device named "asus_custom_fan_curve" exposes two independent
## channels, pwm1/pwm2, each with its own 8-point curve: CPU and GPU.
## Their human-readable labels ("cpu"/"gpu") live on a *different*
## hwmon device, not this one: see get_fan_label()).
##
## Unlike [HwmonFanBackend], this hardware accepts an entire curve
## table uploaded once via pwm<N>_auto_point<N>_temp/pwm: the EC then
## follows it on its own, so no continuous polling is required
## (requires_software_polling() returns false).
##
## fan_id format: "<hwmon device path>#<channel>", e.g.
## "/sys/class/hwmon/hwmon8#1": _split_fan_id() reconstructs the two
## parts to build actual sysfs paths (pwm<channel>, pwm<channel>_enable,
## pwm<channel>_auto_point<N>_temp/pwm). fan<channel>_label is the one
## exception: it's looked up across every hwmon device, not just this
## fan_id's own, since the driver doesn't expose it on the same device
## as the curve controls.

## Cross-file plugin types below are referenced via preload()'d consts,
## not bare class_name lookups: OGUI loads plugins from a zip at
## runtime, which never populates Godot's global class_name cache. See
## tasks/17-fix-class-name-resolution-em-plugin-empacotado.md.
const HardwareId = preload("res://plugins/fan-manager/core/backends/hardware_id.gd")
const PwmIo = preload("res://plugins/fan-manager/core/backends/pwm_io.gd")
const FanCurveUtils = preload("res://plugins/fan-manager/core/persistence/fan_curve_utils.gd")

const HWMON_DIR := "/sys/class/hwmon"
const HWMON_NAME := "asus_custom_fan_curve"
const MAX_HARDWARE_POINTS := 8

## asus-wmi supports up to 3 independent channels (CPU/GPU/MID fan):
## discovery just checks which pwm<N> files actually exist, this is
## only an upper bound to stop scanning at.
const MAX_FAN_CHANNELS := 3

## pwm<N>_enable values specific to asus-wmi's fan curve feature (not
## the same semantics as generic hwmon). Per the kernel source
## (fan_curve_enable_store in asus-wmi.c): 1 enables the custom curve;
## 2 and 3 both disable it and hand control back to the firmware: the
## *only* difference is that 3 also resets the driver's own cached
## curve-point registers to the factory defaults, while 2 leaves
## whatever was last written (by us or anyone else) in place. There is
## no separate "OS-managed" curve exposed by this value at all (that
## would be /sys/firmware/acpi/platform_profile, a different
## subsystem, out of scope here: see tasks/11).
##
## BIOS Mode uses 2, not 3: resetting the driver's register cache has
## no effect on the physical fan (both values hand control back to the
## same firmware auto behavior) and RESET_DEFAULT is intentionally
## left unused for now, so no cached curve-point data is ever
## discarded. Consequence: get_bios_curve() reads those same
## registers, so once a custom curve has been applied at least once,
## it will keep reporting that curve back: not necessarily the
## hardware's original factory curve. See its doc comment below.
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


## Reads fan<channel>_label (e.g. "cpu"/"gpu" on the ROG Ally) when the
## driver exposes it; falls back to a generic "Fan <channel>" name.
##
## Confirmed on real ROG Ally hardware: the label does NOT live next to
## the curve-control files. hwmon8 (name "asus_custom_fan_curve") has
## pwm1_enable/pwm2_enable and the 8 auto_point*_temp/pwm registers per
## channel, but fan1_label/fan2_label live on a *different* device,
## hwmon7: a separate hwmon node the same asus-wmi driver exposes for
## sensor readouts. There's no direct link between the two devices
## other than channel *number*, so this searches every hwmon device
## for a fan<channel>_label file and assumes matching channel numbers
## refer to the same physical fan (true for CPU=1/GPU=2 on the Ally).
func get_fan_label(fan_id: String) -> String:
	var parts := _split_fan_id(fan_id)
	var channel: int = parts["channel"]

	var label := PwmIo.read_text("%s/fan%d_label" % [parts["device"], channel]).strip_edges()
	if label.is_empty():
		label = _find_fan_label_across_hwmon(channel)

	if label.is_empty():
		return "Fan %d" % channel
	return label.to_upper()


## Scans every hwmon device (not just the one this fan's pwm control
## lives on) for a fan<channel>_label file, returning the first match.
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


## pwm<N>_enable has no distinct "OS-managed" value (see AsusPwmEnable
## doc comment): OS Mode isn't offered by this backend for now.
func supports_os_mode() -> bool:
	return false


func requires_software_polling() -> bool:
	return false


## Reads back the curve currently programmed into the hardware's 8
## points for the given fan channel. Returns {} if any point is
## unreadable, matching HwmonFanBackend's fallback behavior.
##
## Despite the name (required by the FanBackend interface), this is
## NOT guaranteed to be the hardware's original factory curve: BIOS
## Mode uses pwm<N>_enable=2, which never resets these registers (see
## AsusPwmEnable doc comment), so after the user has applied at least
## one custom curve this session, that's what gets read back here
## instead. In practice this only matters if Custom Mode is entered
## with no saved profile after a custom curve was already applied and
## then discarded/deleted: a rare edge case, but a real one.
func get_bios_curve(fan_id: String) -> Dictionary:
	var parts := _split_fan_id(fan_id)
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


## Sets the mode for every discovered fan channel at once: BIOS/Custom
## Mode apply to the whole device, not a single fan.
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
		"os":
			logger.warn("AsusWmiFanBackend does not support OS mode")
			return false
		_:
			logger.error("Unknown fan mode '%s'" % mode)
			return false

	var failed_fans: Array[String] = []
	for fan_id in fans:
		var parts := _split_fan_id(fan_id)
		var path := "%s/pwm%d_enable" % [parts["device"], parts["channel"]]
		if not _write_text(path, str(enable_value)):
			failed_fans.append(fan_id)

	if not failed_fans.is_empty():
		logger.error("Failed to set mode '%s' for fan(s): %s" % [mode, ", ".join(failed_fans)])
		return false

	return true


## Both 2 and 3 mean "bios" (see AsusPwmEnable doc comment: they're
## physically identical, we just never write 3 ourselves). Only checks
## the first discovered channel: set_mode() always keeps every
## channel in sync, so any one of them is representative.
func get_current_mode() -> String:
	var fans := _get_or_discover_fans()
	if fans.is_empty():
		return ""

	var parts := _split_fan_id(fans[0])
	var raw := PwmIo.read_text(
		"%s/pwm%d_enable" % [parts["device"], parts["channel"]]
	).strip_edges()
	if raw == str(AsusPwmEnable.MANUAL):
		return "custom"
	if raw == str(AsusPwmEnable.BIOS) or raw == str(AsusPwmEnable.RESET_DEFAULT):
		return "bios"
	return ""


## Validates/clamps the curve, reduces it from the UI's 10 points down
## to the hardware's 8-point limit, and uploads it in one shot to the
## given fan channel: the EC takes it from there, no further calls are
## needed until the curve changes again
## (requires_software_polling() == false).
func apply_custom_curve(fan_id: String, curve: Dictionary) -> bool:
	if curve.is_empty():
		logger.warn("Cannot apply an empty custom curve to %s" % fan_id)
		return false

	if not _ensure_manual_mode(fan_id):
		logger.error(
			"Cannot apply custom curve to %s: failed to switch pwm_enable to manual" % fan_id
		)
		return false

	var parts := _split_fan_id(fan_id)
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
	var parts := _split_fan_id(fan_id)
	var raw := PwmIo.read_text(
		"%s/temp%d_input" % [parts["device"], parts["channel"]]
	).strip_edges()
	if raw.is_empty():
		logger.warn("Unable to read temp%d_input for %s" % [int(parts["channel"]), fan_id])
		return -1.0
	return raw.to_float() / 1000.0


func read_fan_percent(fan_id: String) -> float:
	var parts := _split_fan_id(fan_id)
	var raw := PwmIo.read_text("%s/pwm%d" % [parts["device"], parts["channel"]]).strip_edges()
	if raw.is_empty():
		logger.warn("Unable to read pwm%d for %s" % [int(parts["channel"]), fan_id])
		return -1.0
	return PwmIo.pwm_to_percent(raw.to_int())


## Discovers hwmon devices whose "name" attribute is
## "asus_custom_fan_curve", then enumerates every pwm<N> channel that
## actually exists on each (1 on some ASUS laptops, 2 on the ROG Ally:
## CPU + GPU). Cached once found, retried on every call until then
## (same rationale as HwmonFanBackend: hwmon may not be populated yet
## this early in boot).
func _get_or_discover_fans() -> Array[String]:
	logger.warning("entro get or discover")
	if not _discovered_fans.is_empty():
		return _discovered_fans
	logger.warning("fans empty")

	var discovered: Array[String] = []
	var dir := DirAccess.open(HWMON_DIR)
	if not dir:
		logger.warn("Unable to open %s" % HWMON_DIR)
		return discovered

	# Diagnostic: log every hwmon device considered and its "name", so
	# a failed detection is debuggable from a log alone (e.g. sandbox
	# restricting /sys/class/hwmon, or the driver not loaded yet at
	# this point in boot) instead of a bare "no backend supports this
	# hardware" with no path/name information to act on.
	var seen: Array[String] = []

	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not entry.begins_with("."):
			var device_path := HWMON_DIR + "/" + entry
			var name := PwmIo.read_text(device_path + "/name").strip_edges()
			seen.append("%s -> '%s'" % [entry, name])
			logger.info(
				"device_path: %s; read_text: %s)" % [device_path, device_path + "/name"]
				)
			if name == HWMON_NAME:
				logger.info("Found desired name %s" % name)
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


## Splits a "<device>#<channel>" fan_id back into its parts. Tolerates
## a bare device path (no "#") by assuming channel 1, so a caller that
## somehow still has an old-format fan_id doesn't hard-crash.
func _split_fan_id(fan_id: String) -> Dictionary:
	var parts := fan_id.split("#")
	if parts.size() != 2:
		return {"device": fan_id, "channel": 1}
	return {"device": parts[0], "channel": int(parts[1])}


## Ensures the given fan channel is under custom-curve control
## (pwm<N>_enable=1) before uploading curve points: mirrors
## HwmonFanBackend's _ensure_manual_mode, same rationale (writes are
## ignored otherwise).
func _ensure_manual_mode(fan_id: String) -> bool:
	var parts := _split_fan_id(fan_id)
	var path := "%s/pwm%d_enable" % [parts["device"], parts["channel"]]

	var raw := PwmIo.read_text(path).strip_edges()
	if raw == str(AsusPwmEnable.MANUAL):
		return true

	logger.info("Switching %s to manual fan curve control" % fan_id)
	return _write_text(path, str(AsusPwmEnable.MANUAL))


## The kernel doesn't validate uploaded curves (no safety check is
## performed by the driver), so this backend enforces, in order:
## clamping to 0-100%, and a left-to-right non-decreasing sweep (a
## single forward pass with a running max is sufficient to guarantee
## the whole curve is monotonic, unlike CustomCurveEngine.set_point()'s
## incremental two-directional push, which only needs to correct
## points relative to the one just edited). Second line of defense in
## case a curve reaches this backend some other way (e.g. a saved
## profile edited by hand).
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


## Reduces a curve to at most MAX_HARDWARE_POINTS entries by keeping the
## hottest ones and dropping the coldest. Rationale: the coldest points
## of the UI's 10-point curve tend to sit at/near 0% anyway (idle fan),
## so they carry the least shape information: the actively-managed
## part of a curve is the hot end, which this always keeps in full.
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
