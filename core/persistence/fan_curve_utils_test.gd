extends GutTest

func test_normalize_keys_converts_string_keys_to_int() -> void:
	var normalized := FanCurveUtils.normalize_keys({"10": 5, "20": 10})
	assert_true(normalized.has(10))
	assert_true(normalized.has(20))
	assert_false(normalized.has("10"))


func test_interpolate_value_exact_point() -> void:
	var curve := {10: 0, 20: 0, 30: 20, 40: 35, 50: 50}
	assert_eq(FanCurveUtils.interpolate_value(curve, 30.0), 20.0)


func test_interpolate_value_between_points() -> void:
	var curve := {30: 20, 40: 35}
	assert_almost_eq(FanCurveUtils.interpolate_value(curve, 35.0), 27.5, 0.01)


func test_interpolate_value_clamps_below_lowest_point() -> void:
	var curve := {10: 5, 20: 10}
	assert_eq(FanCurveUtils.interpolate_value(curve, 0.0), 5.0)


func test_interpolate_value_clamps_above_highest_point() -> void:
	var curve := {90: 90, 100: 100}
	assert_eq(FanCurveUtils.interpolate_value(curve, 120.0), 100.0)


func test_interpolate_value_empty_curve_returns_zero() -> void:
	assert_eq(FanCurveUtils.interpolate_value({}, 50.0), 0.0)


func test_interpolate_value_accepts_string_keys() -> void:
	var curve := {"30": 20, "40": 35}
	assert_almost_eq(FanCurveUtils.interpolate_value(curve, 35.0), 27.5, 0.01)


func test_resample_to_fixed_points_covers_every_grid_point() -> void:
	# Hardware-reported curve with its own arbitrary (non-grid) points,
	# like AsusWmiFanBackend.get_bios_curve() might return.
	var curve := {15: 0, 35: 20, 65: 60, 95: 100}
	var resampled := FanCurveUtils.resample_to_fixed_points(curve)

	assert_eq(resampled.keys().size(), FanCurveUtils.FIXED_TEMPERATURE_POINTS.size())
	for temperature in FanCurveUtils.FIXED_TEMPERATURE_POINTS:
		assert_true(resampled.has(temperature), "missing grid point %d" % temperature)


func test_resample_to_fixed_points_interpolates_correctly() -> void:
	var curve := {15: 0, 35: 20, 65: 60, 95: 100}
	var resampled := FanCurveUtils.resample_to_fixed_points(curve)

	# 10°C is below the lowest known point (15) -> clamps to its value.
	assert_eq(resampled[10], 0.0)
	# 100°C is above the highest known point (95) -> clamps to its value.
	assert_eq(resampled[100], 100.0)
	# 30°C sits between 15 (0%) and 35 (20%).
	assert_almost_eq(resampled[30], 15.0, 0.01)


func test_resample_to_fixed_points_is_stable_on_already_aligned_curves() -> void:
	var curve := {10: 0, 20: 0, 30: 20, 40: 35, 50: 50, 60: 65, 70: 80, 80: 90, 90: 100, 100: 100}
	var resampled := FanCurveUtils.resample_to_fixed_points(curve)
	assert_eq(resampled, curve)
