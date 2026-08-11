extends GutTest

## set_point()'s monotonicity rule and curve state are pure enough to
## test without adding the engine to the scene tree: its guard clause
## (`if _poll_timer:`) makes it safe to call set_point()/get_curve() on
## a bare CustomCurveEngine.new() whose _ready() (and therefore the
## timer) never ran. Timer/polling behavior itself is validated
## manually per tasks/10-testes-validacao.md.

class StubBackend extends FanBackend:
	var applied_curves: Array[Dictionary] = []
	var apply_should_succeed := true

	func apply_custom_curve(_fan_id: String, curve: Dictionary) -> bool:
		applied_curves.append(curve.duplicate(true))
		return apply_should_succeed


var engine: CustomCurveEngine


func before_each() -> void:
	engine = CustomCurveEngine.new()


func test_set_point_updates_curve_value() -> void:
	engine.set_point(30, 20.0)
	assert_eq(engine.get_curve()[30], 20.0)


func test_set_point_pushes_higher_points_up_when_exceeded() -> void:
	engine._curve = {10: 0.0, 20: 10.0, 30: 20.0, 40: 30.0, 50: 40.0}

	engine.set_point(30, 60.0)

	var curve := engine.get_curve()
	assert_eq(curve[30], 60.0)
	assert_eq(curve[40], 60.0, "40 was below 60, should be pushed up")
	assert_eq(curve[50], 60.0, "50 was below 60, should be pushed up")


func test_set_point_does_not_raise_lower_points_already_below_the_new_value() -> void:
	engine._curve = {10: 0.0, 20: 10.0, 30: 20.0, 40: 30.0}

	engine.set_point(30, 60.0)

	var curve := engine.get_curve()
	assert_eq(curve[10], 0.0)
	assert_eq(curve[20], 10.0)


func test_set_point_does_not_lower_higher_points_already_above_it() -> void:
	engine._curve = {10: 0.0, 20: 10.0, 30: 90.0, 40: 30.0}

	engine.set_point(20, 15.0)

	var curve := engine.get_curve()
	# 30 was already at 90%, well above the new 15% at 20: must stay.
	assert_eq(curve[30], 90.0)
	# 40 was at 30%, above the new 15% at 20: must also stay untouched
	# (the rule only pushes points that are BELOW the new value).
	assert_eq(curve[40], 30.0)


func test_set_point_pulls_lower_points_down_when_undercut() -> void:
	# Bidirectional rule (REQUIREMENTS.md §2.3): lowering a point must
	# pull down any lower-temperature point that's now above it,
	# mirroring the "push up" rule so the curve can't go decreasing in
	# either direction.
	engine._curve = {10: 0.0, 20: 50.0, 30: 80.0, 40: 90.0}

	engine.set_point(30, 20.0)

	var curve := engine.get_curve()
	assert_eq(curve[30], 20.0)
	assert_eq(curve[20], 20.0, "20 was above the new value at 30 and must be pulled down")
	assert_eq(curve[10], 0.0, "10 was already below the new value and must stay untouched")
	assert_eq(curve[40], 90.0, "40 is above 30 and already >= the new value, must stay untouched")


func test_set_point_does_not_lower_upper_points_when_undercutting_below() -> void:
	engine._curve = {10: 0.0, 20: 50.0, 30: 80.0}

	engine.set_point(20, 10.0)

	var curve := engine.get_curve()
	assert_eq(curve[20], 10.0)
	assert_eq(curve[30], 80.0, "30 is above 20; the downward pull must not cross to the other side")


func test_set_point_clamps_to_0_100_range() -> void:
	engine.set_point(50, 150.0)
	assert_eq(engine.get_curve()[50], 100.0)

	engine.set_point(50, -20.0)
	assert_eq(engine.get_curve()[50], 0.0)


func test_set_point_emits_curve_changed_with_the_updated_curve() -> void:
	watch_signals(engine)
	engine.set_point(30, 42.0)

	assert_signal_emitted(engine, "curve_changed")
	var emitted_curve: Dictionary = get_signal_parameters(engine, "curve_changed")[0]
	assert_eq(emitted_curve[30], 42.0)


func test_get_curve_returns_a_copy_not_a_reference() -> void:
	engine._curve = {30: 20.0}
	var curve := engine.get_curve()
	curve[30] = 999.0

	assert_eq(engine.get_curve()[30], 20.0, "mutating the returned copy must not affect engine state")


func test_start_normalizes_string_keyed_curve() -> void:
	var backend := StubBackend.new()
	engine.start(backend, "fan-0", {"10": 0, "20": 20, "30": 40})

	var curve := engine.get_curve()
	assert_true(curve.has(10))
	assert_true(curve.has(20))
	assert_true(curve.has(30))
	assert_false(curve.has("10"))


func test_start_immediately_applies_the_curve() -> void:
	var backend := StubBackend.new()
	engine.start(backend, "fan-0", {10: 0, 20: 50})

	assert_eq(backend.applied_curves.size(), 1)


func test_load_curve_replaces_working_curve_and_applies_it() -> void:
	var backend := StubBackend.new()
	engine.start(backend, "fan-0", {10: 0, 20: 50})

	engine.load_curve({10: 5, 20: 90})

	assert_eq(engine.get_curve(), {10: 5.0, 20: 90.0})
	assert_eq(backend.applied_curves.size(), 2)
	assert_eq(backend.applied_curves[1], {10: 5, 20: 90})


func test_load_curve_does_nothing_before_start() -> void:
	var backend := StubBackend.new()
	engine.load_curve({10: 5})

	assert_true(engine.get_curve().is_empty())
	assert_eq(backend.applied_curves.size(), 0)


func test_set_point_does_not_write_to_hardware() -> void:
	# Dragging a slider is a pure in-memory draft edit: only
	# commit_draft() (the user clicking "Save") applies it.
	var backend := StubBackend.new()
	engine.start(backend, "fan-0", {10: 0, 20: 50})
	backend.applied_curves.clear()

	engine.set_point(20, 77.0)

	assert_true(backend.applied_curves.is_empty(), "set_point() must not write to hardware")
	assert_eq(engine.get_curve()[20], 77.0, "the draft must still reflect the edit")


func test_commit_draft_applies_the_edited_curve_to_hardware() -> void:
	var backend := StubBackend.new()
	engine.start(backend, "fan-0", {10: 0, 20: 50})
	backend.applied_curves.clear()

	engine.set_point(20, 77.0)
	engine.commit_draft()

	assert_eq(backend.applied_curves.size(), 1)
	assert_eq(backend.applied_curves[0][20], 77.0)


func test_poll_reapplies_committed_curve_not_the_uncommitted_draft() -> void:
	var backend := StubBackend.new()
	engine.start(backend, "fan-0", {10: 0, 20: 50})

	engine.set_point(20, 77.0)  # draft only, not committed
	engine._apply_now()  # simulates a poll tick without a real Timer

	# The last thing actually written to hardware must still be the
	# original committed curve (20 -> 50), not the uncommitted draft
	# edit (20 -> 77).
	assert_eq(backend.applied_curves[-1][20], 50.0)
