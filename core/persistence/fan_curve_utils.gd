extends RefCounted
class_name FanCurveUtils

## Shared helpers for working with fan curve Dictionaries, used by both
## FanBackend implementations and CustomCurveEngine so normalization
## logic isn't duplicated.

static var logger := Log.get_logger("FanManager FanCurveUtils")

## The 10 fixed temperature points the UI's curve editor always shows
## (10-100°C, step 10).
const FIXED_TEMPERATURE_POINTS: Array[int] = [10, 20, 30, 40, 50, 60, 70, 80, 90, 100]

## Name of the built-in profile FanModeManager creates automatically
## the first time Custom Mode is entered with no profile chosen yet.
const DEFAULT_PROFILE_NAME := "Default"

## A gentle, generally-safe starting curve: silent at idle, ramping up
## through 40-70°C, maxing out at 90°C. Deliberately not read from
## hardware: see FanModeManager._start_custom_mode().
const DEFAULT_BALANCED_CURVE := {
	10: 0.0,
	20: 0.0,
	30: 20.0,
	40: 35.0,
	50: 50.0,
	60: 65.0,
	70: 80.0,
	80: 90.0,
	90: 100.0,
	100: 100.0,
}


## Normalizes curve's temperature keys to int. Curves loaded from JSON
## always have String keys; in-memory curves may already use int keys.
static func normalize_keys(curve: Dictionary) -> Dictionary:
	var normalized := {}
	var converted := 0
	for key in curve.keys():
		var temp_key: int = int(key) if key is String else key
		if key is String:
			converted += 1
		normalized[temp_key] = curve[key]
	if converted > 0:
		logger.debug("normalize_keys(): converted %d String key(s) to int" % converted)
	return normalized


## Linearly interpolates the fan percent for temperature from an
## arbitrary (possibly sparse) curve. Clamps to the lowest/highest
## known point outside their range. Returns 0.0 for an empty curve.
static func interpolate_value(curve: Dictionary, temperature: float) -> float:
	var normalized := normalize_keys(curve)
	var points: Array = normalized.keys()
	points.sort()

	if points.is_empty():
		logger.debug("interpolate_value(): empty curve, returning 0.0")
		return 0.0

	var lowest: int = points[0]
	var highest: int = points[-1]

	if temperature <= lowest:
		logger.debug("interpolate_value(%.1f°C): below lowest point %d, clamping" % [temperature, lowest])
		return normalized[lowest]
	if temperature >= highest:
		logger.debug("interpolate_value(%.1f°C): above highest point %d, clamping" % [temperature, highest])
		return normalized[highest]

	for i in range(points.size() - 1):
		var lower_temp: int = points[i]
		var upper_temp: int = points[i + 1]
		if temperature >= lower_temp and temperature <= upper_temp:
			var lower_percent: float = normalized[lower_temp]
			var upper_percent: float = normalized[upper_temp]
			var span := float(upper_temp - lower_temp)
			if span <= 0.0:
				return lower_percent
			var t := (temperature - lower_temp) / span
			var result := lerp(lower_percent, upper_percent, t)
			logger.debug(
				"interpolate_value(%.1f°C): between %d°C(%.1f%%) and %d°C(%.1f%%) -> %.1f%%"
				% [temperature, lower_temp, lower_percent, upper_temp, upper_percent, result]
			)
			return result

	return normalized[highest]


## Resamples curve onto FIXED_TEMPERATURE_POINTS via interpolate_value().
## Use when a curve isn't already grid-aligned, e.g. a hardware-reported
## curve with its own arbitrary points.
static func resample_to_fixed_points(curve: Dictionary) -> Dictionary:
	var resampled := {}
	for temperature in FIXED_TEMPERATURE_POINTS:
		resampled[temperature] = interpolate_value(curve, temperature)
	logger.debug("resample_to_fixed_points(%s) -> %s" % [curve, resampled])
	return resampled
