extends Node
class_name GameCurveManager

## Applies and continuously updates a full fan mode/profile/curve
## snapshot per "context" (a running game, or the Steam home screen
## when nothing is running): tasks/12-fancurve-por-jogo.md, v2 beyond
## REQUIREMENTS.md §5.
##
## Disabled by default (per_game_enabled == false). When enabled:
## - Switching context (game launched/changed, or back to home) with a
##   saved config for that context applies it in full: mode, named
##   profile (if any), and curve: even if that means switching away
##   from the current mode. With no saved config, nothing changes.
## - Any relevant state change (mode switch, profile select/save/
##   delete, curve edit) while a context is active is captured into
##   that context's config. This is the only way a config comes to
##   exist for a context: there is no manual "assign profile to this
##   game" UI.
##
## FanCurveStore/FanModeManager/ProfileManagerPanel below are
## referenced via preload()'d consts, not bare class_name lookups (see
## hwmon_fan_backend.gd's header comment /
## tasks/17-fix-class-name-resolution-em-plugin-empacotado.md).
const FanCurveStore = preload("res://plugins/fan-manager/core/persistence/fan_curve_store.gd")
const FanModeManager = preload("res://plugins/fan-manager/core/modes/fan_mode_manager.gd")
const ProfileManagerPanel = preload("res://plugins/fan-manager/core/ui/components/profile_manager_panel.gd")

const STEAM_HOME_KEY := "__steam_home__"

var logger := Log.get_logger("GameCurveManager")

## Untyped on purpose: only ever called via .app_switched (signal) and
## .get_current_app() (duck-typed), so tests can pass a lightweight
## double instead of depending on OGUI's real LaunchManager (a Resource
## singleton with its own environment-dependent _init()).
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


func _ready() -> void:
	var data: Dictionary = store.load_data(hardware_id)

	var raw_context = data.get("active_game_context")
	active_game_context = raw_context if raw_context != null else ""

	launch_manager.app_switched.connect(_on_app_switched)
	mode_manager.mode_changed.connect(_on_mode_changed)
	profiles_panel.active_profile_changed.connect(_on_state_changed)
	_sync_curve_engine_connections()

	# Reads (and, if already on, re-applies) the persisted toggle on
	# every plugin load: covers "was already enabled last session" the
	# same way as flipping it on mid-session with a game running.
	per_game_enabled = data.get("per_game_enabled", false)


func _on_app_switched(_from, to) -> void:
	_apply_or_track(to)


func _on_mode_changed(_mode: String) -> void:
	# Entering Custom Mode for the first time creates a fresh
	# CustomCurveEngine per fan on demand (tasks/14): (re)connect
	# whenever the mode changes so newly-created engines get tracked
	# too, not just the ones that already existed at _ready().
	_sync_curve_engine_connections()
	_on_state_changed()


func _sync_curve_engine_connections() -> void:
	for engine in mode_manager.get_all_curve_engines().values():
		if not engine.curve_changed.is_connected(_on_curve_changed):
			engine.curve_changed.connect(_on_curve_changed)


func _on_state_changed(_arg = null) -> void:
	_snapshot_and_save()


func _on_curve_changed(_curve: Dictionary) -> void:
	_snapshot_and_save()


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
	# else: no saved config for this context: leave the current state
	# as-is. It starts getting captured by _snapshot_and_save() from
	# the next state change onward.


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


func _persist_enabled(value: bool) -> void:
	var data: Dictionary = store.load_data(hardware_id)
	data["per_game_enabled"] = value
	store.save(hardware_id, data)


func _persist_active_context(context_key: String) -> void:
	var data: Dictionary = store.load_data(hardware_id)
	data["active_game_context"] = context_key
	store.save(hardware_id, data)
