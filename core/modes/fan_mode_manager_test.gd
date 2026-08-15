extends GutTest

class MockBackend extends FanBackend:
	var supported := true
	var hardware_id_value := "mock-hardware"
	# Only read by _adopt_current_custom_curve() now (the hardware was
	# already in custom mode on a genuinely first run): the normal
	# "no profile saved" path no longer reads this at all, see
	# FanCurveUtils.DEFAULT_BALANCED_CURVE / test_custom_mode_creates_default_profile_when_none_saved.
	var bios_curve := {10: 0, 20: 0, 30: 15, 40: 25, 50: 35, 60: 45, 70: 60, 80: 75, 90: 90, 100: 100}
	var mode_calls: Array[String] = []
	var fail_next_set_mode := false
	var polling_required := true
	var applied_curves: Array[Dictionary] = []
	# What get_current_mode() reports: "" (unknown) by default, like a
	# freshly-detected backend with no assumptions made yet.
	var current_mode_value := ""

	func is_supported() -> bool:
		return supported

	func get_hardware_id() -> String:
		return hardware_id_value

	func list_fans() -> Array[String]:
		return ["mock-fan-0"]

	func get_bios_curve(_fan_id: String) -> Dictionary:
		return bios_curve

	func get_current_mode() -> String:
		return current_mode_value

	func requires_software_polling() -> bool:
		return polling_required

	func set_mode(mode: String) -> bool:
		if fail_next_set_mode:
			fail_next_set_mode = false
			return false
		mode_calls.append(mode)
		return true

	func apply_custom_curve(_fan_id: String, curve: Dictionary) -> bool:
		applied_curves.append(curve.duplicate(true))
		return true

	func read_temperature(_fan_id: String) -> float:
		return 50.0


var store: FanCurveStore
var backend: MockBackend
var registry: FanBackendRegistry
var manager: FanModeManager

var _test_hardware_id := "gut-fanmode-test"


func before_each() -> void:
	store = FanCurveStore.new()
	backend = MockBackend.new()
	backend.hardware_id_value = _test_hardware_id

	registry = FanBackendRegistry.new()
	registry.register(backend)

	manager = FanModeManager.new(registry, store)
	add_child_autoqfree(manager)
	await wait_frames(1, "let FanModeManager._ready() run")


func after_each() -> void:
	var path := store._path_for(_test_hardware_id)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


func test_startup_adopts_current_hardware_mode_without_writing_anything() -> void:
	# Genuinely first run (no store file yet, see before_each/after_each):
	# must NOT write pwm1_enable at all: just read and reflect whatever
	# the hardware already had. MockBackend.get_current_mode() defaults
	# to "" (unknown), which falls back to the "bios" label only.
	assert_eq(manager.current_mode, "bios")
	assert_true(backend.mode_calls.is_empty(), "must not call backend.set_mode() on first run")

	var data := store.load_data(_test_hardware_id)
	assert_eq(data["active_mode"], "bios", "the adopted mode is still persisted to our own store")


func test_startup_adopts_whatever_mode_the_hardware_reports() -> void:
	# Same scenario, but the hardware happens to already be in "custom"
	# when the plugin runs for the very first time.
	var custom_backend := MockBackend.new()
	custom_backend.hardware_id_value = "gut-fanmode-adopt-custom"
	custom_backend.current_mode_value = "custom"
	custom_backend.bios_curve = {10: 1.0, 20: 2.0, 30: 3.0, 40: 4.0, 50: 5.0, 60: 6.0, 70: 7.0, 80: 8.0, 90: 9.0, 100: 10.0}

	var custom_registry := FanBackendRegistry.new()
	custom_registry.register(custom_backend)
	var custom_manager := FanModeManager.new(custom_registry, store)
	add_child_autoqfree(custom_manager)
	await wait_frames(1, "let the adopt-custom FanModeManager._ready() run")

	assert_eq(custom_manager.current_mode, "custom")
	assert_true(custom_backend.mode_calls.is_empty(), "must not call backend.set_mode() while adopting")
	# Reads back whatever curve is already active rather than creating
	# the "Default" profile (that would overwrite it).
	assert_eq(custom_manager.get_curve_engine("mock-fan-0").get_curve(), custom_backend.bios_curve)

	var path := store._path_for("gut-fanmode-adopt-custom")
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


func test_set_mode_switches_and_persists() -> void:
	assert_true(manager.set_mode("custom"))
	assert_eq(manager.current_mode, "custom")

	var data := store.load_data(_test_hardware_id)
	assert_eq(data["active_mode"], "custom")


func test_switching_from_custom_to_bios_stops_the_curve_engine() -> void:
	manager.set_mode("custom")
	var engine := manager.get_curve_engine("mock-fan-0")
	assert_false(engine._poll_timer.is_stopped(), "engine should be polling in custom mode")

	manager.set_mode("bios")
	assert_true(engine._poll_timer.is_stopped(), "engine must stop when leaving custom mode")


func test_unknown_mode_is_rejected() -> void:
	assert_false(manager.set_mode("turbo"))


func test_reopening_reapplies_last_saved_mode() -> void:
	manager.set_mode("custom")

	# Simulate the plugin reloading: fresh backend/registry/manager
	# instances, but the same persisted store + hardware_id.
	var backend2 := MockBackend.new()
	backend2.hardware_id_value = _test_hardware_id
	var registry2 := FanBackendRegistry.new()
	registry2.register(backend2)
	var manager2 := FanModeManager.new(registry2, store)
	add_child_autoqfree(manager2)
	await wait_frames(1, "let the second FanModeManager._ready() run")

	assert_eq(manager2.current_mode, "custom")
	assert_true(backend2.mode_calls.has("custom"))


func test_failed_backend_switch_still_changes_current_mode_optimistically() -> void:
	# set_mode() queues the backend write and returns before it runs, so
	# a failing write no longer blocks the switch or reverts
	# current_mode -- only the write itself is best-effort/logged.
	manager.set_mode("custom")
	backend.fail_next_set_mode = true

	assert_true(manager.set_mode("bios"))
	assert_eq(manager.current_mode, "bios")


func test_custom_mode_creates_default_profile_when_none_saved() -> void:
	manager.set_mode("custom")

	assert_eq(manager.get_curve_engine("mock-fan-0").get_curve(), FanCurveUtils.DEFAULT_BALANCED_CURVE)

	var data := store.load_data(_test_hardware_id)
	assert_true(data["profiles"].has(FanCurveUtils.DEFAULT_PROFILE_NAME))
	assert_eq(data["active_profile"], FanCurveUtils.DEFAULT_PROFILE_NAME)
	assert_eq(
		data["profiles"][FanCurveUtils.DEFAULT_PROFILE_NAME]["mock-fan-0"],
		FanCurveUtils.DEFAULT_BALANCED_CURVE,
		"a profile bundles one curve per fan_id (tasks/14), even with a single fan"
	)


func test_custom_mode_reuses_existing_default_profile_instead_of_recreating_it() -> void:
	var custom_default := {10: 1.0, 20: 2.0, 30: 3.0, 40: 4.0, 50: 5.0, 60: 6.0, 70: 7.0, 80: 8.0, 90: 9.0, 100: 10.0}
	store.save_profile(
		_test_hardware_id, FanCurveUtils.DEFAULT_PROFILE_NAME, {"mock-fan-0": custom_default}
	)

	manager.set_mode("custom")

	# Must reuse the existing "Default" as-is, not overwrite it with
	# FanCurveUtils.DEFAULT_BALANCED_CURVE.
	assert_eq(manager.get_curve_engine("mock-fan-0").get_curve(), custom_default)


func test_custom_mode_loads_active_profile_when_one_is_saved() -> void:
	var profile_curve := {10: 5.0, 20: 15.0, 100: 90.0}
	store.save_profile(_test_hardware_id, "Perfil", {"mock-fan-0": profile_curve})
	var data := store.load_data(_test_hardware_id)
	data["active_profile"] = "Perfil"
	store.save(_test_hardware_id, data)

	manager.set_mode("custom")

	assert_eq(manager.get_curve_engine("mock-fan-0").get_curve(), profile_curve)


func test_custom_mode_preserves_in_memory_edits_across_mode_switches() -> void:
	manager.set_mode("custom")
	manager.get_curve_engine("mock-fan-0").set_point(30, 77.0)

	manager.set_mode("bios")
	manager.set_mode("custom")

	assert_eq(
		manager.get_curve_engine("mock-fan-0").get_curve()[30],
		77.0,
		"unsaved edit must survive a round trip through another mode"
	)


func test_custom_mode_attaches_engine_but_skips_polling_when_backend_needs_none() -> void:
	backend.polling_required = false

	manager.set_mode("custom")
	var engine := manager.get_curve_engine("mock-fan-0")

	# The engine still attaches and applies the curve once (it stays the
	# source of truth the UI editor reads/writes through): only the
	# steady-state re-poll timer is skipped.
	assert_true(
		engine._poll_timer.is_stopped(),
		"engine must not poll when the backend applies the curve natively"
	)
	assert_eq(engine.get_curve(), FanCurveUtils.DEFAULT_BALANCED_CURVE)
	assert_eq(backend.applied_curves.size(), 1)
	assert_eq(backend.applied_curves[0], FanCurveUtils.DEFAULT_BALANCED_CURVE)


func test_custom_mode_uses_curve_engine_when_backend_needs_polling() -> void:
	backend.polling_required = true

	manager.set_mode("custom")

	assert_false(
		manager.get_curve_engine("mock-fan-0")._poll_timer.is_stopped(),
		"engine must poll when the backend requires software polling"
	)


func test_get_all_curve_engines_returns_one_engine_per_fan() -> void:
	manager.set_mode("custom")

	var engines := manager.get_all_curve_engines()
	assert_eq(engines.size(), 1)
	assert_true(engines.has("mock-fan-0"))
