extends RefCounted
class_name FanCurveUtils

## Shared helpers for working with fan curve Dictionaries, used by both
## FanBackend implementations and CustomCurveEngine so the same
## normalization rule isn't duplicated (and doesn't drift) across them.

## The 10 fixed temperature points the UI's curve editor always shows
## (REQUIREMENTS.md §2.3, 10-100°C step 10).
const FIXED_TEMPERATURE_POINTS: Array[int] = [10, 20, 30, 40, 50, 60, 70, 80, 90, 100]

## Name of the built-in profile FanModeManager creates automatically
## the first time Custom Mode is entered on a given hardware with no
## profile chosen yet (instead of seeding from a possibly-stale
## BIOS-reported curve).
const DEFAULT_PROFILE_NAME := "Default"

## A gentle, generally-safe starting curve: silent at idle, ramping up
## through the 40-70°C range most handhelds actually live in under
## load, maxing out at 90°C. Deliberately not read from hardware:
## see FanModeManager._start_custom_mode().
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


## Normalizes a fan curve Dictionary's temperature keys to int. Curves
## loaded from JSON persistence (REQUIREMENTS.md §3) always have String
## keys, since JSON object keys are always strings; curves built
## in-memory (e.g. FanBackend.get_bios_curve()) may already use int
## keys. Callers should normalize at every boundary where a curve may
## have come from disk, rather than assuming a fixed key type.
static func normalize_keys(curve: Dictionary) -> Dictionary:
	var normalized := {}
	for key in curve.keys():
		var temp_key: int = int(key) if key is String else key
		normalized[temp_key] = curve[key]
	return normalized


## Linearly interpolates the fan percent for the given temperature from
## an arbitrary (possibly sparse, possibly non-grid-aligned) curve.
## Temperatures below the lowest known point use that point's value;
## above the highest known point use that point's value. Returns 0.0
## for an empty curve.
static func interpolate_value(curve: Dictionary, temperature: float) -> float:
	var normalized := normalize_keys(curve)
	var points: Array = normalized.keys()
	points.sort()

	if points.is_empty():
		return 0.0

	var lowest: int = points[0]
	var highest: int = points[-1]

	if temperature <= lowest:
		return normalized[lowest]
	if temperature >= highest:
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
			return lerp(lower_percent, upper_percent, t)

	return normalized[highest]


## Resamples an arbitrary curve onto FIXED_TEMPERATURE_POINTS via
## interpolate_value(). Use this whenever a curve may not already be
## aligned to the UI's fixed grid: e.g. a hardware-reported curve
## (FanBackend.get_bios_curve()) that has its own arbitrary points, as
## opposed to a saved profile, which is always already grid-aligned
## since it was created by this editor in the first place.
static func resample_to_fixed_points(curve: Dictionary) -> Dictionary:
	var resampled := {}
	for temperature in FIXED_TEMPERATURE_POINTS:
		resampled[temperature] = interpolate_value(curve, temperature)
	return resampled
