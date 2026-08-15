extends GutTest

## Covers PwmIo._systemd_escape(), the pure-GDScript reimplementation
## of `systemd-escape` used to build fan-manager-priv-write@<instance>
## unit names (see PwmIo._privileged_write()). Getting this encoding
## wrong wouldn't fail loudly: it would silently produce a unit name
## the polkit rule's regex still matches, but whose instance the
## privileged helper decodes into a different (and likely rejected)
## path/value pair — so this is asserted against known-good output
## captured from the real systemd-escape binary, not just re-derived
## logic.


func test_systemd_escape_maps_slashes_to_hyphens() -> void:
	# Captured from a real device: `systemd-escape --
	# /sys/class/hwmon/hwmon8/pwm1_enable` produced exactly this.
	assert_eq(
		PwmIo._systemd_escape("/sys/class/hwmon/hwmon8/pwm1_enable"),
		"-sys-class-hwmon-hwmon8-pwm1_enable"
	)


func test_systemd_escape_leaves_plain_digits_untouched() -> void:
	assert_eq(PwmIo._systemd_escape("255"), "255")


func test_systemd_escape_hex_escapes_percent() -> void:
	# Captured from a real device: `systemd-escape -- 'test%itest'`
	# produced this — confirms "%" (a systemd specifier character) is
	# neutralized, not passed through, avoiding specifier injection
	# into the unit's ExecStart when %i is expanded.
	assert_eq(PwmIo._systemd_escape("test%itest"), "test\\x25itest")


func test_systemd_escape_hex_escapes_literal_hyphen() -> void:
	# "-" is reserved as the substitution target for "/", so a literal
	# "-" in the input must itself be escaped rather than passed
	# through, or it would be ambiguous with an escaped "/".
	assert_eq(PwmIo._systemd_escape("a-b"), "a\\x2db")
