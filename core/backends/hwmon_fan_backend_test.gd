extends GutTest

## These tests cover the pure logic of HwmonFanBackend (fan channel
## resolution) that doesn't depend on reading/writing real hwmon sysfs
## files. Actual I/O against /sys/class/hwmon is validated manually per
## tasks/10-testes-validacao.md. Curve interpolation is covered in
## fan_curve_utils_test.gd; PWM<->percent conversion in pwm_io_test.gd
## — this backend just calls those directly, nothing left to test here.

var backend: HwmonFanBackend


func before_each() -> void:
	backend = HwmonFanBackend.new()


func test_set_mode_rejects_unknown_mode() -> void:
	assert_false(backend.set_mode("turbo"))


func test_requires_software_polling_defaults_to_true() -> void:
	# HwmonFanBackend doesn't override this: it must inherit FanBackend's
	# default, since the generic hwmon interface has no native curve
	# support and needs FanModeManager to keep polling.
	assert_true(backend.requires_software_polling())


func test_resolve_fan_channels_splits_on_exact_matched_channels() -> void:
	# Handheld case: pwm1/pwm2 (CPU/GPU) each with their own temp
	# sensor, same channel numbers on both sides.
	var channels := backend._resolve_fan_channels([1, 2], [1, 2])
	assert_eq(channels, [1, 2])


func test_resolve_fan_channels_falls_back_to_single_fan_on_count_mismatch() -> void:
	# pwm2 exists but temp2_input doesn't: no reliable way to pair it,
	# so only the historical single fan (channel 1) is reported.
	var channels := backend._resolve_fan_channels([1, 2], [1])
	assert_eq(channels, [1])


func test_resolve_fan_channels_falls_back_to_single_fan_on_channel_mismatch() -> void:
	# Same channel count on both sides, but not the same channels: a
	# bare size comparison would wrongly accept this as paired.
	var channels := backend._resolve_fan_channels([1, 2], [1, 3])
	assert_eq(channels, [1])


func test_resolve_fan_channels_single_channel_is_unchanged() -> void:
	# Today's common case (one fan, one temp sensor): still resolves to
	# channel 1 only, not the multi-fan path.
	var channels := backend._resolve_fan_channels([1], [1])
	assert_eq(channels, [1])


func test_resolve_fan_channels_returns_empty_when_channel_1_missing() -> void:
	var channels := backend._resolve_fan_channels([], [])
	assert_eq(channels, [])
