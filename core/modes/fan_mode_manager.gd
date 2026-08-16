extends Node
class_name FanModeManager

## Orchestrates switching between BIOS and Custom fan modes: detects
## the active FanBackend, stops the previous mode's activity before
## applying the new one, persists the active mode, and reapplies it on
## startup.
##
## Referenced via preload()'d consts, not bare class_name lookups: see
## hwmon_fan_backend.gd's header comment for why.

const FanBackendRegistry = preload("res://plugins/fan-manager/core/backends/fan_backend_registry.gd")
const FanCurveStore = preload("res://plugins/fan-manager/core/persistence/fan_curve_store.gd")
const CustomCurveEngine = preload("res://plugins/fan-manager/core/engine/custom_curve_engine.gd")
const FanBackend = preload("res://plugins/fan-manager/core/backends/fan_backend.gd")
const FanCurveUtils = preload("res://plugins/fan-manager/core/persistence/fan_curve_utils.gd")
const HardwareWriteQueue = preload("res://plugins/fan-manager/core/utils/hardware_write_queue.gd")

## user_initiated distinguishes a real user action (the dropdown) from
## a mode change that's a side effect of something else (restoring a
## saved per-game context, reapplying the saved mode on boot) —
## GameCurveManager uses this to decide whether to commit a
## game_curves snapshot: without it, GameCurveManager._apply_context()
## restoring a saved context's mode would immediately re-trigger a
## commit for that same context, right after loading it.
signal fan_mode_changed(mode: String, user_initiated: bool)

const VALID_MODES := ["bios", "custom"]

var logger := Log.get_logger("FanManager FanModeManager")

var registry: FanBackendRegistry
var store: FanCurveStore
var write_queue: HardwareWriteQueue

## One CustomCurveEngine per fan_id, created lazily as fans are
## discovered.
var curve_engines: Dictionary = {}

var backend: FanBackend
var hardware_id: String = ""
var current_mode: String = ""


func _init(p_registry: FanBackendRegistry, p_store: FanCurveStore, p_write_queue: HardwareWriteQueue = null) -> void:
	registry = p_registry
	store = p_store
	write_queue = p_write_queue


func _ready() -> void:
	backend = registry.detect()
	if not backend:
		logger.warn("No fan backend available; fan mode management disabled")
		return

	hardware_id = backend.get_hardware_id()
	logger.debug("Using backend '%s' for hardware '%s'" % [backend.get_script().get_global_name(), hardware_id])

	if not store.exists(hardware_id):
		# First run for this hardware: adopt whatever mode it's already
		# in instead of writing an assumed default.
		_adopt_current_hardware_mode()
		store.flush()
		return

	var data: Dictionary = store.load_data(hardware_id)
	var saved_mode: String = data.get("active_mode", "bios")
	logger.debug("Reapplying saved mode '%s' on startup" % saved_mode)

	if not set_mode(saved_mode):
		logger.warn(
			"Failed to reapply saved mode '%s' on startup, falling back to bios" % saved_mode
		)
		set_mode("bios")
	store.flush()


func _adopt_current_hardware_mode() -> void:
	var detected := backend.get_current_mode()
	logger.debug("_adopt_current_hardware_mode(): backend reports current mode '%s'" % detected)
	if detected not in VALID_MODES:
		logger.debug("'%s' is not a valid mode, defaulting to 'bios'" % detected)
		detected = "bios"

	current_mode = detected
	_persist_active_mode(detected)

	# Not _start_custom_mode(): that creates the built-in "Default"
	# profile, overwriting the hardware's existing curve. Read back
	# what's actually active instead.
	if detected == "custom":
		_adopt_current_custom_curve()

	fan_mode_changed.emit(detected, false)
	logger.info(
		"First run for hardware '%s': adopted current mode '%s' without writing pwm1_enable"
		% [hardware_id, detected]
	)


## Switches to the given mode ("bios" or "custom"), cleanly stopping
## the previous mode's activity first. Persists the new mode
## optimistically and returns true as soon as the switch is queued;
## the actual backend write happens on write_queue and is only logged
## if it fails. Returns false (and logs) only for an invalid mode or
## no backend.
##
## user_initiated (default false, safe-by-default: a call site that
## doesn't think about this explicitly ends up not committing, never
## spuriously committing) — see fan_mode_changed's doc comment.
func set_mode(mode: String, user_initiated: bool = false) -> bool:
	if not backend:
		logger.error("Cannot set mode '%s': no fan backend available" % mode)
		return false

	if mode not in VALID_MODES:
		logger.error("Unknown fan mode '%s'" % mode)
		return false

	# Already in this mode: skip the stop/restart cycle entirely. This
	# matters for GameCurveManager, which calls set_mode("custom") to
	# restore a per-context config even when already in Custom Mode
	# (switching contexts never leaves Custom Mode), without this
	# guard, _start_custom_mode() would reuse whichever curve is
	# currently in memory (the previous context's) and briefly reapply
	# it to hardware, and the resulting fan_mode_changed emission would
	# trigger a premature snapshot save with that stale curve, before
	# the caller gets a chance to load the correct context's curve.
	if mode == current_mode:
		logger.debug("set_mode('%s'): already in this mode" % mode)
		return true

	var previous_mode := current_mode if not current_mode.is_empty() else "(none)"
	logger.debug("set_mode('%s'): stopping %d curve engine(s) from previous mode '%s'" % [mode, curve_engines.size(), previous_mode])

	# Stop the previous mode's activity before touching the backend.
	for engine in curve_engines.values():
		engine.stop()

	_queue_backend_mode_write(mode)

	if mode == "custom":
		_start_custom_mode()

	current_mode = mode
	_persist_active_mode(mode)
	fan_mode_changed.emit(mode, user_initiated)
	logger.info("Switched fan mode from '%s' to '%s'" % [previous_mode, mode])
	return true


## Queues backend.set_mode(mode), keyed "mode" so rapid switches
## coalesce instead of running concurrently. Falls back to a
## synchronous call if no write_queue is set.
func _queue_backend_mode_write(mode: String) -> void:
	var backend_ref := backend
	var job := func():
		if not backend_ref.set_mode(mode):
			logger.error("Backend failed to switch to mode '%s'" % mode)

	if write_queue:
		write_queue.submit("mode", job)
	else:
		job.call()


func get_curve_engine(fan_id: String) -> CustomCurveEngine:
	return curve_engines.get(fan_id)


func get_all_curve_engines() -> Dictionary:
	return curve_engines


func _ensure_curve_engine(fan_id: String) -> CustomCurveEngine:
	if curve_engines.has(fan_id):
		return curve_engines[fan_id]

	logger.debug("Creating new CustomCurveEngine for fan '%s'" % fan_id)
	var engine := CustomCurveEngine.new()
	engine.write_queue = write_queue
	add_child(engine)
	curve_engines[fan_id] = engine
	return engine


## Applies a curve to every fan reported by the backend, seeded from
## the "__default__" game_curves context (FanCurveUtils.
## GLOBAL_DEFAULT_CONTEXT_KEY) — the single shared curve GameCurveManager
## also reads/writes whenever per-game tracking is off. Created here,
## built-in balanced, the first time this ever runs for a hardware_id.
func _start_custom_mode() -> void:
	var fans := backend.list_fans()
	if fans.is_empty():
		logger.error("Cannot start custom mode: no fans available")
		return

	var data: Dictionary = store.load_data(hardware_id)
	var game_curves: Dictionary = data.get("game_curves", {})
	var default_entry: Dictionary = game_curves.get(FanCurveUtils.GLOBAL_DEFAULT_CONTEXT_KEY, {})
	var default_curves: Dictionary = default_entry.get("curve", {})
	logger.debug("_start_custom_mode(): fans=%s default_curves=%s" % [fans, default_curves.keys()])

	if default_curves.is_empty():
		# Nothing saved yet: create the built-in balanced default,
		# applied identically to every fan.
		for fan_id in fans:
			default_curves[fan_id] = FanCurveUtils.DEFAULT_BALANCED_CURVE.duplicate()
		store.set_game_curve(FanCurveUtils.GLOBAL_DEFAULT_CONTEXT_KEY, "custom", default_curves)
		logger.info(
			"Created built-in default curve ('%s' context) for hardware '%s'"
			% [FanCurveUtils.GLOBAL_DEFAULT_CONTEXT_KEY, hardware_id]
		)

	for fan_id in fans:
		var engine := _ensure_curve_engine(fan_id)

		# Reuse in-memory curve on re-entry so unsaved edits survive a
		# round trip through another mode.
		var curve: Dictionary = engine.get_curve()
		if curve.is_empty():
			curve = default_curves.get(fan_id, FanCurveUtils.DEFAULT_BALANCED_CURVE.duplicate())
			logger.debug("Fan '%s': no in-memory curve, seeding from default/balanced" % fan_id)
		else:
			logger.debug("Fan '%s': reusing in-memory curve from previous session" % fan_id)

		engine.start(backend, fan_id, curve)


## Used by _adopt_current_hardware_mode() when the hardware was already
## in custom mode before the plugin ran. Reads back the curve actually
## active per fan, without creating/using the "Default" profile.
func _adopt_current_custom_curve() -> void:
	var fans := backend.list_fans()
	if fans.is_empty():
		return

	for fan_id in fans:
		var curve := FanCurveUtils.resample_to_fixed_points(backend.get_bios_curve(fan_id))
		logger.debug("_adopt_current_custom_curve(): fan '%s' -> %s" % [fan_id, curve])
		var engine := _ensure_curve_engine(fan_id)
		engine.start(backend, fan_id, curve)


## In-memory only, no disk write here. Callers (_ready(),
## _apply_context() via GameCurveManager, ModeSelectOverlay) are
## responsible for calling store.flush() once their own top-level
## operation is fully done.
func _persist_active_mode(mode: String) -> void:
	logger.debug("Persisting active_mode='%s' for hardware '%s'" % [mode, hardware_id])
	store.load_data(hardware_id)
	store.set_active_mode(mode)
