extends RefCounted
class_name PwmChannel

## A single controllable fan channel, with every sysfs path it needs
## already resolved once at discovery time — callers (backend instance
## methods) look this up by fan_id and use its fields directly,
## instead of re-parsing fan_id and rebuilding "%s/pwm%d..." paths on
## every call (the old PwmIo.split_channel_fan_id()-based pattern).
##
## fan_id is stored directly, not derived from hwmon_path/channel_id:
## each backend owns its own fan_id format/compatibility rules
## (HwmonFanBackend's bare-path-for-channel-1 legacy exception vs.
## AsusWmiFanBackend always using "<path>#<channel>"), and deriving it
## generically here couldn't express both without backend-specific
## branching inside a supposedly-generic model class.
##
## points holds one PwmCurvePath per hardware curve point:
## HwmonFanBackend uses exactly one (the live temp/speed pair it
## polls and interpolates in software); AsusWmiFanBackend uses up to
## 8 (the full hardware curve table).

## External, persisted identity — same string shape saved.gd's
## game_curves/profiles dictionaries already use as keys today.
var fan_id: String = ""

## The hwmon device directory this channel belongs to (e.g.
## "/sys/class/hwmon/hwmon8"), kept as its own field for reference
## even though fan_id isn't derived from it.
var hwmon_path: String = ""

## The "<N>" in pwm<N>/pwm<N>_enable for this channel.
var channel_id: int = -1

## Human-readable label (e.g. "CPU", "GPU"), resolved once at
## discovery instead of re-scanning hwmon on every get_fan_label() call.
var fan_label: String = ""

## pwm<N>_enable path: switches this channel between automatic
## (firmware/EC controlled) and manual (accepts written values).
var enable_path: String = ""

## Live, read-only temperature sensor path (e.g. temp<N>_input),
## used by read_temperature() for display/reporting. Distinct from
## points[]'s temp_path: for AsusWmiFanBackend these are different
## files (temp_sensor_path is a plain sensor reading; points[].temp_path
## is the writable temperature axis of the uploaded curve table).
## HwmonFanBackend's single point happens to reuse the same path for
## both, since it reads this sensor to interpolate the curve in
## software rather than uploading a hardware table.
var temp_sensor_path: String = ""

## Live, read-only fan-speed readback path (e.g. bare pwm<N>), used by
## read_fan_percent() for display/reporting. Distinct from points[]'s
## fan_speed_path for the same reason as temp_sensor_path above: for
## AsusWmiFanBackend, this is a plain duty-cycle readback register,
## separate from any of the 8 curve-table points. HwmonFanBackend's
## single point reuses the same path here too, since pwm<N> is both
## where it writes the computed speed and where it reads it back.
var fan_speed_readback_path: String = ""

var points: Array[PwmCurvePath] = []
