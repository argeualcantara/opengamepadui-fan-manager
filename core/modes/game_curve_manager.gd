extends Node
class_name GameCurveManager

## Applies and continuously updates a full fan mode/profile/curve
## snapshot per "context" (a running game, or the Steam home screen
## when nothing is running).
##
## Disabled by default (per_game_enabled == false). When enabled:
## - Switching context with a saved config applies it in full (mode,
##   profile, curve). With no saved config, nothing changes.
## - Any relevant state change while a context is active gets captured
##   into that context's config; there's no manual "assign" UI.
##
## Referenced via preload()'d consts, not bare class_name lookups: see
## hwmon_fan_backend.gd's header comment for why.
const FanCurveStore = preload("res://plugins/fan-manager/core/persistence/fan_curve_store.gd")
const FanModeManager = preload("res://plugins/fan-manager/core/modes/fan_mode_manager.gd")
const ProfileManagerPanel = preload("res://plugins/fan-manager/core/ui/components/profile_manager_panel.gd")

const STEAM_HOME_KEY := "__steam_home__"

var logger := Log.get_logger("GameCurveManager")

## Untyped on purpose: only used via .app_switched/.get_current_app()
## (duck-typed), so tests can pass a lightweight double instead of
## OGUI's real LaunchManager.
var launch_manager
var store: FanCurveStore
var mode_manager: FanModeManager
var profiles_panel: ProfileManagerPanel
var hardware_id: String = ""

var active_game_context: String = ""

var per_game_enabled: bool = false:
	set(value):
		if per_game_enabled == value:
			return
		per_game_enabled = value
		_persist_enabled(value)
		if value:
			_apply_or_track(launch_manager.get_current_app())


## Wires dependencies in: launch_manager (game switch events), store
## (persistence), mode_manager (mode/curve state), profiles_panel
## (profile apply), hardware_id (persistence key).
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
	mode_manager.mode_changed.connect(_on_mode_changed)
	profiles_panel.active_profile_changed.connect(_on_state_changed)
	_sync_curve_engine_connections()

	# Re-applies the persisted toggle on load, same as flipping it on mid-session.
	per_game_enabled = data.get("per_game_enabled", false)


## Signal handler for launch_manager.app_switched. to is the newly
## running app (or null for the Steam home screen).
func _on_app_switched(_from, to) -> void:
	_apply_or_track(to)


func _on_mode_changed(_mode: String) -> void:
	# Reconnects on every mode change so newly-created engines (Custom
	# Mode creates them lazily per fan) get tracked too.
	_sync_curve_engine_connections()
	_on_state_changed()


## Connects curve_changed on every current CustomCurveEngine to
## _on_curve_changed, skipping engines already connected.
func _sync_curve_engine_connections() -> void:
	for engine in mode_manager.get_all_curve_engines().values():
		if not engine.curve_changed.is_connected(_on_curve_changed):
			engine.curve_changed.connect(_on_curve_changed)


## Signal handler for mode_changed/active_profile_changed: any relevant
## state change gets captured into the active context's config.
func _on_state_changed(_arg = null) -> void:
	_snapshot_and_save()


## Signal handler for CustomCurveEngine.curve_changed.
func _on_curve_changed(_curve: Dictionary) -> void:
	_snapshot_and_save()


## Derives the context key for to (a running app, or null for Steam
## home), persists it as the active context, and applies its saved
## config if per_game_enabled and one exists.
func _apply_or_track(to) -> void:
	var context_key := STEAM_HOME_KEY
	if to != null and to.launch_item:
		context_key = to.launch_item.name.to_lower()

	active_game_context = context_key
	_persist_active_context(context_key)

	if not per_game_enabled:
		return

	var data: Dictionary = store.load_data(hardware_id)
	var game_curves: Dictionary = data.get("game_curves", {})
	if game_curves.has(context_key):
		_apply_context(game_curves[context_key])
	# else: no saved config, leave state as-is; starts getting captured
	# from the next state change onward.


## Applies a saved context config ({mode, active_profile, curve}):
## switches mode, then either applies the named profile (if still
## valid) or loads the raw per-fan curve directly into each engine.
func _apply_context(saved: Dictionary) -> void:
	var mode: String = saved.get("mode", "")
	if mode.is_empty():
		return

	if not mode_manager.set_mode(mode):
		logger.warn(
			"Saved mode '%s' for context '%s' is no longer valid; keeping current mode"
			% [mode, active_game_context]
		)
		return

	logger.info("Applied per-game config for context '%s'" % active_game_context)

	if mode != "custom":
		return

	var profile_name = saved.get("active_profile")
	var data: Dictionary = store.load_data(hardware_id)
	var profiles: Dictionary = data.get("profiles")
	if profiles == null:
		profiles = {}

	if profile_name != null and profiles.has(profile_name):
		profiles_panel.apply_profile(profile_name)
		return

	var curve: Dictionary = saved.get("curve", {})
	var engines := mode_manager.get_all_curve_engines()
	for fan_id in curve:
		if engines.has(fan_id):
			engines[fan_id].load_curve(curve[fan_id])


## Captures the current mode/active_profile/per-fan curves and saves
## them under the active context's key. No-op if per_game_enabled is
## off, no context is active, or no curve engines exist yet.
func _snapshot_and_save() -> void:
	if not per_game_enabled or active_game_context.is_empty():
		return

	var engines := mode_manager.get_all_curve_engines()
	if engines.is_empty():
		return

	var curve: Dictionary = {}
	for fan_id in engines:
		curve[fan_id] = engines[fan_id].get_curve()

	var data: Dictionary = store.load_data(hardware_id)
	var game_curves: Dictionary = data.get("game_curves", {})
	game_curves[active_game_context] = {
		"mode": mode_manager.current_mode,
		"active_profile": data.get("active_profile"),
		"curve": curve,
	}
	data["game_curves"] = game_curves
	store.save(hardware_id, data)
	logger.debug("Saved per-game config for context '%s'" % active_game_context)


## Persists the per_game_enabled toggle to disk.
func _persist_enabled(value: bool) -> void:
	var data: Dictionary = store.load_data(hardware_id)
	data["per_game_enabled"] = value
	store.save(hardware_id, data)


## Persists context_key as the active game context to disk.
func _persist_active_context(context_key: String) -> void:
	var data: Dictionary = store.load_data(hardware_id)
	data["active_game_context"] = context_key
	store.save(hardware_id, data)
