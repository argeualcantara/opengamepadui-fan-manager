extends Node
class_name CustomCurveEngine

## Tracks the curve being edited (the "draft") separately from the
## curve applied to hardware (the "committed" curve), for a single fan
## (one engine instance per fan_id; ModeSelectOverlay owns one per
## fan).
##
## set_point() only touches the draft: updates the value, enforces
## non-decreasing monotonicity, emits curve_changed, never writes to
## hardware. The committed curve only changes on start()/load_curve()
## (already-known-good curves, safe to apply right away) or
## commit_draft() (user explicitly saves).
##
## Owns a steady-state poll timer that re-applies the committed curve
## on an interval; only started when the backend needs it
## (requires_software_polling() == true).
##
## Referenced via preload()'d consts, not bare class_name lookups: see
## hwmon_fan_backend.gd's header comment for why.
const FanBackend = preload("res://plugins/fan-manager/core/backends/fan_backend.gd")
const FanCurveUtils = preload("res://plugins/fan-manager/core/persistence/fan_curve_utils.gd")

signal curve_changed(curve: Dictionary)

const DEFAULT_POLL_INTERVAL_SEC := 2.0

var logger := Log.get_logger("FanManager CustomCurveEngine")

var poll_interval_sec: float = DEFAULT_POLL_INTERVAL_SEC:
	set(value):
		poll_interval_sec = value
		if _poll_timer:
			_poll_timer.wait_time = value

var _backend: FanBackend
var _fan_id: String = ""
var _curve: Dictionary = {}
var _committed_curve: Dictionary = {}

var _poll_timer: Timer


func _ready() -> void:
	_poll_timer = Timer.new()
	_poll_timer.wait_time = poll_interval_sec
	_poll_timer.one_shot = false
	_poll_timer.timeout.connect(_on_poll_timeout)
	add_child(_poll_timer)


## Attaches to backend/fan_id, sets draft and committed curve to
## curve, and applies it immediately (an already-known-good curve, not
## a mid-edit draft). curve's temperature keys may be String or int;
## normalized on entry. Starts the poll timer only if
## backend.requires_software_polling() is true.
func start(backend: FanBackend, fan_id: String, curve: Dictionary) -> void:
	_backend = backend
	_fan_id = fan_id
	_curve = FanCurveUtils.normalize_keys(curve)
	_committed_curve = _curve.duplicate(true)

	if _poll_timer and backend.requires_software_polling():
		_poll_timer.start()

	logger.info("Started custom curve engine for fan '%s'" % fan_id)
	_apply_now()


## Same as start(), reusing the currently attached backend/fan_id: used
## to load a saved profile into an already-running session. Unlike
## set_point(), does not emit curve_changed.
func load_curve(curve: Dictionary) -> void:
	if not _backend:
		logger.warn("Cannot load curve: engine has not been started yet")
		return
	start(_backend, _fan_id, curve)


## Stops polling. Does not revert the fan's mode/pwm value on hardware
## (FanModeManager handles switching modes).
func stop() -> void:
	if _poll_timer:
		_poll_timer.stop()

	if not _fan_id.is_empty():
		logger.info("Stopped custom curve engine for fan '%s'" % _fan_id)


## Returns a copy of the draft curve, including uncommitted changes.
func get_curve() -> Dictionary:
	return _curve.duplicate(true)


## Sets temperature's fan percent on the draft curve, pushing any
## higher/lower points that would make the curve decrease. In-memory
## only, never writes to hardware; emits curve_changed. Call
## commit_draft() to actually apply.
func set_point(temperature: int, percent: float) -> void:
	var clamped := clampf(percent, 0.0, 100.0)
	_curve[temperature] = clamped

	var pushed: Array[int] = []
	var points: Array = _curve.keys()
	points.sort()
	for point in points:
		if point > temperature and float(_curve[point]) < clamped:
			_curve[point] = clamped
			pushed.append(point)
		elif point < temperature and float(_curve[point]) > clamped:
			_curve[point] = clamped
			pushed.append(point)

	if not pushed.is_empty():
		logger.debug(
			"set_point(%d, %.1f) pushed point(s) %s to keep the curve non-decreasing"
			% [temperature, clamped, pushed]
		)

	curve_changed.emit(get_curve())


## Promotes the draft to the committed curve and applies it to hardware.
## The only thing that turns slider edits into an actual hardware write.
func commit_draft() -> void:
	_committed_curve = _curve.duplicate(true)
	_apply_now()


func _on_poll_timeout() -> void:
	_apply_now()


func _apply_now() -> void:
	if not _backend or _fan_id.is_empty() or _committed_curve.is_empty():
		return

	if not _backend.apply_custom_curve(_fan_id, _committed_curve):
		logger.warn("Failed to apply custom curve to '%s'; will retry next cycle" % _fan_id)
