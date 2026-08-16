extends Node
class_name FanModeManager

# switches between bios/custom fan mode, stops the old mode before starting
# the new one, persists it, reapplies on startup.

const FanBackendRegistry = preload("res://plugins/fan-manager/core/backends/fan_backend_registry.gd")
const FanCurveStore = preload("res://plugins/fan-manager/core/persistence/fan_curve_store.gd")
const CustomCurveEngine = preload("res://plugins/fan-manager/core/engine/custom_curve_engine.gd")
const FanBackend = preload("res://plugins/fan-manager/core/backends/fan_backend.gd")
const FanCurveUtils = preload("res://plugins/fan-manager/core/persistence/fan_curve_utils.gd")
const HardwareWriteQueue = preload("res://plugins/fan-manager/core/utils/hardware_write_queue.gd")

# user_initiated = a real dropdown pick, vs us restoring a saved mode on
# boot or for a per-game context. GameCurveManager uses this to know when
# to actually save.
signal fan_mode_changed(mode: String, user_initiated: bool)

const VALID_MODES := ["bios", "custom"]

var logger := Log.get_logger("FanManager FanModeManager")

var registry: FanBackendRegistry
var store: FanCurveStore
var write_queue: HardwareWriteQueue

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

	var already_exists = store.exists(hardware_id)
	if not already_exists:
		# first run for this hardware, just adopt whatever it's already doing
		_adopt_current_hardware_mode()
		store.flush()
		return

	var data: Dictionary = store.load_data(hardware_id)
	var saved_mode: String = data.get("active_mode", "bios")
	logger.debug("Reapplying saved mode '%s' on startup" % saved_mode)

	var applied_ok = set_mode(saved_mode)
	if not applied_ok:
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

	# not _start_custom_mode() here, that would overwrite the hardware's
	# existing curve with the built-in default. just read back what's active.
	if detected == "custom":
		_adopt_current_custom_curve()

	fan_mode_changed.emit(detected, false)
	logger.info(
		"First run for hardware '%s': adopted current mode '%s' without writing pwm1_enable"
		% [hardware_id, detected]
	)


func set_mode(mode: String, user_initiated: bool = false) -> bool:
	if not backend:
		logger.error("Cannot set mode '%s': no fan backend available" % mode)
		return false

	if mode not in VALID_MODES:
		logger.error("Unknown fan mode '%s'" % mode)
		return false

	# already there, skip the whole stop/restart dance. needed because
	# GameCurveManager calls set_mode("custom") to restore a per-game context
	# even while already in custom mode.
	if mode == current_mode:
		logger.debug("set_mode('%s'): already in this mode" % mode)
		return true

	var previous_mode := current_mode if not current_mode.is_empty() else "(none)"
	logger.debug("set_mode('%s'): stopping %d curve engine(s) from previous mode '%s'" % [mode, curve_engines.size(), previous_mode])

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


func _queue_backend_mode_write(mode: String) -> void:
	var backend_ref := backend
	var job := func():
		var write_ok = backend_ref.set_mode(mode)
		if not write_ok:
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


# seeds every fan from the shared "__default__" game_curves entry, creating
# it with the balanced curve the first time this ever runs. only writes it
# to disk when per-game tracking is off though - checked straight from the
# json cache, we don't want a dependency on GameCurveManager here. while
# per-game is on nobody reads "__default__" anyway, so writing it would just
# leave a dead entry around.
func _start_custom_mode() -> void:
	var fans := backend.list_fans()
	if fans.is_empty():
		logger.error("Cannot start custom mode: no fans available")
		return

	var data: Dictionary = store.load_data(hardware_id)
	var per_game_enabled: bool = data.get("per_game_enabled", false)
	var game_curves: Dictionary = data.get("game_curves", {})
	var default_entry: Dictionary = game_curves.get(FanCurveUtils.GLOBAL_DEFAULT_CONTEXT_KEY, {})
	var default_curves: Dictionary = default_entry.get("curve", {})
	logger.debug(
		"_start_custom_mode(): fans=%s per_game_enabled=%s default_curves=%s"
		% [fans, per_game_enabled, default_curves.keys()]
	)

	if default_curves.is_empty():
		for fan_id in fans:
			default_curves[fan_id] = FanCurveUtils.DEFAULT_BALANCED_CURVE.duplicate()
		if per_game_enabled:
			logger.debug("_start_custom_mode(): per_game_enabled is on, not persisting '%s'" % FanCurveUtils.GLOBAL_DEFAULT_CONTEXT_KEY)
		else:
			store.set_game_curve(FanCurveUtils.GLOBAL_DEFAULT_CONTEXT_KEY, "custom", default_curves)
			logger.info(
				"Created built-in default curve ('%s' context) for hardware '%s'"
				% [FanCurveUtils.GLOBAL_DEFAULT_CONTEXT_KEY, hardware_id]
			)

	for fan_id in fans:
		var engine := _ensure_curve_engine(fan_id)

		# keep whatever's already loaded so unsaved edits survive a trip
		# through another mode
		var curve: Dictionary = engine.get_curve()
		if curve.is_empty():
			curve = default_curves.get(fan_id, FanCurveUtils.DEFAULT_BALANCED_CURVE.duplicate())
			logger.debug("Fan '%s': no in-memory curve, seeding from default/balanced" % fan_id)
		else:
			logger.debug("Fan '%s': reusing in-memory curve from previous session" % fan_id)

		engine.start(backend, fan_id, curve)


func _adopt_current_custom_curve() -> void:
	var fans := backend.list_fans()
	if fans.is_empty():
		return

	for fan_id in fans:
		var bios_curve = backend.get_bios_curve(fan_id)
		var curve := FanCurveUtils.resample_to_fixed_points(bios_curve)
		logger.debug("_adopt_current_custom_curve(): fan '%s' -> %s" % [fan_id, curve])
		var engine := _ensure_curve_engine(fan_id)
		engine.start(backend, fan_id, curve)


func _persist_active_mode(mode: String) -> void:
	logger.debug("Persisting active_mode='%s' for hardware '%s'" % [mode, hardware_id])
	store.load_data(hardware_id)
	store.set_active_mode(mode)
