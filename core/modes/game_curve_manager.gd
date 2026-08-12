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

## Fired after _apply_context() loads a per-context curve directly into
## the curve engines. CustomCurveEngine.load_curve() deliberately does
## not emit curve_changed (see its doc comment), so nothing else tells
## a visible CustomCurveEditor to redraw with the new values — the UI
## only otherwise resyncs on FanModeManager.mode_changed, which no
## longer fires for a same-mode context switch (see the no-op guard in
## FanModeManager.set_mode()). Listeners should re-pull the curve from
## the engine (e.g. ModeSelectOverlay re-calling CustomCurveEditor.
## bind_engine()) to bring the displayed sliders back in sync with the
## hardware/engine state.
signal curve_applied()

var logger := Log.get_logger("FanManager GameCurveManager")

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

	logger.debug(
		"_ready(): active_game_context='%s' per_game_enabled=%s"
		% [active_game_context, data.get("per_game_enabled", false)]
	)

	# Re-applies the persisted toggle on load, same as flipping it on mid-session.
	per_game_enabled = data.get("per_game_enabled", false)


## Signal handler for launch_manager.app_switched. to is the newly
## running app (or null for the Steam home screen).
func _on_app_switched(_from, to) -> void:
	logger.debug("app_switched -> %s" % (to.launch_item.name if to != null and to.launch_item else "(steam home)"))
	_apply_or_track(to)


func _on_mode_changed(_mode: String) -> void:
	# Reconnects on every mode change so newly-created engines (Custom
	# Mode creates them lazily per fan) get tracked too.
	_sync_curve_engine_connections()
	_on_state_changed()


## Connects curve_changed on every current CustomCurveEngine to
## _on_curve_changed, skipping engines already connected.
func _sync_curve_engine_connections() -> void:
	var engines := mode_manager.get_all_curve_engines()
	var newly_connected := 0
	for engine in engines.values():
		if not engine.curve_changed.is_connected(_on_curve_changed):
			engine.curve_changed.connect(_on_curve_changed)
			newly_connected += 1
	if newly_connected > 0:
		logger.debug(
			"_sync_curve_engine_connections(): connected %d new engine(s), %d total"
			% [newly_connected, engines.size()]
		)


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


## Applies a saved context config ({mode, active_profile, curve}):
## switches mode, then loads the raw per-fan curve directly into each
## engine. Deliberately does NOT apply by active_profile's name: with
## the profile picker UI hidden, every context shares the same single
## "Default" profile record, so applying by name would load whichever
## context last overwrote it instead of this context's own curve.
## saved["curve"] is captured live per-context (see _snapshot_and_save())
## and is the only thing that actually isolates one context from another.
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

	if mode != "custom":
		return

	var curve: Dictionary = saved.get("curve", {})
	var engines := mode_manager.get_all_curve_engines()
	logger.debug("_apply_context('%s'): loading raw per-fan curve %s" % [active_game_context, curve])
	for fan_id in curve:
		if engines.has(fan_id):
			engines[fan_id].load_curve(curve[fan_id])

	curve_applied.emit()


## Captures the current mode/active_profile/per-fan curves and saves
## them under the active context's key. No-op if per_game_enabled is
## off, no context is active, or no curve engines exist yet.
func _snapshot_and_save() -> void:
	if not per_game_enabled or active_game_context.is_empty():
		return

	var engines := mode_manager.get_all_curve_engines()
	if engines.is_empty():
		logger.debug("_snapshot_and_save('%s'): no curve engines yet, skipping" % active_game_context)
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
	logger.debug(
		"Saved per-game config for context '%s': mode='%s' active_profile=%s"
		% [active_game_context, mode_manager.current_mode, data.get("active_profile")]
	)


## Persists the per_game_enabled toggle to disk.
func _persist_enabled(value: bool) -> void:
	logger.debug("Persisting per_game_enabled=%s" % value)
	var data: Dictionary = store.load_data(hardware_id)
	data["per_game_enabled"] = value
	store.save(hardware_id, data)


## Persists context_key as the active game context to disk.
func _persist_active_context(context_key: String) -> void:
	logger.debug("Persisting active_game_context='%s'" % context_key)
	var data: Dictionary = store.load_data(hardware_id)
	data["active_game_context"] = context_key
	store.save(hardware_id, data)
