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

static var has_permission := true

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
	if has_permission:
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file:
			file.store_string(text)
			logger.debug("write_text('%s', '%s') succeeded" % [path, text])
			return true

		logger.debug(
			"write_text('%s') failed to open directly (%s), falling back to privileged helper"
			% [path, error_string(FileAccess.get_open_error())]
		)
	has_permission = false
	return _privileged_write(path, text)


## Unit template installed by policy/fan-manager-priv-write@.service;
## the instance packs "<systemd-escape(path)>@<systemd-escape(value)>"
## (see that file's own header comment for the exact format and why
## it exists instead of a plain pkexec call).
const PRIV_WRITE_UNIT_TEMPLATE := "fan-manager-priv-write@%s.service"


## Characters systemd-escape leaves unescaped (besides "/", which maps
## to "-" below): letters, digits, ":", "_", ".". "-" itself is
## deliberately NOT in this set even though it's otherwise a valid
## unit-name character — it's reserved as the substitution target for
## "/", so a literal "-" in the input has to be escaped too or it'd be
## ambiguous with a "/". Matches systemd's own unit_name_escape().
const _SYSTEMD_ESCAPE_SAFE_CHARS := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789:_."


## Reimplements `systemd-escape <value>` (no --path/--template) in
## pure GDScript instead of shelling out to the real binary.
## _privileged_write() calls this twice per write, and a single
## "Apply" can trigger 30+ writes (8 curve points × 2 values × up to
## 2 fans, plus pwm_enable) — spawning 2 extra processes per write on
## top of the systemctl call itself was measurably freezing the UI
## for several seconds on a real device. Every byte not in the safe
## set (or "/" or "-") becomes "\xHH"; "/" becomes "-" directly.
static func _systemd_escape(value: String) -> String:
	var result := ""
	for byte in value.to_utf8_buffer():
		var ch := char(byte)
		if ch == "/":
			result += "-"
		elif ch == "-" or ch == "\\" or not _SYSTEMD_ESCAPE_SAFE_CHARS.contains(ch):
			result += "\\x%02x" % byte
		else:
			result += ch
	return result


## Starts fan-manager-priv-write@<instance>.service (authorized
## without a password by policy/50-fan-manager.rules) to perform the
## write as root.
static func _privileged_write(path: String, text: String) -> bool:
	var instance := _systemd_escape(path) + "@" + _systemd_escape(text)
	var unit := PRIV_WRITE_UNIT_TEMPLATE % instance
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
