extends RefCounted
class_name PwmCurvePath

# sysfs paths for one point of a hardware fan curve table: where to
# read/write temp, where to read/write fan speed.
#
# hwmon only uses one of these per PwmChannel (temp read-only, speed
# read/write - curve is interpolated in software). asus uses up to 8 per
# channel, one per curve point, both paths written since the whole table
# gets uploaded at once.

var temp_path: String = ""
var fan_speed_path: String = ""
