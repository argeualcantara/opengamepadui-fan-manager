extends RefCounted
class_name CurveSessionState

# tracks whether the curve currently loaded in the engines is clean, edited
# or committed, for whatever context is active. used to used to be inferred
# from signal ordering across a bunch of classes which caused bugs, so now
# it's just one state machine.
#
# pure state, no I/O. callers do the actual work (loading curves, writing
# to disk, updating the dirty badge). state_changed fires every time a
# transition function runs, even if the enum value didn't actually change -
# that mattered for the dirty badge not resetting right.

const FanCurveUtils = preload("res://plugins/fan-manager/core/persistence/fan_curve_utils.gd")

enum State { UNTRACKED, LOADED, DIRTY, COMMITTED }

# state is deliberately untyped here (not ": State"). when OGUI loads this
# plugin from a zip, Godot's class_name cache doesn't get populated, and
# this file's own State can end up as a different type identity than
# CurveSessionState.State seen through the preload()'d const other scripts
# use - which fails compilation on real hardware. untyped sidesteps that.
signal state_changed(state, context_key: String)

var logger := Log.get_logger("FanManager CurveSessionState")

var state = State.UNTRACKED
var context_key: String = ""


func context_switched(new_context_key: String) -> void:
	state = State.LOADED
	context_key = new_context_key
	logger.debug("context_switched('%s')" % new_context_key)
	state_changed.emit(state, context_key)


func mode_changed_to_custom() -> void:
	state = State.LOADED
	logger.debug("mode_changed_to_custom(): context='%s'" % context_key)
	state_changed.emit(state, context_key)


func slider_edited() -> void:
	if state != State.LOADED and state != State.COMMITTED:
		return
	state = State.DIRTY
	logger.debug("slider_edited(): context='%s'" % context_key)
	state_changed.emit(state, context_key)


func apply_pressed() -> void:
	if state == State.UNTRACKED:
		return
	state = State.COMMITTED
	logger.debug("apply_pressed(): context='%s'" % context_key)
	state_changed.emit(state, context_key)


func per_game_toggled_off() -> void:
	state = State.LOADED
	context_key = FanCurveUtils.GLOBAL_DEFAULT_CONTEXT_KEY
	logger.debug("per_game_toggled_off()")
	state_changed.emit(state, context_key)


func per_game_toggled_on(current_context_key: String) -> void:
	context_switched(current_context_key)
