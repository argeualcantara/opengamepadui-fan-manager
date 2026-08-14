extends GutTest

class FakeLaunchItem extends RefCounted:
	var name: String

	func _init(n: String) -> void:
		name = n


class FakeRunningApp extends RefCounted:
	var launch_item: FakeLaunchItem

	func _init(n: String) -> void:
		launch_item = FakeLaunchItem.new(n)


## Lightweight double for OGUI's LaunchManager: only exposes what
## GameCurveManager actually uses (app_switched, all_apps_stopped,
## get_current_app()), so tests don't depend on instantiating the real
## Resource singleton.
class FakeLaunchManager extends RefCounted:
	signal app_switched(from, to)
	signal all_apps_stopped()

	var _current = null

	func get_current_app():
		return _current

	func switch_to(app) -> void:
		var previous = _current
		_current = app
		app_switched.emit(previous, app)

	func stop_all() -> void:
		_current = null
		all_apps_stopped.emit()


class StubBackend extends FanBackend:
	var supported := true
	var hardware_id_value := "gut-gamecurve-test"
	var bios_curve := {10: 0.0, 20: 0.0, 30: 15.0, 40: 25.0, 50: 35.0, 60: 45.0, 70: 60.0, 80: 75.0, 90: 90.0, 100: 100.0}
	var applied_curves: Array[Dictionary] = []

	func is_supported() -> bool:
		return supported

	func get_hardware_id() -> String:
		return hardware_id_value

	func list_fans() -> Array[String]:
		return ["fan-0"]

	func get_bios_curve(_fan_id: String) -> Dictionary:
		return bios_curve

	func set_mode(_mode: String) -> bool:
		return true

	func apply_custom_curve(_fan_id: String, curve: Dictionary) -> bool:
		applied_curves.append(curve.duplicate(true))
		return true

	func read_temperature(_fan_id: String) -> float:
		return 50.0


var store: FanCurveStore
var backend: StubBackend
var registry: FanBackendRegistry
var mode_manager: FanModeManager
var profiles_panel: ProfileManagerPanel
var launch_manager: FakeLaunchManager
var manager: GameCurveManager

var _test_hardware_id := "gut-gamecurve-test"
var _fan_id := "fan-0"


func before_each() -> void:
	store = FanCurveStore.new()
	backend = StubBackend.new()
	backend.hardware_id_value = _test_hardware_id

	registry = FanBackendRegistry.new()
	registry.register(backend)

	mode_manager = FanModeManager.new(registry, store)
	add_child_autoqfree(mode_manager)
	await wait_frames(1, "let FanModeManager._ready() run")

	profiles_panel = ProfileManagerPanel.new()
	add_child_autoqfree(profiles_panel)
	await wait_frames(1, "let ProfileManagerPanel._ready() run")
	profiles_panel.refresh(store, _test_hardware_id, mode_manager.get_all_curve_engines())

	# In production, ModeSelectOverlay re-syncs ProfileManagerPanel with
	# the (possibly newly-created) per-fan engines whenever the mode
	# changes: replicated here since no overlay is instantiated in
	# this test.
	mode_manager.mode_changed.connect(
		func(_mode): profiles_panel.refresh(store, _test_hardware_id, mode_manager.get_all_curve_engines())
	)

	launch_manager = FakeLaunchManager.new()

	manager = GameCurveManager.new(launch_manager, store, mode_manager, profiles_panel, _test_hardware_id)
	add_child_autoqfree(manager)
	await wait_frames(1, "let GameCurveManager._ready() run")


func after_each() -> void:
	var path := store._path_for(_test_hardware_id)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


func _engine() -> CustomCurveEngine:
	return mode_manager.get_curve_engine(_fan_id)


func test_disabled_by_default() -> void:
	assert_false(manager.per_game_enabled)


func test_context_tracking_updates_regardless_of_toggle() -> void:
	launch_manager.switch_to(FakeRunningApp.new("Cyberpunk 2077"))

	assert_eq(manager.active_game_context, "cyberpunk 2077")
	var data := store.load_data(_test_hardware_id)
	assert_eq(data["active_game_context"], "cyberpunk 2077")


func test_null_app_maps_to_steam_home_context() -> void:
	launch_manager.switch_to(FakeRunningApp.new("Hades"))
	launch_manager.switch_to(null)

	assert_eq(manager.active_game_context, GameCurveManager.STEAM_HOME_KEY)


func test_all_apps_stopped_maps_to_steam_home_context() -> void:
	launch_manager.switch_to(FakeRunningApp.new("Hades"))

	launch_manager.stop_all()

	assert_eq(manager.active_game_context, GameCurveManager.STEAM_HOME_KEY)


func test_all_apps_stopped_restores_steam_home_config() -> void:
	var data := store.load_data(_test_hardware_id)
	data["game_curves"] = {
		GameCurveManager.STEAM_HOME_KEY: {
			"mode": "custom", "active_profile": null, "curve": {_fan_id: {10: 1.0, 20: 2.0}}
		}
	}
	store.save(_test_hardware_id, data)

	manager.per_game_enabled = true
	launch_manager.switch_to(FakeRunningApp.new("Hades"))
	mode_manager.set_mode("custom")
	_engine().set_point(30, 77.0)

	launch_manager.stop_all()

	assert_eq(mode_manager.current_mode, "custom")
	assert_eq(_engine().get_curve(), {10: 1.0, 20: 2.0})


func test_switching_context_without_saved_config_leaves_state_untouched() -> void:
	manager.per_game_enabled = true
	var mode_before := mode_manager.current_mode

	launch_manager.switch_to(FakeRunningApp.new("Elden Ring"))

	assert_eq(mode_manager.current_mode, mode_before)


func test_state_change_with_toggle_off_does_not_save_a_config() -> void:
	launch_manager.switch_to(FakeRunningApp.new("Hades"))
	mode_manager.set_mode("custom")

	var data := store.load_data(_test_hardware_id)
	assert_false(data.get("game_curves", {}).has("hades"))


func test_mode_change_with_toggle_on_saves_full_state_for_active_context() -> void:
	manager.per_game_enabled = true
	launch_manager.switch_to(FakeRunningApp.new("Hades"))

	mode_manager.set_mode("custom")
	# A bare set_mode() no longer persists anything by itself (tasks/18,
	# etapa 4): production drives this through ModeSelectOverlay.
	# _on_mode_selected(), which calls profiles_panel.apply_current()
	# right after a successful set_mode(), that's what actually
	# commits curve_session to COMMITTED and triggers the game_curves
	# write, via GameCurveManager._on_curve_session_committed().
	profiles_panel.apply_current()

	var data := store.load_data(_test_hardware_id)
	assert_true(data["game_curves"].has("hades"))
	assert_eq(data["game_curves"]["hades"]["mode"], "custom")


func test_curve_edit_alone_does_not_save_a_config() -> void:
	# Dragging a slider must never write anything by itself, only
	# pressing Apply (profiles_panel.apply_current(), which commits the
	# draft to hardware and emits active_profile_changed) does.
	manager.per_game_enabled = true
	launch_manager.switch_to(FakeRunningApp.new("Hades"))
	mode_manager.set_mode("custom")

	_engine().set_point(30, 77.0)

	var data := store.load_data(_test_hardware_id)
	assert_false(data.get("game_curves", {}).has("hades"))


func test_pressing_apply_saves_the_current_curve_for_active_context() -> void:
	manager.per_game_enabled = true
	launch_manager.switch_to(FakeRunningApp.new("Hades"))
	mode_manager.set_mode("custom")

	_engine().set_point(30, 77.0)
	profiles_panel.apply_current()

	var data := store.load_data(_test_hardware_id)
	var saved_curve: Dictionary = FanCurveUtils.normalize_keys(data["game_curves"]["hades"]["curve"][_fan_id])
	assert_eq(saved_curve[30], 77.0)


func test_switching_to_bios_persists_the_mode_change_for_the_active_context() -> void:
	# Regression for the gap found after etapa 1: switching to BIOS
	# must still persist game_curves[contexto], same as it always has.
	# Simulates exactly what ModeSelectOverlay._on_mode_selected() does
	# for a bios target (tasks/18, revised after etapa 4): set_mode()
	# then curve_session.apply_pressed() directly, NOT
	# profiles_panel.apply_current(), which would call
	# engine.commit_draft() and, on real ASUS hardware, silently flip
	# pwm_enable back to manual right after set_mode() just switched it
	# to bios (confirmed via device log). Going to bios never needs a
	# hardware push or a profiles["Default"] write: the curve itself
	# didn't change, only the mode did.
	var data := store.load_data(_test_hardware_id)
	data["game_curves"] = {
		"hades": {"mode": "custom", "active_profile": null, "curve": {_fan_id: {10: 5.0, 20: 10.0}}}
	}
	store.save(_test_hardware_id, data)

	manager.per_game_enabled = true
	launch_manager.switch_to(FakeRunningApp.new("Hades"))
	assert_eq(mode_manager.current_mode, "custom")

	mode_manager.set_mode("bios")
	manager.curve_session.apply_pressed()
	store.flush()

	var reloaded := store.load_data(_test_hardware_id)
	assert_eq(reloaded["game_curves"]["hades"]["mode"], "bios")
	var saved_curve: Dictionary = FanCurveUtils.normalize_keys(
		reloaded["game_curves"]["hades"]["curve"][_fan_id]
	)
	assert_eq(saved_curve, {10: 5.0, 20: 10.0}, "curve must survive a switch to bios, unedited")


func test_switching_to_bios_does_not_commit_the_draft_curve_to_hardware() -> void:
	# Regression for the bug found via real device log (tasks/18): the
	# old etapa 4 design routed every mode switch through
	# profiles_panel.apply_current(), which calls engine.commit_draft()
	# unconditionally. On real ASUS hardware, apply_custom_curve()
	# itself flips pwm_enable back to manual whenever it isn't already
	#, silently undoing the bios switch set_mode() just made, at the
	# hardware level, the instant apply_current() ran. Simulating the
	# corrected ModeSelectOverlay behavior (curve_session.apply_pressed()
	# instead of apply_current() for a bios target) must not touch the
	# backend at all.
	mode_manager.set_mode("custom")
	backend.applied_curves = []

	mode_manager.set_mode("bios")
	manager.curve_session.apply_pressed()
	store.flush()

	assert_true(
		backend.applied_curves.is_empty(),
		"switching to bios must never push a curve to hardware"
	)


func test_switching_mode_with_toggle_off_saves_the_current_curve_to_default_profile() -> void:
	# Gap found in review: with per-game off, a mode switch previously
	# didn't save anything to profiles["Default"] at all, only
	# ProfileManagerPanel._commit_save() did, and only from a real
	# Apply press. Now ModeSelectOverlay._on_mode_selected() calls
	# apply_current() on every mode switch too, so an edit made just
	# before switching modes is captured either way.
	mode_manager.set_mode("custom")
	_engine().set_point(10, 42.0)

	mode_manager.set_mode("bios")
	profiles_panel.apply_current()

	var data := store.load_data(_test_hardware_id)
	var saved_curve: Dictionary = FanCurveUtils.normalize_keys(
		data["profiles"][FanCurveUtils.DEFAULT_PROFILE_NAME][_fan_id]
	)
	assert_eq(saved_curve[10], 42.0)


func test_applying_saved_context_restores_mode_and_curve() -> void:
	var data := store.load_data(_test_hardware_id)
	data["game_curves"] = {
		"hades": {"mode": "custom", "active_profile": null, "curve": {_fan_id: {10: 5.0, 20: 10.0}}}
	}
	store.save(_test_hardware_id, data)

	manager.per_game_enabled = true
	launch_manager.switch_to(FakeRunningApp.new("Hades"))

	assert_eq(mode_manager.current_mode, "custom")
	assert_eq(_engine().get_curve(), {10: 5.0, 20: 10.0})


func test_applying_saved_context_with_a_mode_change_does_not_corrupt_the_saved_curve() -> void:
	# Regression test: current mode starts as "bios" (fresh store), so
	# applying this saved "custom" context makes set_mode() actually
	# switch mode (not the same-mode no-op) and emit mode_changed
	# mid-_apply_context(), before store.flush() at the bottom. The
	# curve reload itself (see GameCurveManager._on_curve_session_loaded(),
	# tasks/18 etapa 3) runs synchronously off that same mode_changed,
	# via curve_session's LOADED transition, before the enqueued
	# snapshot job (lazy, only runs inside flush()) ever reads the
	# engines, so the snapshot always sees the corrected curve, never
	# whatever _start_custom_mode() had just seeded as a placeholder.
	var data := store.load_data(_test_hardware_id)
	data["game_curves"] = {
		"hades": {"mode": "custom", "active_profile": null, "curve": {_fan_id: {10: 5.0, 20: 10.0}}}
	}
	store.save(_test_hardware_id, data)
	assert_eq(mode_manager.current_mode, "bios", "sanity check: switching to this context must involve a real mode change")

	manager.per_game_enabled = true
	launch_manager.switch_to(FakeRunningApp.new("Hades"))

	var reloaded := store.load_data(_test_hardware_id)
	var saved_curve: Dictionary = FanCurveUtils.normalize_keys(
		reloaded["game_curves"]["hades"]["curve"][_fan_id]
	)
	assert_eq(saved_curve, {10: 5.0, 20: 10.0}, "the saved curve on disk must survive applying it")


func test_bios_context_still_seeds_engines_so_a_later_manual_custom_switch_keeps_its_own_curve() -> void:
	# Regression: Steam Home is custom with curve A, "Hades" is bios but
	# has its own saved curve B from an earlier session. Applying the
	# bios context used to skip loading B into the (shared, per-fan)
	# engines, leaving them holding Steam's A; a later manual switch to
	# custom inside Hades would then reuse that leaked A instead of B.
	var data := store.load_data(_test_hardware_id)
	data["game_curves"] = {
		GameCurveManager.STEAM_HOME_KEY: {
			"mode": "custom", "active_profile": null, "curve": {_fan_id: {10: 1.0, 20: 2.0}}
		},
		"hades": {
			"mode": "bios", "active_profile": null, "curve": {_fan_id: {10: 9.0, 20: 8.0}}
		},
	}
	store.save(_test_hardware_id, data)

	manager.per_game_enabled = true

	# Steam Home applies first (nothing running yet), loading curve A
	# into the shared fan-0 engine.
	assert_eq(_engine().get_curve(), {10: 1.0, 20: 2.0})

	# Entering Hades applies its saved "bios" context.
	launch_manager.switch_to(FakeRunningApp.new("Hades"))
	assert_eq(mode_manager.current_mode, "bios")

	# The user now manually switches Hades to custom mode by hand (not
	# via a saved-context apply): must reuse Hades' own curve B, not
	# whatever Steam Home last loaded into the shared engine.
	mode_manager.set_mode("custom")
	assert_eq(_engine().get_curve(), {10: 9.0, 20: 8.0})


func test_applying_saved_invalid_mode_falls_back_gracefully() -> void:
	var data := store.load_data(_test_hardware_id)
	data["game_curves"] = {"hades": {"mode": "turbo", "active_profile": null, "curve": {}}}
	store.save(_test_hardware_id, data)

	var mode_before := mode_manager.current_mode
	manager.per_game_enabled = true
	launch_manager.switch_to(FakeRunningApp.new("Hades"))

	assert_eq(mode_manager.current_mode, mode_before, "an invalid saved mode must not change anything")


func test_enabling_toggle_with_game_already_running_applies_immediately() -> void:
	launch_manager.switch_to(FakeRunningApp.new("Hades"))
	var data := store.load_data(_test_hardware_id)
	data["game_curves"] = {"hades": {"mode": "custom", "active_profile": null, "curve": {_fan_id: {10: 9.0}}}}
	store.save(_test_hardware_id, data)

	manager.per_game_enabled = true

	assert_eq(mode_manager.current_mode, "custom")
	assert_eq(_engine().get_curve(), {10: 9.0})


func test_disabling_toggle_in_bios_mode_still_reloads_default_profile() -> void:
	# Regression for the etapa 5 gap: apply_profile() only ever writes
	# curve points (never pwm_enable/mode), so reloading "Default" on
	# toggle-off must not depend on currently being in custom mode.
	store.save_profile(_test_hardware_id, FanCurveUtils.DEFAULT_PROFILE_NAME, {_fan_id: {10: 11.0, 20: 22.0}})

	# Populate curve_engines by visiting custom mode once (as a real
	# session would), then switch back to bios before toggling.
	mode_manager.set_mode("custom")
	mode_manager.set_mode("bios")
	assert_eq(mode_manager.current_mode, "bios")

	manager.per_game_enabled = true
	manager.per_game_enabled = false

	assert_eq(_engine().get_curve(), {10: 11.0, 20: 22.0})
	assert_eq(mode_manager.current_mode, "bios", "toggling per-game off must not itself change mode")


func test_disabling_toggle_in_bios_mode_does_not_leave_the_engine_polling() -> void:
	# Regression: apply_profile() -> CustomCurveEngine.load_curve() ->
	# start() always (re)starts the software poll timer when the
	# backend needs one (StubBackend defaults to requiring it, like
	# HwmonFanBackend). Reloading "Default" while in bios (the etapa 5
	# fix above) must not leave that timer running: FanModeManager.
	# set_mode() is the only other place that stops engines, and it
	# isn't involved in this toggle.
	mode_manager.set_mode("custom")
	mode_manager.set_mode("bios")
	assert_true(_engine()._poll_timer.is_stopped(), "sanity check: leaving custom mode already stops the engine")

	manager.per_game_enabled = true
	manager.per_game_enabled = false

	assert_true(_engine()._poll_timer.is_stopped(), "toggling per-game off in bios mode must not restart polling")


func test_disabling_toggle_persists() -> void:
	manager.per_game_enabled = true
	manager.per_game_enabled = false

	var data := store.load_data(_test_hardware_id)
	assert_false(data["per_game_enabled"])


func test_snapshot_bundles_curves_from_every_fan_engine() -> void:
	manager.per_game_enabled = true
	launch_manager.switch_to(FakeRunningApp.new("Hades"))
	mode_manager.set_mode("custom")

	# Simulate a second fan (e.g. GPU) getting its own engine, the way
	# FanModeManager would for a multi-fan backend.
	var second_engine := mode_manager._ensure_curve_engine("fan-1")
	second_engine.start(backend, "fan-1", {10: 3.0, 20: 6.0})
	profiles_panel.refresh(store, _test_hardware_id, mode_manager.get_all_curve_engines())

	_engine().set_point(30, 77.0)
	profiles_panel.apply_current()

	var data := store.load_data(_test_hardware_id)
	var saved_curve: Dictionary = data["game_curves"]["hades"]["curve"]
	assert_true(saved_curve.has(_fan_id))
	assert_true(saved_curve.has("fan-1"))
