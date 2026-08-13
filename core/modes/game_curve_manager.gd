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
##   captured into the active context's config immediately. Curve edits
##   are NOT: dragging a slider never writes anything (mirrors
##   CustomCurveEngine's own draft/committed split — see its doc
##   comment). The curve is only snapshotted when ModeSelectOverlay's
##   Apply button commits the draft to hardware and ProfileManagerPanel
##   reports the resulting active_profile_changed — see
##   _on_state_changed() below.
##
## Referenced via preload()'d consts, not bare class_name lookups: see
## hwmon_fan_backend.gd's header comment for why.
const FanCurveStore = preload("res://plugins/fan-manager/core/persistence/fan_curve_store.gd")
const FanModeManager = preload("res://plugins/fan-manager/core/modes/fan_mode_manager.gd")
const ProfileManagerPanel = preload("res://plugins/fan-manager/core/ui/components/profile_manager_panel.gd")
const FanCurveUtils = preload("res://plugins/fan-manager/core/persistence/fan_curve_utils.gd")

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
		elif mode_manager.current_mode == "custom":
			# Turning tracking off otherwise leaves whichever context's
			# curve was last active sitting in the engines/on hardware
			# with no indication anything changed. Snap back to the
			# single shared "Default" profile — the same curve Apply
			# now writes to while per-game is off (see
			# ProfileManagerPanel._commit_save()) — so the UI and
			# hardware match what'll actually get edited/saved from
			# here on. profiles["Default"] has no mode of its own (only
			# a per-fan curve), so this only makes sense while already
			# in custom mode; no-op (with a log warning) if "Default"
			# doesn't exist yet.
			profiles_panel.apply_profile(FanCurveUtils.DEFAULT_PROFILE_NAME)
			# apply_profile() updates the engines (and hardware) directly
			# but never emits curve_applied — unlike _apply_context()/
			# _on_mode_changed() below, which always do. Without this,
			# the curve underneath changes but the visible sliders never
			# get told to re-pull it (see curve_applied's doc comment).
			curve_applied.emit()


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
	mode_manager.mode_changed.connect(_on_state_changed)
	profiles_panel.active_profile_changed.connect(_on_state_changed)

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
## for a saved context — reloads the active context's curve straight
## from the store's document. Never trusts whatever curve happens to
## still be sitting in the engine: CustomCurveEngine instances are one
## per fan_id, shared by every context, so the engine's in-memory curve
## can be leftover data from whichever context was active last. The
## store's document is the source of truth for what THIS context's
## curve actually is; store.load_data() returns the shared in-memory
## copy rather than re-reading disk, so this always sees a fully
## up-to-date, consistent state, even mid-flush (see FanCurveStore's
## enqueue()/flush() doc comments for why that's race-safe).
func _on_mode_changed(mode: String) -> void:
	if mode != "custom" or not per_game_enabled or active_game_context.is_empty():
		return

	var data: Dictionary = store.load_data(hardware_id)
	var game_curves: Dictionary = data.get("game_curves", {})
	if not game_curves.has(active_game_context):
		return

	var curve: Dictionary = game_curves[active_game_context].get("curve", {})
	if curve.is_empty():
		return

	var engines := mode_manager.get_all_curve_engines()
	logger.debug(
		"_on_mode_changed('%s'): reloading curve from store for context '%s': %s"
		% [mode, active_game_context, curve]
	)
	for fan_id in curve:
		if engines.has(fan_id):
			engines[fan_id].load_curve(curve[fan_id])

	curve_applied.emit()


## Signal handler for mode_changed/active_profile_changed: those are
## already discrete, deliberate actions (not a continuous drag), so
## they're captured into the active context's config. Only enqueues —
## never flushes: whoever triggered the signal (ModeSelectOverlay,
## ProfileManagerPanel, or GameCurveManager's own _apply_context())
## owns flushing once its own top-level operation is fully settled.
## See store.enqueue()'s doc comment for why the read has to be lazy.
func _on_state_changed(_arg = null) -> void:
	if not per_game_enabled or active_game_context.is_empty():
		return

	var context_key := active_game_context
	store.enqueue(func(): _snapshot(context_key))


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
## saved["curve"] is captured live per-context (see _snapshot()) and
## is the only thing that actually isolates one context from another.
func _apply_context(saved: Dictionary) -> void:
	var mode: String = saved.get("mode", "")
	logger.debug("_apply_context('%s'): %s" % [active_game_context, saved])
	if mode.is_empty():
		return

	# If mode already equals current_mode, set_mode() below is a no-op
	# and mode_changed never fires — so _on_mode_changed() (which is
	# what normally reloads this context's curve on becoming "custom")
	# never runs either. Track that here so this context's curve still
	# gets applied explicitly in that case, right below.
	var was_already_in_mode := mode == mode_manager.current_mode

	# set_mode() only mutates the in-memory document and enqueues (via
	# _on_state_changed(), if it actually changes mode) — it never
	# flushes. That's what makes it safe to call here even though the
	# curve below hasn't been loaded yet: nothing hits disk until this
	# function's own flush() at the bottom.
	if not mode_manager.set_mode(mode):
		logger.warn(
			"Saved mode '%s' for context '%s' is no longer valid; keeping current mode"
			% [mode, active_game_context]
		)
		return

	logger.info("Applied per-game config for context '%s'" % active_game_context)

	# A real mode switch to "custom" already went through
	# _on_mode_changed() above, via the mode_changed signal set_mode()
	# just emitted — it reloads this exact same curve from the store.
	# Only the no-op case (already in the right mode) needs it applied
	# explicitly here.
	if was_already_in_mode and mode == "custom":
		var curve: Dictionary = saved.get("curve", {})
		var engines := mode_manager.get_all_curve_engines()
		logger.debug("_apply_context('%s'): loading raw per-fan curve %s" % [active_game_context, curve])
		for fan_id in curve:
			if engines.has(fan_id):
				engines[fan_id].load_curve(curve[fan_id])

		curve_applied.emit()

	store.flush()


## Runs (only from inside store.flush(), via the job enqueued in
## _on_state_changed()) to capture the current mode/active_profile/
## per-fan curves and stage them under context_key. No-op if there are
## no curve engines yet.
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
