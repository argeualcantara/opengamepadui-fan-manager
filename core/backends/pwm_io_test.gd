extends GutTest

## Covers PwmIo.split_channel_fan_id(), shared by every backend that
## can control more than one independent fan on the same device
## (AsusWmiFanBackend always, HwmonFanBackend when it discovers matched
## pwm<N>/temp<N>_input channels). percent_to_pwm()/pwm_to_percent()
## and the actual sysfs I/O are exercised indirectly through the
## backends that use them (see hwmon_fan_backend_test.gd), not here.


func test_split_channel_fan_id_extracts_device_and_channel() -> void:
	var parts := PwmIo.split_channel_fan_id("/sys/class/hwmon/hwmon7#2")
	assert_eq(parts["device"], "/sys/class/hwmon/hwmon7")
	assert_eq(parts["channel"], 2)


func test_split_channel_fan_id_defaults_channel_1_for_a_bare_device_path() -> void:
	# Tolerates an old-format fan_id (no "#channel") instead of hard
	# failing: this is also single-fan hardware's normal, permanent
	# fan_id shape (see HwmonFanBackend's backward-compatibility note
	# on _resolve_fan_channels()), not just a fallback for stale data.
	var parts := PwmIo.split_channel_fan_id("/sys/class/hwmon/hwmon7")
	assert_eq(parts["device"], "/sys/class/hwmon/hwmon7")
	assert_eq(parts["channel"], 1)
