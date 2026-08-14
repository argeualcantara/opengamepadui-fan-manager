extends RefCounted
class_name PwmIo

## Shared low-level helpers for talking to Linux pwm-style sysfs
## interfaces (hwmon's pwm1, asus-wmi's pwm1_auto_point*, etc), so file
## I/O and percent<->pwm conversion aren't duplicated across backends.

## Safety switch, ON by default: while true, write_text() only logs
## what it would write instead of touching the filesystem, and reports
## success. Single choke point for every backend's writes. No UI
## toggle yet, flip manually here once logged writes look correct.
static var dry_run := true

static var logger := Log.get_logger("FanManager PwmIo")


## Splits a "<device>#<channel>" fan_id into {"device": ..., "channel":
## ...}. A bare device path with no "#" defaults to channel 1, for
## single-fan hardware's fan_id (backward compatible with saved
## profiles).
## TODO: no longer called anywhere,  HwmonFanBackend and
## AsusWmiFanBackend both migrated to looking up a PwmChannel (with
## every path already resolved) by fan_id instead of re-deriving paths
## from it on every call. Safe to delete this method and its two tests
## in pwm_io_test.gd once nothing else needs it.
static func split_channel_fan_id(fan_id: String) -> Dictionary:
	var parts := fan_id.split("#")
	if parts.size() != 2:
		return {"device": fan_id, "channel": 1}
	return {"device": parts[0], "channel": int(parts[1])}


## Converts a 0-100% fan speed to a 0-255 pwm duty-cycle value.
static func percent_to_pwm(percent: float) -> int:
	return clampi(roundi(clampf(percent, 0.0, 100.0) / 100.0 * 255.0), 0, 255)


## Converts a 0-255 pwm duty-cycle value to a 0-100% fan speed.
static func pwm_to_percent(pwm_value: int) -> float:
	return clampf(float(pwm_value) / 255.0 * 100.0, 0.0, 100.0)


## Reads a sysfs text file, returning "" on any failure (missing file,
## permission denied, etc) or if the file is empty.
static func read_text(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		logger.debug("read_text('%s') failed: %s" % [path, error_string(FileAccess.get_open_error())])
		return ""
	var bytes := PackedByteArray()

	while not f.eof_reached():
		bytes.append_array(f.get_buffer(256))
	f.close()
	var as_text := bytes.get_string_from_utf8().replace("\n", "")
	logger.debug("read_text('%s') -> '%s'" % [path, as_text])
	return as_text


## Writes text to a sysfs file. Returns false if it couldn't be opened
## for writing (permission denied, missing udev rule, device gone).
static func write_text(path: String, text: String) -> bool:
	if dry_run:
		logger.info("[DRY RUN] would write '%s' to %s" % [text, path])
		return true

	var file := FileAccess.open(path, FileAccess.WRITE)
	if not file:
		logger.debug("write_text('%s') failed to open: %s" % [path, error_string(FileAccess.get_open_error())])
		return false
	file.store_string(text)
	logger.debug("write_text('%s', '%s') succeeded" % [path, text])
	return true


## Returns whether path exists at all, without opening it,  cheaper
## than is_writable() for callers that only need to know a sysfs
## attribute is present (e.g. probing how many hardware curve points a
## device actually exposes), not that it's writable.
static func path_exists(path: String) -> bool:
	return FileAccess.file_exists(path)


## Probes whether path can currently be opened for writing
static func is_writable(path: String) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if not file:
		logger.debug(
			"is_writable('%s') -> false: %s" % [path, error_string(FileAccess.get_open_error())]
		)
		return false
	file.close()
	return true
