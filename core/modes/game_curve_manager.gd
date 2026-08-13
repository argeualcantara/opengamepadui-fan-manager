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
##   captured into the active context's config immediately — both a
##   real Apply press and a user-driven mode switch go through
##   ProfileManagerPanel._commit_save(), which emits
##   active_profile_changed; see curve_session's COMMITTED transition
##   and _on_curve_session_committed() below. Curve edits are NOT:
##   dragging a slider never writes anything on its own (mirrors
##   CustomCurveEngine's own draft/committed split — see its doc
##   comment) — it only marks curve_session DIRTY until something
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
## engines from something other than a user edit — either
## _on_curve_session_loaded() reloading a per-context curve (tasks/18,
## etapa 3), or the per_game_enabled toggle-off branch below reloading
## the "Default" profile. CustomCurveEngine.load_curve() deliberately
## does not emit curve_changed (see its doc comment), so nothing else
## tells a visible CustomCurveEditor to redraw with the new values —
## the UI only otherwise resyncs on FanModeManager.mode_changed, which
## no longer fires for a same-mode context switch (see the no-op guard
## in FanModeManager.set_mode()). Listeners should re-pull the curve
## from the engine (e.g. ModeSelectOverlay re-calling
## CustomCurveEditor.bind_engine()) to bring the displayed sliders back
## in sync with the hardware/engine state.
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

## Fed the same events this class already reacts to (tasks/18). Public
## so ModeSelectOverlay can listen to state_changed directly and drive
## the "unsaved" badge from it (etapa 2). Also the trigger for reloading
## a context's curve into the engines on LOADED (etapa 3 — see
## _on_curve_session_loaded()) and for writing game_curves[context] on
## COMMITTED (etapa 4 — see _on_curve_session_committed()).
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
			# Turning tracking off otherwise leaves whichever context's
			# curve was last active sitting in the engines/on hardware
			# with no indication anything changed. Snap back to the
			# single shared "Default" profile — the same curve Apply
			# now writes to while per-game is off (see
			# ProfileManagerPanel._commit_save()) — so the engines (and
			# UI, once redrawn) match what'll actually get edited/saved
			# from here on.
			#
			# Deliberately NOT gated on mode_manager.current_mode ==
			# "custom" anymore (tasks/18, etapa 5 gap fix): apply_profile()
			# only ever writes curve *points* (pwmN_auto_pointM_temp/pwm)
			# to hardware, never pwm_enable/mode itself, so it's just as
			# safe to run in bios mode — the curve only takes effect
			# once/if the user switches to custom by hand afterward.
			# Without this, engines (and curve_session's context_key) were
			# left holding whichever game's context/curve was last active
			# while the toggle was on, until the user happened to be in
			# custom mode the next time they flipped per-game off —
			# leaving profiles["Default"] (the JSON source of truth) out
			# of sync with the engines in the meantime. No-op (with a log
			# warning) if "Default" doesn't exist yet.
			profiles_panel.apply_profile(FanCurveUtils.DEFAULT_PROFILE_NAME)
			if mode_manager.current_mode != "custom":
				# apply_profile() -> CustomCurveEngine.load_curve() ->
				# start() always (re)applies once immediately AND restarts
				# the software poll timer when the backend needs one (see
				# requires_software_polling()) — appropriate while actually
				# in custom mode, but not here: FanModeManager.set_mode()
				# is the only other place that stops engines, and it isn't
				# involved in this toggle. Without this, a backend that
				# needs software polling would keep re-writing the curve to
				# hardware every couple seconds while nominally in BIOS
				# mode, until the next real mode switch. The one-time write
				# start() already did is harmless on its own (see
				# _snapshot()'s doc comment on curve points vs pwm_enable);
				# only the recurring timer needs to stop.
				for engine in mode_manager.get_all_curve_engines().values():
					engine.stop()
			# apply_profile() updates the engines (and hardware) directly
			# but never emits curve_applied — unlike _apply_context()/
			# _on_mode_changed() below, which always do. Without this,
			# the curve underneath changes but the visible sliders never
			# get told to re-pull it (see curve_applied's doc comment).
			curve_applied.emit()
			curve_session.per_game_toggled_off()


## Wires dependencies in: launch_manager (game switch events, and
## all_apps_stopped for detecting a return to Steam home — see
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

	# Custom mode may already be active (FanModeManager re-applies the
	# saved mode in its own _ready(), which runs before this one) —
	# catch any engines that already exist so a slider edit right
	# after startup isn't missed.
	_track_curve_engines_for_dirty(mode_manager.get_all_curve_engines())

	# Re-applies the persisted toggle on load, same as flipping it on mid-session.
	per_game_enabled = data.get("per_game_enabled", false)


## Signal handler for launch_manager.app_switched. to is the newly
## running app (or null for the Steam home screen).
func _on_app_switched(_from, to) -> void:
	logger.debug("app_switched -> %s" % (to.launch_item.name if to != null and to.launch_item else "(steam home)"))
	_apply_or_track(to)


## Signal handler for launch_manager.all_apps_stopped: fires exactly
## once, when the last running app actually terminates (its card
## disappears from the overlay). Needed because app_switched is NOT
## emitted for this transition: on_focused_app_changed() in
## launch_manager.gd returns early (before emitting app_switched)
## whenever focus moves to the OGUI overlay itself.
##
## Deliberately NOT using in_game_state.state_exited for this (tried
## first): that signal fires any time a new state is pushed on top of
## in_game_state in OGUI's state stack — e.g. opening the Quick Bar
## menu while the game is still running also pushes a state and fires
## state_exited on in_game_state, which wrongly reverted to the Steam
## home curve mid-game every time a menu was opened. all_apps_stopped
## only fires when LaunchManager actually has zero running apps left.
func _on_all_apps_stopped() -> void:
	logger.debug("all_apps_stopped -> steam home")
	_apply_or_track(null)


## Signal handler for mode_manager.mode_changed: whenever the mode
## actually becomes "custom" — however that happened, a manual toggle
## in ModeSelectOverlay just as much as _apply_context() switching mode
## for a saved context — tracks any new engines and re-enters
## curve_session's LOADED state for the active context.
##
## Independent of per_game_enabled/active_game_context on purpose:
## engines can be created for the first time on any transition into
## custom mode (not just _ready()'s initial one), and both slider-edit
## tracking and the "unsaved" badge (tasks/18, etapa 2) must work
## regardless of whether per-game tracking itself is on. The actual
## curve reload from game_curves — which IS per-game-only — happens in
## _on_curve_session_loaded(), triggered by the LOADED state this sets
## (see curve_session.state_changed's doc comment there for why
## reacting to the state transition, not this signal directly, is what
## also correctly covers the "already in this mode" case).
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
## (tasks/18, etapa 3) — _apply_or_track() already called
## curve_session.context_switched() before this runs, which
## synchronously triggers _on_curve_session_loaded() to load
## saved["curve"] the moment the hardware is actually in custom mode:
## immediately, if it already was (context_switched() alone covers
## that case); via mode_changed_to_custom() below once set_mode()
## finishes, if switching to custom is what this call actually did.
## Either way, saved["curve"] never needs reading here — see
## _on_curve_session_loaded()'s doc comment for why applying it by
## active_profile's name instead would be wrong.
func _apply_context(saved: Dictionary) -> void:
	var mode: String = saved.get("mode", "")
	logger.debug("_apply_context('%s'): %s" % [active_game_context, saved])
	if mode.is_empty():
		return

	# set_mode() only mutates the in-memory document — it never flushes
	# on its own. That's what makes it safe to call here even though
	# the curve hasn't been loaded yet: nothing hits disk until this
	# function's own flush() at the bottom.
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
## No-op if there are no curve engines yet.
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
		# Not in custom mode: there's no live curve to read — engines
		# are shared across every context (see _on_mode_changed()'s doc
		# comment), so whatever they currently hold could easily be
		# leftover data from a different context. Keep whatever this
		# context already had saved instead of overwriting it with that
		# stale/foreign curve.
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
## operation, flushes immediately — independent of whether
## _apply_context() also runs (and flushes again) right after, for a
## context that has a saved config.
func _persist_active_context(context_key: String) -> void:
	logger.debug("Persisting active_game_context='%s'" % context_key)
	store.load_data(hardware_id)
	store.set_active_game_context(context_key)
	store.flush()


## Signal handler for profiles_panel.active_profile_changed: any commit
## (Apply press or profile change) transitions curve_session to
## COMMITTED. Deliberately NOT gated on per_game_enabled/
## active_game_context here — Apply always commits *something*
## (game_curves when per-game is on, just profiles["Default"]
## otherwise — see ProfileManagerPanel._commit_save()), and the
## "unsaved" badge needs to clear either way. The actual game_curves
## write is gated separately, in _on_curve_session_committed().
func _on_apply_pressed(_profile_name: String) -> void:
	curve_session.apply_pressed()


## Signal handler for curve_session.state_changed (tasks/18, etapas 3-4):
## dispatches to _on_curve_session_loaded() on LOADED and
## _on_curve_session_committed() on COMMITTED, and always logs for
## comparison against active_game_context/mode_manager.current_mode.
func _on_curve_session_state_changed(state: CurveSessionState.State, context_key: String) -> void:
	logger.debug(
		"CurveSessionState -> state=%s context='%s' (real: active_game_context='%s' mode='%s')"
		% [CurveSessionState.State.keys()[state], context_key, active_game_context, mode_manager.current_mode]
	)
	if state == CurveSessionState.State.LOADED:
		_on_curve_session_loaded(context_key)
	elif state == CurveSessionState.State.COMMITTED:
		_on_curve_session_committed(context_key)


## The one place game_curves[context_key] gets written (tasks/18, etapa
## 4) — replaces _on_state_changed()'s old connection to
## mode_manager.mode_changed. Fires on every COMMITTED transition: a
## real Apply press (_on_apply_pressed(), via
## profiles_panel.active_profile_changed) just as much as a user-driven
## mode switch (ModeSelectOverlay._on_mode_selected() calling
## profiles_panel.apply_current() directly — see its doc comment for
## why that's the one that also covers the per-game-off/profiles case).
## Only enqueues — never flushes: whoever triggered the commit
## (ProfileManagerPanel._commit_save(), always) owns flushing once its
## own top-level operation is fully settled. See store.enqueue()'s doc
## comment for why the read has to be lazy.
func _on_curve_session_committed(context_key: String) -> void:
	if not per_game_enabled or context_key.is_empty():
		return
	store.enqueue(func(): _snapshot(context_key))


## The one place a per-context curve moves from disk into the curve
## engines (tasks/18, etapa 3) — replaces the logic previously
## duplicated between _on_mode_changed() and _apply_context(). Runs on
## every LOADED transition, from both context_switched() (a context
## switch, whether or not it also changes mode) and
## mode_changed_to_custom() (a mode change for the already-active
## context) — between the two, every path that can bring the hardware
## into "custom mode, context_key active" ends up here exactly once,
## including the case where mode was already custom before the switch
## (context_switched() alone covers it, since mode_changed_to_custom()
## never fires when set_mode() no-ops).
##
## Deliberately does NOT apply by active_profile's name: with the
## profile picker UI hidden, every context shares the same single
## "Default" profile record, so applying by name would load whichever
## context last overwrote it instead of this context's own curve.
## game_curves[context_key]["curve"] is captured live per-context (see
## _snapshot()) and is the only thing that actually isolates one
## context from another.
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
## class hasn't seen before — engines are created once and reused for
## the whole session (see FanModeManager._ensure_curve_engine()), so
## each only needs connecting once, whichever call site (_ready(),
## _on_mode_changed(), _on_curve_session_loaded()) first gets a chance
## to see it. Replaces ProfileManagerPanel's old per-engine
## curve_changed connection (tasks/18, etapa 2): dirty-tracking is now
## owned here.
func _track_curve_engines_for_dirty(engines: Dictionary) -> void:
	for fan_id in engines:
		if _tracked_curve_engine_fan_ids.has(fan_id):
			continue
		_tracked_curve_engine_fan_ids[fan_id] = true
		engines[fan_id].curve_changed.connect(_on_curve_engine_edited)


## Signal handler for CustomCurveEngine.curve_changed: a slider was
## dragged. Doesn't distinguish which fan/context — any edit marks the
## whole session dirty, matching the old ProfileManagerPanel behavior
## this replaces.
func _on_curve_engine_edited(_curve: Dictionary) -> void:
	curve_session.slider_edited()
