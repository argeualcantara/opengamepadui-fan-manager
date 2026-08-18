extends Node
class_name CustomCurveEngine

# keeps track of the curve being edited (the "draft") separately from the
# one actually applied to hardware (the "committed" curve), one engine per
# fan_id.
#
# set_point() only touches the draft - updates the value, keeps the curve
# non-decreasing, emits curve_changed, never writes to hardware. the
# committed curve only changes on start()/load_curve() (already-known-good,
# safe to apply right away) or commit_draft() (user pressed save).
#
# also owns a poll timer that keeps re-applying the committed curve, only
# started if the backend actually needs polling.

const FanBackend = preload("res://plugins/fan-manager/core/backends/fan_backend.gd")
const FanCurveUtils = preload("res://plugins/fan-manager/core/persistence/fan_curve_utils.gd")
const HardwareWriteQueue = preload("res://plugins/fan-manager/core/utils/hardware_write_queue.gd")

signal curve_changed(curve: Dictionary)

const DEFAULT_POLL_INTERVAL_SEC := 10.0

var logger := Log.get_logger("FanManager CustomCurveEngine")

# set by FanModeManager, null in tests that build this engine directly -
# falls back to applying synchronously then
var write_queue: HardwareWriteQueue

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


func start(backend: FanBackend, fan_id: String, curve: Dictionary) -> void:
	_backend = backend
	_fan_id = fan_id
	_curve = FanCurveUtils.normalize_keys(curve)
	_committed_curve = _curve.duplicate(true)

	var needs_polling = backend.requires_software_polling()
	if _poll_timer and needs_polling:
		_poll_timer.start()

	logger.info("Started custom curve engine for fan '%s'" % fan_id)
	_queue_apply()


# same as start() but reusing the currently attached backend/fan_id, used
# to load a saved profile into an already-running session. doesn't emit
# curve_changed, unlike set_point().
func load_curve(curve: Dictionary) -> void:
	if not _backend:
		logger.warn("Cannot load curve: engine has not been started yet")
		return
	start(_backend, _fan_id, curve)


func stop() -> void:
	if _poll_timer:
		_poll_timer.stop()

	if not _fan_id.is_empty():
		logger.info("Stopped custom curve engine for fan '%s'" % _fan_id)


func get_curve() -> Dictionary:
	return _curve.duplicate(true)


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

	var current_curve = get_curve()
	curve_changed.emit(current_curve)


# the only thing that turns a slider edit into an actual hardware write
func commit_draft() -> void:
	_committed_curve = _curve.duplicate(true)
	_queue_apply()


func _on_poll_timeout() -> void:
	_queue_apply()


# takes curve as a param instead of reading _committed_curve, so it's safe
# to run on write_queue's background thread without touching engine state
func _apply_curve(backend: FanBackend, fan_id: String, curve: Dictionary) -> void:
	if not backend or fan_id.is_empty() or curve.is_empty():
		return

	var applied_ok = backend.apply_custom_curve(fan_id, curve)
	if not applied_ok:
		logger.warn("Failed to apply custom curve to '%s'; will retry next cycle" % fan_id)


# hands backend/fan_id/curve to write_queue keyed by fan_id, so overlapping
# requests for the same fan coalesce instead of running at the same time.
# no write_queue set means just apply synchronously right here.
func _queue_apply() -> void:
	if not _backend or _fan_id.is_empty() or _committed_curve.is_empty():
		return

	var curve_copy = _committed_curve.duplicate(true)
	var job := _apply_curve.bind(_backend, _fan_id, curve_copy)

	if write_queue:
		write_queue.submit(_fan_id, job)
	else:
		job.call()
