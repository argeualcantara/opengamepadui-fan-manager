extends GutTest

var backend: AsusWmiFanBackend


func before_each() -> void:
	backend = AsusWmiFanBackend.new()


func test_requires_software_polling_is_false() -> void:
	assert_false(backend.requires_software_polling())


func test_set_mode_rejects_unknown_mode() -> void:
	assert_false(backend.set_mode("turbo"))


func test_reduce_to_hardware_points_keeps_curve_at_or_under_limit() -> void:
	var curve := {10: 0, 20: 0, 30: 20, 40: 35, 50: 50, 60: 65, 70: 80, 80: 90, 90: 100, 100: 100}
	var reduced := backend._reduce_to_hardware_points(curve)
	assert_eq(reduced.size(), 8)


func test_reduce_to_hardware_points_drops_the_two_coldest() -> void:
	var curve := {10: 0, 20: 0, 30: 20, 40: 35, 50: 50, 60: 65, 70: 80, 80: 90, 90: 100, 100: 100}
	var reduced := backend._reduce_to_hardware_points(curve)

	assert_false(reduced.has(10))
	assert_false(reduced.has(20))
	# The 8 hottest points must all survive untouched.
	for temp in [30, 40, 50, 60, 70, 80, 90, 100]:
		assert_true(reduced.has(temp), "expected %d to survive the reduction" % temp)
		assert_eq(reduced[temp], curve[temp])


func test_reduce_to_hardware_points_is_a_noop_under_the_limit() -> void:
	var curve := {10: 0, 20: 10, 30: 20}
	var reduced := backend._reduce_to_hardware_points(curve)
	assert_eq(reduced, curve)


func test_reduce_to_hardware_points_works_regardless_of_temperature_spacing() -> void:
	# 9 arbitrarily-spaced points: must still end up with exactly the
	# 8 hottest, regardless of shape.
	var curve := {
		11: 0, 22: 10, 33: 20, 44: 30, 55: 40, 66: 50, 77: 60, 88: 70, 99: 80
	}
	var reduced := backend._reduce_to_hardware_points(curve)

	assert_eq(reduced.size(), 8)
	assert_false(reduced.has(11), "coldest point must be the one dropped")


func test_validate_and_clamp_clamps_out_of_range_values() -> void:
	var curve := {10: -20.0, 20: 150.0}
	var validated := backend._validate_and_clamp(curve)
	assert_eq(validated[10], 0.0)
	assert_eq(validated[20], 100.0)


func test_validate_and_clamp_enforces_non_decreasing_curve() -> void:
	# 30 is higher than 40 and 50: those must be raised to match,
	# same "never decreasing" rule as CustomCurveEngine.set_point().
	var curve := {10: 0.0, 20: 10.0, 30: 80.0, 40: 20.0, 50: 30.0}
	var validated := backend._validate_and_clamp(curve)

	assert_eq(validated[30], 80.0)
	assert_eq(validated[40], 80.0)
	assert_eq(validated[50], 80.0)
	assert_eq(validated[20], 10.0, "points below the raised one must be untouched")


func test_validate_and_clamp_accepts_string_keys_from_json() -> void:
	var curve := {"10": 0, "20": 50}
	var validated := backend._validate_and_clamp(curve)
	assert_true(validated.has(10))
	assert_true(validated.has(20))
	assert_false(validated.has("10"))


# split_channel_fan_id() itself now lives on PwmIo (shared with
# HwmonFanBackend's own multi-fan discovery): see pwm_io_test.gd for
# its coverage. Nothing left here to test that's specific to this
# backend's use of it.


func test_get_fan_label_falls_back_to_generic_name_when_unreadable() -> void:
	# No real hwmon device on the test machine, so fan<N>_label is
	# unreadable both on the fan's own device and across every other
	# hwmon device scanned by _find_fan_label_across_hwmon(): exercises
	# the full fallback path without crashing.
	assert_eq(backend.get_fan_label("/sys/class/hwmon/hwmon8#1"), "Fan 1")
	assert_eq(backend.get_fan_label("/sys/class/hwmon/hwmon8#2"), "Fan 2")
