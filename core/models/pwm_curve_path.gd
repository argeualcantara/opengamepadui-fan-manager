extends RefCounted
class_name PwmCurvePath

## One point's worth of sysfs paths for a hardware fan curve table:
## where to read/write the temperature axis, and where to read/write
## the fan-speed axis, for a single point.
##
## HwmonFanBackend uses exactly one of these per PwmChannel (temp_path
## read-only, fan_speed_path read/write, since the curve itself is
## interpolated in software and only the resulting speed is written).
## AsusWmiFanBackend uses up to 8 per PwmChannel, one per hardware
## curve point (both temp_path and fan_speed_path are written, since
## the whole table is uploaded to the driver at once). See PwmChannel.

var temp_path: String = ""
var fan_speed_path: String = ""
