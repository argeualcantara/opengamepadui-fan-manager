extends Node
class_name GameCurveManager

# handles per-context (game/steam home/default) fan curves. saves mode+curve
# whenever the user actually does something (apply, mode switch), never on
# just dragging a slider.

const FanCurveStore = preload("res://plugins/fan-manager/core/persistence/fan_curve_store.gd")
const FanModeManager = preload("res://plugins/fan-manager/core/modes/fan_mode_manager.gd")
const FanCurveUtils = preload("res://plugins/fan-manager/core/persistence/fan_curve_utils.gd")
const CurveSessionState = preload("res://plugins/fan-manager/core/modes/curve_session_state.gd")

const STEAM_HOME_KEY := "__steam_home__"

# tells listeners a curve got loaded into the engines directly (not from a
# slider drag), so they should re-pull and redraw. CustomCurveEngine.load_curve()
# doesn't emit curve_changed on its own.
signal curve_applied()

var logger := Log.get_logger("FanManager GameCurveManager")

var launch_manager
var store: FanCurveStore
var mode_manager: FanModeManager
var hardware_id: String = ""

var active_game_context: String = ""

var curve_session := CurveSessionState.new()

# fans we already hooked slider_edited() to, so we don't connect twice
var _tracked_curve_engine_fan_ids: Dictionary = {}

var per_game_enabled: bool = false:
	set(value):
		if per_game_enabled == value:
			return
		per_game_enabled = value
		_persist_per_game_config(value)
		if value:
			var current_app = launch_manager.get_current_app()
			_apply_or_track(current_app)
		else:
			if mode_manager.current_mode != "custom":
				logger.debug(
					"per_game_enabled=false in mode '%s': stopping %d curve engine(s) to avoid polling outside custom mode"
					% [mode_manager.current_mode, mode_manager.curve_engines.size()]
				)
				for engine in mode_manager.curve_engines.values():
					engine.stop()
			# when per game enabled is false, should always reload __default__ 
			# context mode as well as curves
			curve_session.per_game_toggled_off()
			_restore_default_context_mode()


func _init(
	p_launch_manager,
	p_store: FanCurveStore,
	p_mode_manager: FanModeManager,
	p_hardware_id: String
) -> void:
	launch_manager = p_launch_manager
	store = p_store
	mode_manager = p_mode_manager
	hardware_id = p_hardware_id


func _ready() -> void:
	var json_data_cache: Dictionary = store.load_data(hardware_id)

	# re-apply the saved toggle, same as flipping it live
	per_game_enabled = json_data_cache.get("per_game_enabled", false)

	if per_game_enabled:
		active_game_context = STEAM_HOME_KEY
	else:
		active_game_context = FanCurveUtils.GLOBAL_DEFAULT_CONTEXT_KEY
		# the setter above has a guard that skips itself when the loaded
		# value equals the default (false), so we have to seed the
		# curve_session by hand here or apply_pressed() would be a no-op
		# on the first Apply after boot
		curve_session.context_switched(active_game_context)

	launch_manager.app_switched.connect(_on_app_switched)
	launch_manager.all_apps_stopped.connect(_on_all_apps_stopped)
	mode_manager.fan_mode_changed.connect(_on_fan_mode_changed)
	curve_session.state_changed.connect(_on_curve_session_state_changed)

	logger.debug("_ready(): active_game_context='%s' per_game_enabled=%s" % [active_game_context, json_data_cache.get("per_game_enabled", false)])

	var engines = mode_manager.get_all_curve_engines()
	_track_curve_engines_for_dirty(engines)


func _on_app_switched(_from, to) -> void:
	logger.debug("app_switched -> %s" % (to.launch_item.name if to != null and to.launch_item else "(steam home)"))
	_apply_or_track(to)


func _on_all_apps_stopped() -> void:
	logger.debug("all_apps_stopped -> steam home")
	_apply_or_track(null)


# mode == custom reloads the context's curve into the engines. user_initiated
# means it was a real dropdown pick (not us restoring a saved context), so
# that's when we actually commit/save.
func _on_fan_mode_changed(mode: String, user_initiated: bool) -> void:
	if mode == "custom":
		var engines = mode_manager.get_all_curve_engines()
		_track_curve_engines_for_dirty(engines)
		curve_session.mode_changed_to_custom()
	if user_initiated:
		curve_session.apply_pressed()


func _apply_or_track(to) -> void:
	var context_key := STEAM_HOME_KEY
	if to != null and to.launch_item:
		context_key = to.launch_item.name.to_lower()

	active_game_context = context_key

	if not per_game_enabled:
		# just track it, don't touch curve_session, it has to stay on
		# "__default__" while per-game is off
		logger.debug("_apply_or_track('%s'): per_game_enabled is off, tracking only" % context_key)
		return

	curve_session.context_switched(context_key)

	var data: Dictionary = store.load_data(hardware_id)
	logger.debug("_apply_or_track('%s'): full saved config: %s" % [context_key, JSON.stringify(data, "\t")])

	var game_curves: Dictionary = data.get("game_curves", {})
	var has_saved_config = game_curves.has(context_key)
	if has_saved_config:
		logger.debug("_apply_or_track('%s'): found saved config, applying" % context_key)
		_apply_context(game_curves[context_key])
	else:
		logger.debug("_apply_or_track('%s'): no saved config, creating default entry" % context_key)
		_create_default_context(context_key, game_curves)


# a game/steam home context we've never seen before: give it a bios entry
# with a generic curve right away instead of leaving it blank.
func _create_default_context(context_key: String, game_curves: Dictionary) -> void:
	var default_curve: Dictionary = {}
	var fans = mode_manager.backend.list_fans()
	for fan_id in fans:
		default_curve[fan_id] = FanCurveUtils.DEFAULT_BALANCED_CURVE.duplicate()
	logger.info("_create_default_context('%s'): new context, seeding bios mode with %d default curve entries" % [context_key, default_curve.size()])
	store.set_game_curve(context_key, "bios", default_curve)
	_apply_context({"mode": "bios", "curve": default_curve})


func _apply_context(saved: Dictionary) -> void:
	var mode: String = saved.get("mode", "bios")
	logger.debug("_apply_context('%s'): %s" % [active_game_context, saved])
	if mode.is_empty():
		return

	var switched_ok = mode_manager.set_mode(mode)
	if not switched_ok:
		logger.warn(
			"Saved mode '%s' for context '%s' is no longer valid; keeping current mode"
			% [mode, active_game_context]
		)
		return

	logger.info("Applied per-game config for context '%s'" % active_game_context)
	store.flush()


func _restore_default_context_mode() -> void:
	var data: Dictionary = store.load_data(hardware_id)
	var default_entry: Dictionary = data.get("game_curves", {}).get(FanCurveUtils.GLOBAL_DEFAULT_CONTEXT_KEY, {})
	var default_mode: String = default_entry.get("mode", "bios")
	logger.debug("_restore_default_context_mode(): restoring '%s'" % default_mode)
	mode_manager.set_mode(default_mode)
	store.flush()


func _snapshot_current_context(context_key: String) -> void:
	var mode := mode_manager.current_mode
	var curve: Dictionary = {}

	if mode == "custom":
		var engines := mode_manager.get_all_curve_engines()
		if engines.is_empty():
			logger.debug("_snapshot_current_context('%s'): no curve engines yet, skipping" % context_key)
			return
		for fan_id in engines:
			var engine_curve = engines[fan_id].get_curve()
			curve[fan_id] = engine_curve
	else:
		var stored_data = store.load_data(hardware_id)
		var existing: Dictionary = stored_data.get("game_curves", {}).get(context_key, {})
		curve = existing.get("curve", {})

	store.set_game_curve(context_key, mode, curve)
	logger.debug("Staged per-game config for context '%s': mode='%s'" % [context_key, mode])


func _persist_per_game_config(enabled: bool) -> void:
	logger.debug("Persisting per_game_enabled=%s" % enabled)
	store.load_data(hardware_id)
	store.set_per_game_enabled(enabled)
	store.flush()


func _persist_active_context(context_key: String) -> void:
	logger.debug("Persisting active_game_context='%s'" % context_key)
	store.load_data(hardware_id)
	store.set_active_game_context(context_key)
	store.flush()


func _on_curve_session_state_changed(state: CurveSessionState.State, context_key: String) -> void:
	logger.debug(
		"CurveSessionState -> state=%s context='%s' (real: active_game_context='%s' mode='%s')"
		% [CurveSessionState.State.keys()[state], context_key, active_game_context, mode_manager.current_mode]
	)
	if state == CurveSessionState.State.LOADED:
		_on_curve_session_loaded(context_key)
	elif state == CurveSessionState.State.COMMITTED:
		_on_curve_session_committed(context_key)


# fires on every commit (apply press or a real mode switch). only pushes to
# hardware in custom mode - doing it in bios flips pwm_enable back on real
# ASUS hardware, which we don't want.
func _on_curve_session_committed(context_key: String) -> void:
	if mode_manager.current_mode == "custom":
		var engines := mode_manager.get_all_curve_engines()
		logger.debug("_on_curve_session_committed('%s'): committing draft to hardware for %d engine(s)" % [context_key, engines.size()])
		for engine in engines.values():
			engine.commit_draft()
	else:
		logger.debug("_on_curve_session_committed('%s'): mode is '%s', not custom, skipping hardware commit" % [context_key, mode_manager.current_mode])
	if context_key.is_empty():
		logger.debug("_on_curve_session_committed(''): empty context_key, not staging a game_curves write")
		return
	logger.debug("_on_curve_session_committed('%s'): staging game_curves write" % context_key)
	store.enqueue(func(): _snapshot_current_context(context_key))


# reload the context's curve into the engines. only while in custom mode -
# same hardware-write concern as above.
func _on_curve_session_loaded(context_key: String) -> void:
	if mode_manager.current_mode != "custom":
		logger.debug(
			"_on_curve_session_loaded('%s'): mode is '%s', not custom, skipping reload (engines keep whatever they last had)"
			% [context_key, mode_manager.current_mode]
		)
		return

	var data: Dictionary = store.load_data(hardware_id)
	var game_curves: Dictionary = data.get("game_curves", {})
	var has_saved_config = game_curves.has(context_key)
	if not has_saved_config:
		return

	var curve: Dictionary = game_curves[context_key].get("curve", {})
	if curve.is_empty():
		return

	var engines := mode_manager.get_all_curve_engines()
	_track_curve_engines_for_dirty(engines)
	logger.debug("_on_curve_session_loaded('%s'): reloading curve from store: %s" % [context_key, curve])
	for fan_id in curve:
		if engines.has(fan_id):
			engines[fan_id].load_curve(curve[fan_id])

	curve_applied.emit()


func _track_curve_engines_for_dirty(engines: Dictionary) -> void:
	for fan_id in engines:
		if _tracked_curve_engine_fan_ids.has(fan_id):
			continue
		_tracked_curve_engine_fan_ids[fan_id] = true
		engines[fan_id].curve_changed.connect(_on_curve_engine_edited)


func _on_curve_engine_edited(_curve: Dictionary) -> void:
	curve_session.slider_edited()
