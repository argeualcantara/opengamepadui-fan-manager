extends Node
class_name GameCurveManager

## Applies and snapshots a full fan mode/profile/curve config per
## "context" (a running game, or the Steam home screen when nothing is
## running).
##
## Disabled by default (per_game_enabled == false). When enabled:
## - Switching context with a saved config applies it in full (mode,
##   profile, curve). With no saved config, nothing changes.
## - Mode/profile changes (already discrete, deliberate actions) are
##   captured into the active context's config immediately, both a
##   real Apply press and a user-driven mode switch go through
##   ProfileManagerPanel._commit_save(), which emits
##   active_profile_changed; see curve_session's COMMITTED transition
##   and _on_curve_session_committed() below. Curve edits are NOT:
##   dragging a slider never writes anything on its own (mirrors
##   CustomCurveEngine's own draft/committed split, see its doc
##   comment), it only marks curve_session DIRTY until something
##   commits it.
##
## Referenced via preload()'d consts, not bare class_name lookups: see
## hwmon_fan_backend.gd's header comment for why.
const FanCurveStore = preload("res://plugins/fan-manager/core/persistence/fan_curve_store.gd")
const FanModeManager = preload("res://plugins/fan-manager/core/modes/fan_mode_manager.gd")
const ProfileManagerPanel = preload("res://plugins/fan-manager/core/ui/components/profile_manager_panel.gd")
const FanCurveUtils = preload("res://plugins/fan-manager/core/persistence/fan_curve_utils.gd")
const CurveSessionState = preload("res://plugins/fan-manager/core/modes/curve_session_state.gd")

const STEAM_HOME_KEY := "__steam_home__"

## Fired whenever a curve was just loaded directly into the curve
## engines from something other than a user edit, either
## _on_curve_session_loaded() reloading a per-context curve, 
## or the per_game_enabled toggle-off branch below reloading
## the "Default" profile. CustomCurveEngine.load_curve() deliberately
## does not emit curve_changed (see its doc comment), so nothing else
## tells a visible CustomCurveEditor to redraw with the new values,
## the UI only otherwise resyncs on FanModeManager.mode_changed, which
## no longer fires for a same-mode context switch (see the no-op guard
## in FanModeManager.set_mode()). Listeners should re-pull the curve
## from the engine (e.g. ModeSelectOverlay re-calling
## CustomCurveEditor.bind_engine()) to bring the displayed sliders back
## in sync with the hardware/engine state.
signal curve_applied()

var logger := Log.get_logger("FanManager GameCurveManager")

## References OGUI's real LaunchManager.
var launch_manager
var store: FanCurveStore
var mode_manager: FanModeManager
var profiles_panel: ProfileManagerPanel
var hardware_id: String = ""

var active_game_context: String = ""

var curve_session := CurveSessionState.new()

## fan_id -> true for every CustomCurveEngine curve_session.
## slider_edited() has already been wired to. Engines are created once
## and reused for the whole session (see FanModeManager.
## _ensure_curve_engine()), so each one only needs connecting once,
## whenever this class first gets a chance to see it.
var _tracked_curve_engine_fan_ids: Dictionary = {}

var per_game_enabled: bool = false:
	set(value):
		if per_game_enabled == value:
			return
		per_game_enabled = value
		_persist_enabled(value)
		if value:
			_apply_or_track(launch_manager.get_current_app())
		else:
			profiles_panel.apply_profile(FanCurveUtils.DEFAULT_PROFILE_NAME)
			if mode_manager.current_mode != "custom":
				logger.debug(
					"per_game_enabled=false in mode '%s': stopping %d curve engine(s) to avoid polling outside custom mode"
					% [mode_manager.current_mode, mode_manager.curve_engines.size()]
				)
				for engine in mode_manager.curve_engines.values():
					engine.stop()
			curve_applied.emit()
			curve_session.per_game_toggled_off()


## Wires dependencies in: launch_manager (game switch events, and
## all_apps_stopped for detecting a return to Steam home, see
## _on_all_apps_stopped()'s doc comment), store (persistence),
## mode_manager (mode/curve state), profiles_panel (profile apply),
## hardware_id (persistence key).
func _init(
	p_launch_manager,
	p_store: FanCurveStore,
	p_mode_manager: FanModeManager,
	p_profiles_panel: ProfileManagerPanel,
	p_hardware_id: String
) -> void:
	launch_manager = p_launch_manager
	store = p_store
	mode_manager = p_mode_manager
	profiles_panel = p_profiles_panel
	hardware_id = p_hardware_id


## Restores the last active context, wires up signals, and re-applies
## the persisted per_game_enabled toggle.
func _ready() -> void:
	var data: Dictionary = store.load_data(hardware_id)

	var raw_context = data.get("active_game_context")
	active_game_context = raw_context if raw_context != null else ""

	launch_manager.app_switched.connect(_on_app_switched)
	launch_manager.all_apps_stopped.connect(_on_all_apps_stopped)
	mode_manager.mode_changed.connect(_on_mode_changed)
	profiles_panel.active_profile_changed.connect(_on_apply_pressed)
	curve_session.state_changed.connect(_on_curve_session_state_changed)

	logger.debug(
		"_ready(): active_game_context='%s' per_game_enabled=%s"
		% [active_game_context, data.get("per_game_enabled", false)]
	)

	_track_curve_engines_for_dirty(mode_manager.get_all_curve_engines())

	# Re-applies the persisted toggle on load, same as flipping it on mid-session.
	per_game_enabled = data.get("per_game_enabled", false)


## Signal handler for launch_manager.app_switched. to is the newly
## running app (or null for the Steam home screen).
func _on_app_switched(_from, to) -> void:
	logger.debug("app_switched -> %s" % (to.launch_item.name if to != null and to.launch_item else "(steam home)"))
	_apply_or_track(to)


## Signal handler for launch_manager.all_apps_stopped: fires exactly
## once, when the last running app actually terminates.
func _on_all_apps_stopped() -> void:
	logger.debug("all_apps_stopped -> steam home")
	_apply_or_track(null)


## Signal handler for mode_manager.mode_changed: whenever the mode
## actually becomes "custom", however that happened, a manual toggle
## in ModeSelectOverlay just as much as _apply_context() switching mode
## for a saved context, tracks any new engines and re-enters
## curve_session's LOADED state for the active context.
func _on_mode_changed(mode: String) -> void:
	if mode != "custom":
		return
	_track_curve_engines_for_dirty(mode_manager.get_all_curve_engines())
	curve_session.mode_changed_to_custom()


## Derives the context key for to (a running app, or null for Steam
## home), persists it as the active context, and applies its saved
## config if per_game_enabled and one exists.
func _apply_or_track(to) -> void:
	var context_key := STEAM_HOME_KEY
	if to != null and to.launch_item:
		context_key = to.launch_item.name.to_lower()

	active_game_context = context_key
	_persist_active_context(context_key)
	curve_session.context_switched(context_key)

	if not per_game_enabled:
		logger.debug("_apply_or_track('%s'): per_game_enabled is off, tracking only" % context_key)
		return

	var data: Dictionary = store.load_data(hardware_id)
	logger.debug("_apply_or_track('%s'): full saved config: %s" % [context_key, JSON.stringify(data, "\t")])

	var game_curves: Dictionary = data.get("game_curves", {})
	if game_curves.has(context_key):
		logger.debug("_apply_or_track('%s'): found saved config, applying" % context_key)
		_apply_context(game_curves[context_key])
	else:
		logger.debug("_apply_or_track('%s'): no saved config, leaving state as-is" % context_key)


## Applies a saved context config ({mode, active_profile, curve}): just
## switches mode. The curve itself is no longer loaded here directly
## _apply_or_track() already calls curve_session.context_switched() before this runs.
func _apply_context(saved: Dictionary) -> void:
	var mode: String = saved.get("mode", "")
	logger.debug("_apply_context('%s'): %s" % [active_game_context, saved])
	if mode.is_empty():
		return

	if not mode_manager.set_mode(mode):
		logger.warn(
			"Saved mode '%s' for context '%s' is no longer valid; keeping current mode"
			% [mode, active_game_context]
		)
		return

	logger.info("Applied per-game config for context '%s'" % active_game_context)
	store.flush()


## Runs (only from inside store.flush(), via the job enqueued in
## _on_curve_session_committed()) to capture the current mode/
## active_profile/per-fan curves and stage them under context_key.
## Does nothing if there are no curve engines yet.
func _snapshot(context_key: String) -> void:
	var mode := mode_manager.current_mode
	var curve: Dictionary = {}

	if mode == "custom":
		var engines := mode_manager.get_all_curve_engines()
		if engines.is_empty():
			logger.debug("_snapshot('%s'): no curve engines yet, skipping" % context_key)
			return
		for fan_id in engines:
			curve[fan_id] = engines[fan_id].get_curve()
	else:
		var existing: Dictionary = store.load_data(hardware_id).get("game_curves", {}).get(context_key, {})
		curve = existing.get("curve", {})

	var active_profile = store.load_data(hardware_id).get("active_profile")
	store.set_game_curve(context_key, mode, active_profile, curve)
	logger.debug(
		"Staged per-game config for context '%s': mode='%s' active_profile=%s"
		% [context_key, mode, active_profile]
	)


## Persists the per_game_enabled toggle. Standalone operation (not
## part of a bigger transaction), so it flushes immediately.
func _persist_enabled(value: bool) -> void:
	logger.debug("Persisting per_game_enabled=%s" % value)
	store.load_data(hardware_id)
	store.set_per_game_enabled(value)
	store.flush()


## Persists context_key as the active game context. Standalone
## operation, flushes immediately, independent of whether
## _apply_context() also runs (and flushes again) right after, for a
## context that has a saved config.
func _persist_active_context(context_key: String) -> void:
	logger.debug("Persisting active_game_context='%s'" % context_key)
	store.load_data(hardware_id)
	store.set_active_game_context(context_key)
	store.flush()


## Signal handler for profiles_panel.active_profile_changed: any commit
## (Apply press or profile change) transitions curve_session to COMMITTED.
func _on_apply_pressed(_profile_name: String) -> void:
	curve_session.apply_pressed()


## Signal handler for curve_session.state_changed
## dispatches to _on_curve_session_loaded() on LOADED and
## _on_curve_session_committed() on COMMITTED.
func _on_curve_session_state_changed(state: CurveSessionState.State, context_key: String) -> void:
	logger.debug(
		"CurveSessionState -> state=%s context='%s' (real: active_game_context='%s' mode='%s')"
		% [CurveSessionState.State.keys()[state], context_key, active_game_context, mode_manager.current_mode]
	)
	if state == CurveSessionState.State.LOADED:
		_on_curve_session_loaded(context_key)
	elif state == CurveSessionState.State.COMMITTED:
		_on_curve_session_committed(context_key)


## The one place game_curves[context_key] gets written.
## Fires on every COMMITTED transition: a real Apply press (_on_apply_pressed()
## via profiles_panel.active_profile_changed) just as much as a user-driven
## mode switch (ModeSelectOverlay._on_mode_selected() calling
## profiles_panel.apply_current() directly.
func _on_curve_session_committed(context_key: String) -> void:
	if not per_game_enabled:
		logger.debug("_on_curve_session_committed('%s'): per_game_enabled is off, not staging a game_curves write" % context_key)
		return
	if context_key.is_empty():
		logger.debug("_on_curve_session_committed(''): empty context_key, not staging a game_curves write")
		return
	logger.debug("_on_curve_session_committed('%s'): staging game_curves write" % context_key)
	store.enqueue(func(): _snapshot(context_key))


## Runs on every LOADED transition, from both context_switched()
## (a context switch, whether or not it also changes mode) and
## mode_changed_to_custom() (a mode change for the already-active
## context), between the two, every path that can bring the hardware
## into "custom mode, context_key active" ends up here exactly once.
func _on_curve_session_loaded(context_key: String) -> void:
	if not per_game_enabled or mode_manager.current_mode != "custom":
		return

	var data: Dictionary = store.load_data(hardware_id)
	var game_curves: Dictionary = data.get("game_curves", {})
	if not game_curves.has(context_key):
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


## Connects curve_session.slider_edited() to any engine in engines this
## class hasn't seen before, engines are created once and reused for
## the whole session (see FanModeManager._ensure_curve_engine()), so
## each only needs connecting once, whichever call site (_ready(),
## _on_mode_changed(), _on_curve_session_loaded()) first gets a chance
## to see it. 
func _track_curve_engines_for_dirty(engines: Dictionary) -> void:
	for fan_id in engines:
		if _tracked_curve_engine_fan_ids.has(fan_id):
			continue
		_tracked_curve_engine_fan_ids[fan_id] = true
		engines[fan_id].curve_changed.connect(_on_curve_engine_edited)


## Signal handler for CustomCurveEngine.curve_changed: a slider was
## dragged. Doesn't distinguish which fan/context, any edit marks the
## whole session dirty.
func _on_curve_engine_edited(_curve: Dictionary) -> void:
	curve_session.slider_edited()
