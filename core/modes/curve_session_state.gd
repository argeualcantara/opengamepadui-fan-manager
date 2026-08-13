extends RefCounted
class_name CurveSessionState

## Tracks, for the active game context, whether the curve currently
## loaded into the (shared, per-fan) CustomCurveEngine instances is
## clean, edited, or committed, the one thing that was previously
## inferred implicitly from signal ordering across GameCurveManager,
## FanModeManager, ProfileManagerPanel, and ModeSelectOverlay (see
## tasks/18-state-machine-curva-por-etapas.md for the bugs that came
## from that).
##
## Pure state only: no I/O, no engines/store access. Every transition
## below just updates state/context_key and emits state_changed,
## callers are the ones responsible for the actual side effects
## (load_curve(), writing game_curves/profiles, updating the dirty
## badge). state_changed fires on every transition call, even if the
## resulting State value is textually the same as before (e.g.
## apply_pressed() while already COMMITTED): each call represents a
## real event that happened, not just a memoized value, collapsing
## "did the enum value change" into "did the event happen" was itself
## the cause of at least one bug fixed this session (the dirty badge
## not resetting).

enum State { UNTRACKED, LOADED, DIRTY, COMMITTED }

## STEAM_HOME_KEY equivalent for per_game_toggled_off(): the "Default"
## profile has no context of its own, so it gets this sentinel key
## instead of a real game/Steam Home name.
const DEFAULT_PROFILE_CONTEXT_KEY := "__default__"

## state's parameter/var are deliberately untyped (not `: State`), even
## though this file is exactly where State is defined: OGUI loads
## plugins from a zip via ProjectSettings.load_resource_pack(), which
## never populates Godot's global class_name cache (see
## hwmon_fan_backend.gd's header comment for the canonical writeup of
## this gotcha). Under that loading path, this file's own bare `State`
## and `CurveSessionState.State` as seen through the preload()'d const
## other scripts use (game_curve_manager.gd, mode_select_overlay.gd)
## can end up as two distinct type identities for the compiler, which
## fails the whole plugin to compile with "Cannot assign a value of
## type CurveSessionState.State to variable "state" with specified
## type State", confirmed on real hardware (tasks/18). Untyped avoids
## the cross-script identity check entirely; enums are just ints at
## runtime, so this costs only compile-time checking within this file.
signal state_changed(state, context_key: String)

var logger := Log.get_logger("FanManager CurveSessionState")

var state = State.UNTRACKED
var context_key: String = ""


## A context became active (a game switch, Steam Home, or per-game
## tracking just turned on): whatever was loaded before, including an
## unsaved DIRTY edit, is irrelevant now, since the engines are about
## to be reloaded with new_context_key's own curve.
func context_switched(new_context_key: String) -> void:
	state = State.LOADED
	context_key = new_context_key
	logger.debug("context_switched('%s')" % new_context_key)
	state_changed.emit(state, context_key)


## The hardware just switched into custom mode (however that
## happened) for the context already tracked here. Re-enters LOADED
## without changing context_key.
func mode_changed_to_custom() -> void:
	state = State.LOADED
	logger.debug("mode_changed_to_custom(): context='%s'" % context_key)
	state_changed.emit(state, context_key)


## A slider was dragged: only meaningful once a context's curve is
## actually loaded (LOADED or re-editing after a previous COMMITTED);
## no-op while UNTRACKED or already DIRTY.
func slider_edited() -> void:
	if state != State.LOADED and state != State.COMMITTED:
		return
	state = State.DIRTY
	logger.debug("slider_edited(): context='%s'" % context_key)
	state_changed.emit(state, context_key)


## Apply was pressed: commits whatever's currently loaded, regardless
## of whether it was actually edited (mirrors ModeSelectOverlay's
## Apply button, which has no dirty guard today). No-op while
## UNTRACKED, there's no context to commit to.
func apply_pressed() -> void:
	if state == State.UNTRACKED:
		return
	state = State.COMMITTED
	logger.debug("apply_pressed(): context='%s'" % context_key)
	state_changed.emit(state, context_key)


## Per-game tracking just turned off: snaps to the single shared
## "Default" profile regardless of prior state/context, there's no
## per-context curve to track anymore.
func per_game_toggled_off() -> void:
	state = State.LOADED
	context_key = DEFAULT_PROFILE_CONTEXT_KEY
	logger.debug("per_game_toggled_off()")
	state_changed.emit(state, context_key)


## Per-game tracking just turned on for current_context_key (whatever
## app is running right now, or Steam Home).
func per_game_toggled_on(current_context_key: String) -> void:
	context_switched(current_context_key)
