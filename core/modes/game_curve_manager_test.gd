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
	var bios_curve := {10: 0, 20: 0, 30: 15, 40: 25, 50: 35, 60: 45, 70: 60, 80: 75, 90: 90, 100: 100}

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

	func apply_custom_curve(_fan_id: String, _curve: Dictionary) -> bool:
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
	var data := store.load(_test_hardware_id)
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
	var data := store.load(_test_hardware_id)
	data["game_curves"] = {
		GameCurveManager.STEAM_HOME_KEY: {
			"mode": "custom", "active_profile": null, "curve": {_fan_id: {10: 1, 20: 2}}
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

	var data := store.load(_test_hardware_id)
	assert_false(data.get("game_curves", {}).has("hades"))


func test_mode_change_with_toggle_on_saves_full_state_for_active_context() -> void:
	manager.per_game_enabled = true
	launch_manager.switch_to(FakeRunningApp.new("Hades"))

	mode_manager.set_mode("custom")

	var data := store.load(_test_hardware_id)
	assert_true(data["game_curves"].has("hades"))
	assert_eq(data["game_curves"]["hades"]["mode"], "custom")


func test_curve_edit_with_toggle_on_saves_config_for_active_context() -> void:
	manager.per_game_enabled = true
	launch_manager.switch_to(FakeRunningApp.new("Hades"))
	mode_manager.set_mode("custom")

	_engine().set_point(30, 77.0)

	var data := store.load(_test_hardware_id)
	var saved_curve: Dictionary = FanCurveUtils.normalize_keys(data["game_curves"]["hades"]["curve"][_fan_id])
	assert_eq(saved_curve[30], 77.0)


func test_applying_saved_context_restores_mode_and_curve() -> void:
	var data := store.load(_test_hardware_id)
	data["game_curves"] = {
		"hades": {"mode": "custom", "active_profile": null, "curve": {_fan_id: {10: 5, 20: 10}}}
	}
	store.save(_test_hardware_id, data)

	manager.per_game_enabled = true
	launch_manager.switch_to(FakeRunningApp.new("Hades"))

	assert_eq(mode_manager.current_mode, "custom")
	assert_eq(_engine().get_curve(), {10: 5.0, 20: 10.0})


func test_applying_saved_context_selects_named_profile() -> void:
	store.save_profile(_test_hardware_id, "Silencioso", {_fan_id: {10: 1, 20: 2}})
	var data := store.load(_test_hardware_id)
	data["game_curves"] = {"hades": {"mode": "custom", "active_profile": "Silencioso", "curve": {}}}
	store.save(_test_hardware_id, data)

	manager.per_game_enabled = true
	launch_manager.switch_to(FakeRunningApp.new("Hades"))

	assert_eq(mode_manager.current_mode, "custom")
	assert_eq(_engine().get_curve(), {10: 1.0, 20: 2.0})


func test_applying_saved_invalid_mode_falls_back_gracefully() -> void:
	var data := store.load(_test_hardware_id)
	data["game_curves"] = {"hades": {"mode": "turbo", "active_profile": null, "curve": {}}}
	store.save(_test_hardware_id, data)

	var mode_before := mode_manager.current_mode
	manager.per_game_enabled = true
	launch_manager.switch_to(FakeRunningApp.new("Hades"))

	assert_eq(mode_manager.current_mode, mode_before, "an invalid saved mode must not change anything")


func test_enabling_toggle_with_game_already_running_applies_immediately() -> void:
	launch_manager.switch_to(FakeRunningApp.new("Hades"))
	var data := store.load(_test_hardware_id)
	data["game_curves"] = {"hades": {"mode": "custom", "active_profile": null, "curve": {_fan_id: {10: 9}}}}
	store.save(_test_hardware_id, data)

	manager.per_game_enabled = true

	assert_eq(mode_manager.current_mode, "custom")
	assert_eq(_engine().get_curve(), {10: 9.0})


func test_disabling_toggle_persists() -> void:
	manager.per_game_enabled = true
	manager.per_game_enabled = false

	var data := store.load(_test_hardware_id)
	assert_false(data["per_game_enabled"])


func test_snapshot_bundles_curves_from_every_fan_engine() -> void:
	manager.per_game_enabled = true
	launch_manager.switch_to(FakeRunningApp.new("Hades"))
	mode_manager.set_mode("custom")

	# Simulate a second fan (e.g. GPU) getting its own engine, the way
	# FanModeManager would for a multi-fan backend.
	var second_engine := mode_manager._ensure_curve_engine("fan-1")
	second_engine.start(backend, "fan-1", {10: 3, 20: 6})

	_engine().set_point(30, 77.0)

	var data := store.load(_test_hardware_id)
	var saved_curve: Dictionary = data["game_curves"]["hades"]["curve"]
	assert_true(saved_curve.has(_fan_id))
	assert_true(saved_curve.has("fan-1"))
