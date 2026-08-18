extends RefCounted
class_name PwmChannel

# one controllable fan channel, with all its sysfs paths already resolved at
# discovery time so callers don't have to re-parse fan_id and rebuild paths
# on every call.
#
# fan_id is stored directly instead of derived from hwmon_path/channel_id -
# each backend has its own fan_id format (hwmon keeps the bare path for
# channel 1, asus always uses "<path>#<channel>").
#
# points holds one PwmCurvePath per hardware curve point: hwmon only needs
# one (interpolated in software), asus can have up to 8 (full hw curve table)

const PwmCurvePath = preload("res://plugins/fan-manager/core/models/pwm_curve_path.gd")

var fan_id: String = ""
var hwmon_path: String = ""
var channel_id: int = -1
var fan_label: String = ""
var pwm_enable_path: String = ""

# read-only, for display/reporting. different from points[]'s paths on
# asus (those are the writable curve table axes), same file on hwmon
# (it just reads this to interpolate in software)
var readonly_temp_sensor_path: String = ""
var readonly_fan_speed_path: String = ""

var points: Array[PwmCurvePath] = []
