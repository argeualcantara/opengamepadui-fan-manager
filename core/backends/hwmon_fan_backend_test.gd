extends GutTest

## These tests cover the pure logic of HwmonFanBackend (curve
## interpolation, PWM<->percent conversion) that doesn't depend on
## reading/writing real hwmon sysfs files. Actual I/O against
## /sys/class/hwmon is validated manually per
## tasks/10-testes-validacao.md.

var backend: HwmonFanBackend


func before_each() -> void:
	backend = HwmonFanBackend.new()


func test_interpolate_curve_exact_point() -> void:
	var curve := {10: 0, 20: 0, 30: 20, 40: 35, 50: 50}
	assert_eq(backend._interpolate_curve(curve, 30.0), 20.0)


func test_interpolate_curve_between_points() -> void:
	var curve := {30: 20, 40: 35}
	# Midpoint between 30->20% and 40->35% should be 27.5%.
	assert_almost_eq(backend._interpolate_curve(curve, 35.0), 27.5, 0.01)


func test_interpolate_curve_below_lowest_point_clamps() -> void:
	var curve := {10: 5, 20: 10}
	assert_eq(backend._interpolate_curve(curve, 0.0), 5.0)


func test_interpolate_curve_above_highest_point_clamps() -> void:
	var curve := {90: 90, 100: 100}
	assert_eq(backend._interpolate_curve(curve, 120.0), 100.0)


func test_interpolate_curve_empty_returns_zero() -> void:
	assert_eq(backend._interpolate_curve({}, 50.0), 0.0)


func test_interpolate_curve_accepts_string_keys_from_json() -> void:
	# Dictionaries loaded via JSON.parse_string() always have String
	# keys ("10", "20", ...), never int: this must interpolate the
	# same as the int-keyed equivalent.
	var curve := {"10": 0, "20": 0, "30": 20, "40": 35, "50": 50}
	assert_eq(backend._interpolate_curve(curve, 30.0), 20.0)
	assert_almost_eq(backend._interpolate_curve(curve, 35.0), 27.5, 0.01)


func test_interpolate_curve_sorts_string_keys_numerically() -> void:
	# Lexicographic sort would place "100" before "20"; must sort as numbers.
	var curve := {"10": 10, "20": 20, "100": 100}
	assert_eq(backend._interpolate_curve(curve, 20.0), 20.0)
	assert_eq(backend._interpolate_curve(curve, 100.0), 100.0)


func test_normalize_curve_keys_converts_string_keys_to_int() -> void:
	var normalized := FanCurveUtils.normalize_keys({"10": 5, "20": 10})
	assert_true(normalized.has(10))
	assert_true(normalized.has(20))
	assert_false(normalized.has("10"))


func test_percent_to_pwm_roundtrip_bounds() -> void:
	assert_eq(backend._percent_to_pwm(0.0), 0)
	assert_eq(backend._percent_to_pwm(100.0), 255)
	assert_eq(backend._percent_to_pwm(50.0), 128)


func test_percent_to_pwm_clamps_out_of_range() -> void:
	assert_eq(backend._percent_to_pwm(-10.0), 0)
	assert_eq(backend._percent_to_pwm(150.0), 255)


func test_pwm_to_percent_bounds() -> void:
	assert_almost_eq(backend._pwm_to_percent(0), 0.0, 0.01)
	assert_almost_eq(backend._pwm_to_percent(255), 100.0, 0.01)


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
