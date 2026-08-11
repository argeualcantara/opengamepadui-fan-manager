extends RefCounted
class_name PwmIo

## Shared low-level helpers for talking to Linux pwm-style sysfs
## interfaces (hwmon's pwm1, asus-wmi's pwm1_auto_point*, etc). Used by
## every FanBackend that reads/writes raw sysfs files, so the file I/O
## and percent<->pwm conversion logic isn't duplicated (and doesn't
## drift) across backends.

## Safety switch, ON by default: while true, write_text() never
## touches the filesystem: every attribute write that would have
## happened is logged instead (exact path + exact value), and the call
## reports success so the rest of the plugin (mode switching, the
## curve engine, profile save, per-game snapshots, ...) runs through
## its normal logic unmodified. This is the single choke point every
## backend's writes go through, so flipping this one flag makes the
## whole plugin side-effect-free on real hardware for testing.
##
## Flip to false only once the logged writes have been reviewed and
## look correct: there is deliberately no UI toggle for this yet, it
## must be changed here in code.
static var dry_run := true

static var logger := Log.get_logger("PwmIo")


## Converts a 0-100% fan speed to a 0-255 pwm duty-cycle value.
static func percent_to_pwm(percent: float) -> int:
	return clampi(roundi(clampf(percent, 0.0, 100.0) / 100.0 * 255.0), 0, 255)


## Converts a 0-255 pwm duty-cycle value to a 0-100% fan speed.
static func pwm_to_percent(pwm_value: int) -> float:
	return clampf(float(pwm_value) / 255.0 * 100.0, 0.0, 100.0)


## Reads a sysfs text file, returning "" on any failure (missing file,
## permission denied, etc). Callers that need to distinguish "empty
## file" from "read failed" should check strip_edges().is_empty()
## themselves: in practice sysfs attributes are never legitimately
## empty, so this collapses both cases intentionally.
static func read_text(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var bytes := PackedByteArray()

	while not f.eof_reached():
		bytes.append_array(f.get_buffer(256))
	f.close()
	var as_text := bytes.get_string_from_utf8()
	return as_text.replace("\n", "")





## Writes a sysfs text file. Returns false if the file couldn't be
## opened for writing (permission denied, missing udev rule, device
## gone). Beyond the dry_run log line below, does not log: callers
## attach their own context (which attribute, which operation) to the
## failure.
static func write_text(path: String, text: String) -> bool:
	if dry_run:
		logger.info("[DRY RUN] would write '%s' to %s" % [text, path])
		return true

	var file := FileAccess.open(path, FileAccess.WRITE)
	if not file:
		return false
	file.store_string(text)
	return true
