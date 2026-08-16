extends RefCounted
class_name PwmIo

# low level helpers for talking to linux pwm sysfs stuff (hwmon's pwm1,
# asus-wmi's pwm1_auto_point*, etc) so file I/O and percent<->pwm math
# isn't duplicated across backends

# safety switch, on by default - while true write_text() only logs what it
# would write and pretends it succeeded, never touches the filesystem.
# flip manually here once logged writes look right, no UI toggle for it yet.
static var dry_run := true

static var logger := Log.get_logger("FanManager PwmIo")

static var has_permission := true

static func percent_to_pwm(percent: float) -> int:
	return clampi(roundi(clampf(percent, 0.0, 100.0) / 100.0 * 255.0), 0, 255)


static func pwm_to_percent(pwm_value: int) -> float:
	return clampf(float(pwm_value) / 255.0 * 100.0, 0.0, 100.0)


static func read_text(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		var open_error = FileAccess.get_open_error()
		logger.debug("read_text('%s') failed: %s" % [path, error_string(open_error)])
		return ""
	var bytes := PackedByteArray()

	while not f.eof_reached():
		bytes.append_array(f.get_buffer(256))
	f.close()
	var as_text := bytes.get_string_from_utf8().replace("\n", "")
	logger.debug("read_text('%s') -> '%s'" % [path, as_text])
	return as_text


# tries a direct write first (works if we already have permission, e.g. a
# future udev rule), falls back to the privileged helper service on
# failure - that's the normal path in production since these sysfs files
# are root-owned and this plugin runs unprivileged
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

		var open_error = FileAccess.get_open_error()
		logger.debug(
			"write_text('%s') failed to open directly (%s), falling back to privileged helper"
			% [path, error_string(open_error)]
		)
	has_permission = false
	return _privileged_write(path, text)


# matches the unit template from policy/fan-manager-priv-write@.service,
# instance is "<escaped path>@<escaped value>"
const PRIV_WRITE_UNIT_TEMPLATE := "fan-manager-priv-write@%s.service"

# chars systemd-escape leaves alone besides "/" (mapped to "-" below):
# letters, digits, ":", "_", ".". "-" itself has to be escaped too even
# though it'd normally be a valid unit-name char, since it's used as the
# substitution target for "/".
const _SYSTEMD_ESCAPE_SAFE_CHARS := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789:_."


# reimplements `systemd-escape <value>` in gdscript instead of shelling out
# - _privileged_write() calls this twice per write and a single Apply can
# fire 30+ writes, spawning that many extra processes was noticeably
# freezing the UI on real hardware
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


# starts fan-manager-priv-write@<instance>.service (allowed without a
# password by policy/50-fan-manager.rules) to do the write as root
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


static func path_exists(path: String) -> bool:
	return FileAccess.file_exists(path)


static func is_writable(path: String) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if not file:
		var open_error = FileAccess.get_open_error()
		logger.debug(
			"is_writable('%s') -> false: %s" % [path, error_string(open_error)]
		)
		return false
	file.close()
	return true
