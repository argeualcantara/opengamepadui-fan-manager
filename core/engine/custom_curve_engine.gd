extends Node
class_name CustomCurveEngine

## Tracks the curve being edited (the "draft") separately from the
## curve actually applied to hardware (the "committed" curve) for a
## single fan: REQUIREMENTS.md §2.3, §4.
##
## Dragging a slider (set_point()) only ever touches the draft: it
## updates the in-memory value, enforces the "no decreasing curve"
## rule, and emits curve_changed so the UI can show the result live:
## it never writes to hardware. The committed curve only changes (and
## gets written) when the caller explicitly commits it: on start()/
## load_curve() (switching mode, selecting a saved profile: both
## already-known-good curves, safe to apply right away) or on
## commit_draft() (the user clicked "Save current profile").
##
## Owns one timer: a steady-state poll timer that re-applies the
## *committed* curve on an interval, reacting to temperature changes.
## Backends that don't need that (requires_software_polling() ==
## false) never get it started.
##
## Only tracks one fan at a time: multi-fan support is out of scope
## for v1 (see REQUIREMENTS.md §5).
##
## FanBackend/FanCurveUtils below are referenced via preload()'d consts,
## not bare class_name lookups (see hwmon_fan_backend.gd's header
## comment / tasks/17-fix-class-name-resolution-em-plugin-empacotado.md).
const FanBackend = preload("res://plugins/fan-manager/core/backends/fan_backend.gd")
const FanCurveUtils = preload("res://plugins/fan-manager/core/persistence/fan_curve_utils.gd")

signal curve_changed(curve: Dictionary)

const DEFAULT_POLL_INTERVAL_SEC := 2.0

var logger := Log.get_logger("CustomCurveEngine")

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


## Attaches to `backend`/`fan_id`, sets both the draft and the
## committed curve to `curve`, and applies it immediately: this is an
## already-known-good curve (a saved profile, the built-in default, or
## whatever was active before a mode switch), not a mid-edit draft, so
## applying right away is safe and expected. `curve` may have String or
## int temperature keys (see FanCurveUtils.normalize_keys): it's
## normalized on entry.
##
## Only starts the periodic re-poll timer when
## `backend.requires_software_polling()` is true: backends that follow
## an uploaded curve on their own don't need the steady-state timer
## re-applying on temperature changes.
func start(backend: FanBackend, fan_id: String, curve: Dictionary) -> void:
	_backend = backend
	_fan_id = fan_id
	_curve = FanCurveUtils.normalize_keys(curve)
	_committed_curve = _curve.duplicate(true)

	if _poll_timer and backend.requires_software_polling():
		_poll_timer.start()

	logger.info("Started custom curve engine for fan '%s'" % fan_id)
	_apply_now()


## Same as start(), reusing whichever backend/fan_id the engine is
## already attached to: used to load a saved profile into an
## already-running Custom Mode session. Unlike set_point(), does not
## emit curve_changed (callers that need to resync a UI after loading
## should do so directly from the curve they just loaded).
func load_curve(curve: Dictionary) -> void:
	if not _backend:
		logger.warn("Cannot load curve: engine has not been started yet")
		return
	start(_backend, _fan_id, curve)


## Stops polling. Does not revert the fan's current mode/pwm value on
## the hardware: FanModeManager is responsible for switching the
## backend to a different mode afterwards.
func stop() -> void:
	if _poll_timer:
		_poll_timer.stop()

	if not _fan_id.is_empty():
		logger.info("Stopped custom curve engine for fan '%s'" % _fan_id)


## Returns a copy of the draft curve: i.e. what's currently displayed/
## being edited, including any not-yet-committed changes.
func get_curve() -> Dictionary:
	return _curve.duplicate(true)


## Sets a single temperature point's fan percent on the draft curve,
## enforcing bidirectional monotonicity (REQUIREMENTS.md §2.3): raising
## this point above any higher-temperature point's current value raises
## those too, and lowering it below any lower-temperature point's
## current value lowers those too: the same rule applies symmetrically
## in both directions, so the curve can never end up decreasing
## regardless of which way the user drags.
##
## Purely an in-memory edit: never writes to hardware. Emits
## curve_changed immediately so the UI can reflect any pushed points;
## call commit_draft() to actually apply the draft.
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


## Promotes the current draft to the committed curve and applies it to
## hardware right away. This is the only thing that turns slider edits
## into an actual hardware write: call it when the user explicitly
## saves (see ProfileManagerPanel._commit_save()).
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
