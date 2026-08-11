extends GutTest

class StubBackend extends FanBackend:
	var applied_curves: Array[Dictionary] = []

	func requires_software_polling() -> bool:
		return false

	func apply_custom_curve(_fan_id: String, curve: Dictionary) -> bool:
		applied_curves.append(curve.duplicate(true))
		return true


var store: FanCurveStore
var backend: StubBackend
var curve_engine: CustomCurveEngine
var curve_engines: Dictionary
var panel: ProfileManagerPanel

var _test_hardware_id := "gut-profilepanel-test"
var _fan_id := "fan-0"


func before_each() -> void:
	store = FanCurveStore.new()
	backend = StubBackend.new()
	curve_engine = CustomCurveEngine.new()
	curve_engine.start(backend, _fan_id, {10: 0, 20: 20, 30: 40})
	curve_engines = {_fan_id: curve_engine}

	panel = ProfileManagerPanel.new()
	add_child_autoqfree(panel)
	await wait_frames(1, "let ProfileManagerPanel._ready() run")

	panel.refresh(store, _test_hardware_id, curve_engines)


func after_each() -> void:
	var path := store._path_for(_test_hardware_id)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


func test_refresh_starts_with_no_profiles() -> void:
	assert_true(panel.empty_label.visible)
	assert_eq(panel._rows.size(), 0)


## With no profiles at all yet, the picker starts in the pending
## "New profile" state: there's nothing to be "active" until something
## is saved.
func test_trigger_starts_pending_when_no_profile_is_active() -> void:
	assert_true(panel.trigger.pending)


func test_saving_a_new_profile_adds_it_and_clears_dirty() -> void:
	panel.name_input.text = "Silencioso"
	panel._try_save()

	assert_eq(panel._rows.size(), 1)
	assert_eq(panel._rows[0].profile_name, "Silencioso")
	assert_true(panel._rows[0].active)
	assert_false(panel._dirty)
	assert_false(panel.trigger.pending)
	assert_eq(panel.trigger.profile_name, "Silencioso")

	var data := store.load(_test_hardware_id)
	# JSON round-trip turns keys back into Strings: normalize before
	# comparing against the engine's int-keyed in-memory curve. A saved
	# profile bundles one curve per fan_id (tasks/14).
	assert_eq(
		FanCurveUtils.normalize_keys(data["profiles"]["Silencioso"][_fan_id]),
		curve_engine.get_curve()
	)
	assert_eq(data["active_profile"], "Silencioso")


func test_saving_with_existing_name_shows_overwrite_confirmation_instead_of_saving() -> void:
	store.save_profile(_test_hardware_id, "Existente", {_fan_id: {10: 1}})
	panel.refresh(store, _test_hardware_id, curve_engines)

	panel.name_input.text = "Existente"
	panel._try_save()

	assert_true(panel.overwrite_box.visible)
	# Must not have overwritten yet: original value untouched.
	var data := store.load(_test_hardware_id)
	assert_eq(data["profiles"]["Existente"], {_fan_id: {"10": 1}})


func test_confirming_overwrite_replaces_profile_without_duplicating() -> void:
	store.save_profile(_test_hardware_id, "Existente", {_fan_id: {10: 1}})
	panel.refresh(store, _test_hardware_id, curve_engines)

	panel.name_input.text = "Existente"
	panel._try_save()
	panel._confirm_overwrite()

	assert_eq(panel._rows.size(), 1, "overwriting must not create a duplicate entry")
	var data := store.load(_test_hardware_id)
	assert_eq(
		FanCurveUtils.normalize_keys(data["profiles"]["Existente"][_fan_id]),
		curve_engine.get_curve()
	)
	assert_false(panel.overwrite_box.visible)


func test_selecting_a_profile_loads_it_into_the_engine() -> void:
	store.save_profile(_test_hardware_id, "Perfil", {_fan_id: {10: 7, 20: 8, 30: 9}})
	panel.refresh(store, _test_hardware_id, curve_engines)

	panel.apply_profile("Perfil")

	assert_eq(curve_engine.get_curve(), {10: 7.0, 20: 8.0, 30: 9.0})
	assert_false(panel._dirty)
	assert_true(panel._rows[0].active)
	assert_eq(panel.trigger.profile_name, "Perfil")


func test_selecting_a_profile_closes_the_dropdown() -> void:
	store.save_profile(_test_hardware_id, "Perfil", {_fan_id: {10: 7}})
	panel.refresh(store, _test_hardware_id, curve_engines)

	panel._toggle_dropdown()
	assert_true(panel.dropdown.visible)

	panel.apply_profile("Perfil")

	assert_false(panel.dropdown.visible)


func test_deleting_active_profile_keeps_curve_but_clears_active_marker() -> void:
	store.save_profile(_test_hardware_id, "Perfil", {_fan_id: {10: 1}})
	panel.refresh(store, _test_hardware_id, curve_engines)
	panel.apply_profile("Perfil")

	panel._on_row_delete_requested("Perfil")

	assert_eq(panel._rows.size(), 0)
	assert_true(panel.trigger.pending, "picker must fall back to pending once its active profile is gone")
	var data := store.load(_test_hardware_id)
	assert_eq(data.get("active_profile"), null)
	# The working curve itself is untouched by deleting its saved name.
	assert_true(curve_engine.get_curve().has(10))


func test_deleting_an_inactive_profile_does_not_touch_the_active_one() -> void:
	store.save_profile(_test_hardware_id, "Ativo", {_fan_id: {10: 1}})
	store.save_profile(_test_hardware_id, "Outro", {_fan_id: {10: 2}})
	panel.refresh(store, _test_hardware_id, curve_engines)
	panel.apply_profile("Ativo")

	panel._on_row_delete_requested("Outro")

	assert_eq(panel._rows.size(), 1)
	assert_eq(panel._rows[0].profile_name, "Ativo")
	assert_true(panel._rows[0].active)
	assert_false(panel.trigger.pending)


func test_editing_curve_marks_dirty_and_emits_signal() -> void:
	watch_signals(panel)
	curve_engine.set_point(10, 55.0)

	assert_true(panel._dirty)
	assert_signal_emitted(panel, "dirty_changed")


func test_selecting_a_profile_after_editing_clears_dirty() -> void:
	store.save_profile(_test_hardware_id, "Perfil", {_fan_id: {10: 7, 20: 8, 30: 9}})
	panel.refresh(store, _test_hardware_id, curve_engines)

	curve_engine.set_point(10, 55.0)
	assert_true(panel._dirty)

	panel.apply_profile("Perfil")
	assert_false(panel._dirty)


func test_applying_a_profile_emits_active_profile_changed() -> void:
	store.save_profile(_test_hardware_id, "Perfil", {_fan_id: {10: 1}})
	panel.refresh(store, _test_hardware_id, curve_engines)

	watch_signals(panel)
	panel.apply_profile("Perfil")

	assert_signal_emitted_with_parameters(panel, "active_profile_changed", ["Perfil"])


func test_saving_a_profile_emits_active_profile_changed() -> void:
	watch_signals(panel)
	panel.name_input.text = "Novo"
	panel._try_save()

	assert_signal_emitted_with_parameters(panel, "active_profile_changed", ["Novo"])


func test_deleting_the_active_profile_emits_active_profile_changed_with_empty_name() -> void:
	store.save_profile(_test_hardware_id, "Perfil", {_fan_id: {10: 1}})
	panel.refresh(store, _test_hardware_id, curve_engines)
	panel.apply_profile("Perfil")

	watch_signals(panel)
	panel._on_row_delete_requested("Perfil")

	assert_signal_emitted_with_parameters(panel, "active_profile_changed", [""])


func test_saving_a_profile_commits_the_draft_to_hardware() -> void:
	# Slider edits alone (set_point) never reach the backend: saving
	# is the one action that actually applies the edited curve.
	curve_engine.set_point(10, 66.0)
	backend.applied_curves.clear()

	panel.name_input.text = "Novo"
	panel._try_save()

	assert_eq(backend.applied_curves.size(), 1)
	assert_eq(backend.applied_curves[0][10], 66.0)


func test_deleting_an_inactive_profile_does_not_emit_active_profile_changed() -> void:
	store.save_profile(_test_hardware_id, "Ativo", {_fan_id: {10: 1}})
	store.save_profile(_test_hardware_id, "Outro", {_fan_id: {10: 2}})
	panel.refresh(store, _test_hardware_id, curve_engines)
	panel.apply_profile("Ativo")

	watch_signals(panel)
	panel._on_row_delete_requested("Outro")

	assert_signal_not_emitted(panel, "active_profile_changed")


func test_saving_bundles_curves_from_every_fan_engine() -> void:
	var backend2 := StubBackend.new()
	var engine2 := CustomCurveEngine.new()
	engine2.start(backend2, "fan-1", {10: 1, 20: 2, 30: 3})
	curve_engines["fan-1"] = engine2
	panel.refresh(store, _test_hardware_id, curve_engines)

	panel.name_input.text = "Duas Fans"
	panel._try_save()

	var data := store.load(_test_hardware_id)
	var saved: Dictionary = data["profiles"]["Duas Fans"]
	assert_true(saved.has(_fan_id))
	assert_true(saved.has("fan-1"))
	assert_eq(FanCurveUtils.normalize_keys(saved["fan-1"]), engine2.get_curve())


## Once a profile is active, pressing Save must commit straight to it:
## no name form, no confirmation, matching the "Save always targets
## the current profile" behavior the picker was redesigned around.
func test_save_button_commits_directly_when_a_profile_is_already_active() -> void:
	store.save_profile(_test_hardware_id, "Perfil", {_fan_id: {10: 1, 20: 2, 30: 3}})
	panel.refresh(store, _test_hardware_id, curve_engines)
	panel.apply_profile("Perfil")

	curve_engine.set_point(10, 42.0)
	backend.applied_curves.clear()

	panel._on_save_pressed()

	assert_false(panel.new_name_form.visible, "an already-active profile must not prompt for a name")
	assert_eq(backend.applied_curves.size(), 1)
	assert_eq(backend.applied_curves[0][10], 42.0)
	var data := store.load(_test_hardware_id)
	assert_eq(
		FanCurveUtils.normalize_keys(data["profiles"]["Perfil"][_fan_id])[10],
		42.0
	)


## With no active profile (a genuinely new curve, never saved), Save
## must ask for a name instead of silently failing or guessing one.
func test_save_button_opens_name_form_when_no_profile_is_active() -> void:
	assert_true(panel.trigger.pending)

	panel._on_save_pressed()

	assert_true(panel.new_name_form.visible)


## Picking "New profile" from the dropdown doesn't touch the curve or
## ask for a name immediately: it only marks the picker pending so the
## user can keep editing and gets asked for a name at Save time.
func test_picking_new_profile_marks_picker_pending_without_prompting() -> void:
	store.save_profile(_test_hardware_id, "Perfil", {_fan_id: {10: 1}})
	panel.refresh(store, _test_hardware_id, curve_engines)
	panel.apply_profile("Perfil")

	watch_signals(panel)
	panel._on_new_profile_pressed()

	assert_true(panel.trigger.pending)
	assert_false(panel.new_name_form.visible)
	assert_eq(curve_engine.get_curve()[10], 1.0, "curve must be left untouched by picking New profile")
	assert_signal_emitted_with_parameters(panel, "active_profile_changed", [""])


func test_picking_new_profile_closes_the_dropdown() -> void:
	panel._toggle_dropdown()
	assert_true(panel.dropdown.visible)

	panel._on_new_profile_pressed()

	assert_false(panel.dropdown.visible)


func test_new_profile_button_is_wired_to_the_picker() -> void:
	store.save_profile(_test_hardware_id, "Perfil", {_fan_id: {10: 1}})
	panel.refresh(store, _test_hardware_id, curve_engines)
	panel.apply_profile("Perfil")

	panel.new_profile_button.pressed.emit()

	assert_true(panel.trigger.pending)


func test_toggle_dropdown_flips_visibility_and_trigger_open_state() -> void:
	assert_false(panel.dropdown.visible)
	assert_false(panel.trigger.open)

	panel._toggle_dropdown()
	assert_true(panel.dropdown.visible)
	assert_true(panel.trigger.open)

	panel._toggle_dropdown()
	assert_false(panel.dropdown.visible)
	assert_false(panel.trigger.open)
