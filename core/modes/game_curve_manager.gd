extends Node
class_name GameCurveManager

## Applies and snapshots a full fan mode/curve config per "context" (a
## running game, the Steam home screen when nothing is running, or
## FanCurveUtils.GLOBAL_DEFAULT_CONTEXT_KEY, the single shared context
## used whenever per-game tracking is off).
##
## - Switching context with a saved config applies it in full (mode,
##   curve). With no saved config, nothing changes.
## - Mode/curve changes (already discrete, deliberate actions) are
##   captured into the active context's config immediately: a
##   user-driven mode switch is detected via mode_manager.
##   fan_mode_changed(mode, user_initiated=true), and a real Apply
##   press is a direct call from ModeSelectOverlay to
##   curve_session.apply_pressed() (see curve_session's COMMITTED
##   transition and _on_curve_session_committed() below), which also
##   pushes every engine's draft curve to hardware.
##   Curve edits are NOT: dragging a slider never writes anything on
##   its own (mirrors CustomCurveEngine's own draft/committed split,
##   see its doc comment), it only marks curve_session DIRTY until
##   something commits it.
##
## Referenced via preload()'d consts, not bare class_name lookups: see
## hwmon_fan_backend.gd's header comment for why.
const FanCurveStore = preload("res://plugins/fan-manager/core/persistence/fan_curve_store.gd")
const FanModeManager = preload("res://plugins/fan-manager/core/modes/fan_mode_manager.gd")
const FanCurveUtils = preload("res://plugins/fan-manager/core/persistence/fan_curve_utils.gd")
const CurveSessionState = preload("res://plugins/fan-manager/core/modes/curve_session_state.gd")

const STEAM_HOME_KEY := "__steam_home__"

## Fired whenever a curve was just loaded directly into the curve
## engines from something other than a user edit: _on_curve_session_loaded()
## reloading a context's curve, uniformly for a real game/Steam-home
## context and for FanCurveUtils.GLOBAL_DEFAULT_CONTEXT_KEY (the
## per_game_enabled toggle-off case). CustomCurveEngine.load_curve()
## deliberately does not emit curve_changed (see its doc comment), so
## nothing else tells a visible CustomCurveEditor to redraw with the
## new values, the UI only otherwise resyncs on FanModeManager.
## fan_mode_changed, which no longer fires for a same-mode context
## switch (see the no-op guard in FanModeManager.set_mode()). Listeners
## should re-pull the curve from the engine (e.g. ModeSelectOverlay
## re-calling CustomCurveEditor.bind_engine()) to bring the displayed
## sliders back in sync with the hardware/engine state.
signal curve_applied()

var logger := Log.get_logger("FanManager GameCurveManager")

## References OGUI's real LaunchManager.
var launch_manager
var store: FanCurveStore
var mode_manager: FanModeManager
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
		_persist_per_game_config(value)
		if value:
			_apply_or_track(launch_manager.get_current_app())
		else:
			if mode_manager.current_mode != "custom":
				logger.debug(
					"per_game_enabled=false in mode '%s': stopping %d curve engine(s) to avoid polling outside custom mode"
					% [mode_manager.current_mode, mode_manager.curve_engines.size()]
				)
				for engine in mode_manager.curve_engines.values():
					engine.stop()
			curve_session.per_game_toggled_off()


## Wires dependencies in: launch_manager (game switch events, and
## all_apps_stopped for detecting a return to Steam home, see
## _on_all_apps_stopped()'s doc comment), store (persistence),
## mode_manager (mode/curve state), hardware_id (persistence key).
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


## Restores the last active context, wires up signals, and re-applies
## the persisted per_game_enabled toggle.
func _ready() -> void:
	var json_data_cache: Dictionary = store.load_data(hardware_id)
	
	# Re-applies the persisted toggle on load, same as flipping it on mid-session.
	per_game_enabled = json_data_cache.get("per_game_enabled", false)

	if per_game_enabled:
		active_game_context = STEAM_HOME_KEY
	else:
		active_game_context = FanCurveUtils.GLOBAL_DEFAULT_CONTEXT_KEY
		# Seeded directly here, not left to the per_game_enabled
		# assignment above: that's a property setter with an
		# early-return guard (`if per_game_enabled == value: return`)
		# that silently skips its whole body (including per_game_toggled_off())
		# whenever the loaded value already matches the variable's
		# compiled default (false) — always true in this branch. Without
		# this, curve_session would stay UNTRACKED until the first app
		# switch, and apply_pressed() no-ops while UNTRACKED (see its own
		# doc comment), so the very first Apply press after a normal boot
		# would silently commit nothing. Idempotent and side-effect free
		# here: no listener is connected to state_changed yet. The
		# `per_game_enabled` branch above needs no equivalent: its setter
		# always fires (true never equals the compiled default), and
		# _apply_or_track() already seeds curve_session correctly there.
		curve_session.context_switched(active_game_context)

	launch_manager.app_switched.connect(_on_app_switched)
	launch_manager.all_apps_stopped.connect(_on_all_apps_stopped)
	mode_manager.fan_mode_changed.connect(_on_fan_mode_changed)
	curve_session.state_changed.connect(_on_curve_session_state_changed)

	logger.debug("_ready(): active_game_context='%s' per_game_enabled=%s" % [active_game_context, json_data_cache.get("per_game_enabled", false)])

	_track_curve_engines_for_dirty(mode_manager.get_all_curve_engines())



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


## Signal handler for mode_manager.fan_mode_changed. Two independent
## things, gated on different conditions:
##  - mode == "custom": re-enters curve_session's LOADED state
##    (recharges the active context's curve into the engines) —
##    regardless of who triggered the switch, a manual dropdown pick
##    just as much as _apply_context() restoring a saved context.
##  - user_initiated: commits (COMMITTED transition), staging a
##    game_curves write — only for a real user-driven mode switch.
##    Without this guard, _apply_context() calling mode_manager.
##    set_mode() to restore a saved context's mode would immediately
##    re-trigger a commit for that same context right after loading
##    it — see fan_mode_manager.gd's fan_mode_changed doc comment.
func _on_fan_mode_changed(mode: String, user_initiated: bool) -> void:
	if mode == "custom":
		_track_curve_engines_for_dirty(mode_manager.get_all_curve_engines())
		curve_session.mode_changed_to_custom()
	if user_initiated:
		curve_session.apply_pressed()


## Derives the context key for to (a running app, or null for Steam
## home), persists it as the active context, and applies its saved
## config if per_game_enabled and one exists — if not, seeds a brand
## new default entry for it (see _create_default_context()).
func _apply_or_track(to) -> void:
	var context_key := STEAM_HOME_KEY
	if to != null and to.launch_item:
		context_key = to.launch_item.name.to_lower()

	active_game_context = context_key

	if not per_game_enabled:
		# Tracking only, curve_session is deliberately left untouched:
		# while per-game is off, its context_key must stay pinned at
		# FanCurveUtils.GLOBAL_DEFAULT_CONTEXT_KEY (there's no real
		# context to switch to/from — see _on_curve_session_committed()/
		# _on_curve_session_loaded()'s doc comments for why this matters
		# now that they no longer gate on per_game_enabled themselves).
		logger.debug("_apply_or_track('%s'): per_game_enabled is off, tracking only" % context_key)
		return

	curve_session.context_switched(context_key)

	var data: Dictionary = store.load_data(hardware_id)
	logger.debug("_apply_or_track('%s'): full saved config: %s" % [context_key, JSON.stringify(data, "\t")])

	var game_curves: Dictionary = data.get("game_curves", {})
	if game_curves.has(context_key):
		logger.debug("_apply_or_track('%s'): found saved config, applying" % context_key)
		_apply_context(game_curves[context_key])
	else:
		logger.debug("_apply_or_track('%s'): no saved config, creating default entry" % context_key)
		_create_default_context(context_key, game_curves)


## A context (game/Steam home) with no game_curves entry yet: seeds one
## right away instead of silently leaving the engines/hardware showing
## whatever the previous context left behind. Starts in bios mode, not
## whatever curve was last active — an unconfigured context is unknown,
## so it defaults to the safe/inert mode rather than immediately
## pushing a possibly-irrelevant custom curve to hardware (mirrors the
## same "unknown -> bios" principle FanModeManager._adopt_current_hardware_mode()
## and _ready()'s saved-mode fallback already use). The curve itself is
## seeded from FanCurveUtils.GLOBAL_DEFAULT_CONTEXT_KEY's (the shared
## default), falling back to FanCurveUtils.DEFAULT_BALANCED_CURVE per
## fan if that hasn't been created yet either — same fallback
## FanModeManager._start_custom_mode() uses, so the stored entry always
## has a real curve on disk, not an empty placeholder, once this
## context is later switched to custom for the first time.
func _create_default_context(context_key: String, game_curves: Dictionary) -> void:
	var default_curve: Dictionary = {}
	for fan_id in mode_manager.backend.list_fans():
		default_curve[fan_id] = FanCurveUtils.DEFAULT_BALANCED_CURVE.duplicate()
	logger.info("_create_default_context('%s'): new context, seeding bios mode with %d default curve entries" % [context_key, default_curve.size()])
	store.set_game_curve(context_key, "bios", default_curve)
	_apply_context({"mode": "bios", "curve": default_curve})


## Applies a saved context config ({mode, curve}): just switches mode.
## The curve itself is no longer loaded here directly
## _apply_or_track() already calls curve_session.context_switched() before this runs.
func _apply_context(saved: Dictionary) -> void:
	var mode: String = saved.get("mode", "bios")
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
## _on_curve_session_committed()) to capture the current mode/per-fan
## curves and stage them under context_key. Does nothing if there are
## no curve engines yet.
func _snapshot_current_context(context_key: String) -> void:
	var mode := mode_manager.current_mode
	var curve: Dictionary = {}

	if mode == "custom":
		var engines := mode_manager.get_all_curve_engines()
		if engines.is_empty():
			logger.debug("_snapshot_current_context('%s'): no curve engines yet, skipping" % context_key)
			return
		for fan_id in engines:
			curve[fan_id] = engines[fan_id].get_curve()
	else:
		var existing: Dictionary = store.load_data(hardware_id).get("game_curves", {}).get(context_key, {})
		curve = existing.get("curve", {})

	store.set_game_curve(context_key, mode, curve)
	logger.debug("Staged per-game config for context '%s': mode='%s'" % [context_key, mode])


func _persist_per_game_config(enabled: bool) -> void:
	logger.debug("Persisting per_game_enabled=%s" % enabled)
	store.load_data(hardware_id)
	store.set_per_game_enabled(enabled)
	store.flush()


## Persists context_key as the active game context.
func _persist_active_context(context_key: String) -> void:
	logger.debug("Persisting active_game_context='%s'" % context_key)
	store.load_data(hardware_id)
	store.set_active_game_context(context_key)
	store.flush()


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


## Fires on every COMMITTED transition: a real Apply press
## (ModeSelectOverlay._on_apply_pressed() calling curve_session.
## apply_pressed() directly) just as much as a user-driven mode switch
## (_on_fan_mode_changed() above, gated on user_initiated). Pushes
## every engine's draft curve to hardware while in custom mode (this
## is the one place that happens — CustomCurveEngine.set_point() never
## writes on its own, see its doc comment) — gated on mode == "custom"
## on purpose: CustomCurveEngine.commit_draft() unconditionally queues
## a hardware write, and switching to bios then committing (e.g. a
## user-driven mode switch to bios) must never push a curve to
## hardware, the same real ASUS pwm_enable flip-back bug documented on
## test_switching_to_bios_does_not_commit_the_draft_curve_to_hardware.
## Staging the game_curves[context_key] write is unrelated to mode,
## only gated on having a real context_key, not on per_game_enabled —
## context_key is always FanCurveUtils.GLOBAL_DEFAULT_CONTEXT_KEY while
## per-game is off (see _apply_or_track()'s doc comment), so this
## writes there too, same as any other context.
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


## Runs on every LOADED transition, from both context_switched()
## (a context switch, whether or not it also changes mode) and
## mode_changed_to_custom() (a mode change for the already-active
## context), between the two, every path that can bring the hardware
## into "custom mode, context_key active" ends up here exactly once.
## Gated on mode == "custom" on purpose, not just for the UI resync:
## CustomCurveEngine.load_curve() -> start() unconditionally queues a
## hardware write and can restart the poll timer, the same class of
## real-hardware bug (pwm_enable flip-back, see
## test_switching_to_bios_does_not_commit_the_draft_curve_to_hardware's
## comment) an earlier fix guarded against for the commit path — a
## reload while nominally in bios mode would reintroduce it. Accepted
## trade-off: the shared engines can hold a stale context's curve
## between a mode switch to bios and the next real context_switched()
## (see test_disabling_toggle_in_bios_mode_leaves_the_previous_context_in_memory).
## Not gated on per_game_enabled: context_key is always FanCurveUtils.
## GLOBAL_DEFAULT_CONTEXT_KEY while per-game is off (see
## _apply_or_track()'s doc comment), so this is also how the
## per_game_enabled toggle-off branch above reloads the shared default
## curve, uniformly with any other context.
func _on_curve_session_loaded(context_key: String) -> void:
	if mode_manager.current_mode != "custom":
		logger.debug(
			"_on_curve_session_loaded('%s'): mode is '%s', not custom, skipping reload (engines keep whatever they last had)"
			% [context_key, mode_manager.current_mode]
		)
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
## _on_fan_mode_changed(), _on_curve_session_loaded()) first gets a chance
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
