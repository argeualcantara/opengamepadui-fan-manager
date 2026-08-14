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


## Writes text to a sysfs file. Tries a direct write first (works if
## this process already has permission, e.g. a future udev rule); on
## failure, falls back to the privileged helper (see
## policy/fan-manager-priv-write@.service and policy/50-fan-manager.rules)
## before giving up — the expected path in production, since these
## sysfs attributes are root-owned and this plugin runs unprivileged.
static func write_text(path: String, text: String) -> bool:
	if dry_run:
		logger.info("[DRY RUN] would write '%s' to %s" % [text, path])
		return true

	var file := FileAccess.open(path, FileAccess.WRITE)
	if file:
		file.store_string(text)
		logger.debug("write_text('%s', '%s') succeeded" % [path, text])
		return true

	logger.debug(
		"write_text('%s') failed to open directly (%s), falling back to privileged helper"
		% [path, error_string(FileAccess.get_open_error())]
	)
	return _privileged_write(path, text)


## Unit template installed by policy/fan-manager-priv-write@.service;
## the instance packs "<systemd-escape(path)>@<systemd-escape(value)>"
## (see that file's own header comment for the exact format and why
## it exists instead of a plain pkexec call).
const PRIV_WRITE_UNIT_TEMPLATE := "fan-manager-priv-write@%s.service"


static func _escape_for_systemd(value: String) -> String:
	var output := []
	var exit_code := OS.execute("systemd-escape", ["--", value], output)
	if exit_code != 0:
		logger.debug("_escape_for_systemd('%s') failed: systemd-escape exited %d" % [value, exit_code])
		return ""
	return (output[0] as String).strip_edges()


## Starts fan-manager-priv-write@<instance>.service (authorized
## without a password by policy/50-fan-manager.rules) to perform the
## write as root. Returns false without spawning systemctl at all if
## the instance can't be built, so this degrades cleanly rather than
## running a command that can't possibly succeed.
static func _privileged_write(path: String, text: String) -> bool:
	var escaped_path := _escape_for_systemd(path)
	var escaped_value := _escape_for_systemd(text)
	if escaped_path.is_empty() or escaped_value.is_empty():
		return false

	var unit := PRIV_WRITE_UNIT_TEMPLATE % (escaped_path + "@" + escaped_value)
	var output := []
	var exit_code := OS.execute("systemctl", ["start", unit], output, true)
	if exit_code != 0:
		logger.debug("_privileged_write('%s', '%s') failed via %s: %s" % [path, text, unit, output])
		return false
	logger.debug("_privileged_write('%s', '%s') succeeded via %s" % [path, text, unit])
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
