extends VBoxContainer
class_name ProfileManagerPanel

## Profile picker + save button shown above the fan curve editor in
## Custom Mode (tasks/15-picker-de-perfil-e-save-no-editor.md,
## superseding the old always-expanded profile list from
## tasks/08-ui-perfis-salvar-carregar.md). A single Trigger button
## shows the active profile (or a pending "New profile" placeholder);
## pressing it opens a dropdown to switch/delete profiles or start a
## new one. Save always targets whichever profile is currently active
## with no extra confirmation; a name is only asked for when there is
## no active profile yet (the "New profile" pending state).
##
## FanCurveStore/ProfileTriggerButton/ProfileRow below are referenced
## via preload()'d consts, not bare class_name lookups (see
## hwmon_fan_backend.gd's header comment /
## tasks/17-fix-class-name-resolution-em-plugin-empacotado.md).
const FanCurveStore = preload("res://plugins/fan-manager/core/persistence/fan_curve_store.gd")
const ProfileTriggerButton = preload("res://plugins/fan-manager/core/ui/components/profile_trigger_button.gd")
const ProfileRow = preload("res://plugins/fan-manager/core/ui/components/profile_row.gd")
const FanCurveUtils = preload("res://plugins/fan-manager/core/persistence/fan_curve_utils.gd")

signal dirty_changed(is_dirty: bool)

## Fires whenever the active profile marker changes for any reason:
## selecting a profile, saving/overwriting one, deleting the active
## one, or picking "New profile" (name == "" in the last two cases).
## Used by GameCurveManager (tasks/12-fancurve-por-jogo.md) to know
## when to snapshot the full per-game state; harmless to ignore
## otherwise.
signal active_profile_changed(profile_name: String)

const ROW_SCENE := preload("res://plugins/fan-manager/core/ui/components/profile_row.tscn")

var logger := Log.get_logger("ProfileManagerPanel")

var store: FanCurveStore
var hardware_id: String = ""

## fan_id -> CustomCurveEngine. A saved profile bundles one curve per
## fan (tasks/14-suporte-multiplas-fans.md): save/apply/dirty-tracking
## all iterate every engine here, never just one.
var curve_engines: Dictionary = {}

@onready var trigger := $%Trigger as ProfileTriggerButton
@onready var save_button := $%SaveButton as Button
@onready var dropdown := $%Dropdown as Control
@onready var profile_list := $%ProfileList as VBoxContainer
@onready var empty_label := $%EmptyLabel as Label
@onready var new_profile_button := $%NewProfileButton as Button
@onready var new_name_form := $%NewNameForm as Control
@onready var name_input := $%NameInput as LineEdit
@onready var new_name_confirm := $%NewNameConfirm as Button
@onready var new_name_cancel := $%NewNameCancel as Button
@onready var overwrite_box := $%OverwriteBox as Control
@onready var overwrite_label := $%OverwriteLabel as Label
@onready var overwrite_confirm_button := $%OverwriteConfirmButton as Button
@onready var overwrite_cancel_button := $%OverwriteCancelButton as Button

var _rows: Array[ProfileRow] = []
var _active_profile: String = ""
var _pending_save_name: String = ""
var _dirty := false


func _ready() -> void:
	trigger.pressed.connect(_toggle_dropdown)
	save_button.pressed.connect(_on_save_pressed)
	new_profile_button.pressed.connect(_on_new_profile_pressed)
	new_name_confirm.pressed.connect(_try_save)
	new_name_cancel.pressed.connect(_close_new_name_form)
	name_input.text_submitted.connect(func(_text): _try_save())
	overwrite_confirm_button.pressed.connect(_confirm_overwrite)
	overwrite_cancel_button.pressed.connect(_close_overwrite_box)

	_close_dropdown()
	_close_new_name_form()
	_close_overwrite_box()


## Call whenever Custom Mode becomes active (or the hardware/engines
## change): reloads the profile list and active-profile marker from
## disk, and starts listening to every engine for dirty-state tracking.
func refresh(p_store: FanCurveStore, p_hardware_id: String, p_curve_engines: Dictionary) -> void:
	for engine in curve_engines.values():
		if engine.curve_changed.is_connected(_on_engine_curve_changed):
			engine.curve_changed.disconnect(_on_engine_curve_changed)

	store = p_store
	hardware_id = p_hardware_id
	curve_engines = p_curve_engines

	for engine in curve_engines.values():
		engine.curve_changed.connect(_on_engine_curve_changed)

	var data: Dictionary = store.load_data(hardware_id)
	var raw_active = data.get("active_profile")
	_active_profile = raw_active if raw_active != null else ""

	var profiles: Dictionary = data.get("profiles")
	if profiles == null:
		profiles = {}
	_rebuild_rows(profiles.keys())
	_update_trigger()
	_set_dirty(false)


func _rebuild_rows(names: Array) -> void:
	for row in _rows:
		row.queue_free()
	_rows.clear()

	names.sort()
	for profile_name in names:
		var row := ROW_SCENE.instantiate() as ProfileRow
		row.profile_name = profile_name
		row.active = profile_name == _active_profile
		row.selected.connect(apply_profile)
		row.delete_requested.connect(_on_row_delete_requested)
		profile_list.add_child(row)
		_rows.append(row)

	empty_label.visible = names.is_empty()


func _update_trigger() -> void:
	trigger.pending = _active_profile.is_empty()
	if not _active_profile.is_empty():
		trigger.profile_name = _active_profile


func _toggle_dropdown() -> void:
	if dropdown.visible:
		_close_dropdown()
	else:
		dropdown.visible = true
		trigger.open = true


func _close_dropdown() -> void:
	dropdown.visible = false
	trigger.open = false


## Loads the named profile into the working curve of every fan and
## marks it active. Public so GameCurveManager can reapply a saved
## profile (as part of restoring a per-game snapshot) without
## duplicating this logic.
func apply_profile(profile_name: String) -> void:
	var data: Dictionary = store.load_data(hardware_id)
	var profiles: Dictionary = data.get("profiles", {})
	if not profiles.has(profile_name):
		logger.warn("Profile '%s' no longer exists" % profile_name)
		return

	var profile_curves: Dictionary = profiles[profile_name]
	for fan_id in curve_engines:
		if profile_curves.has(fan_id):
			curve_engines[fan_id].load_curve(profile_curves[fan_id])

	logger.info("Applied profile '%s' for hardware '%s'" % [profile_name, hardware_id])

	_active_profile = profile_name
	_persist_active_profile(profile_name)
	for row in _rows:
		row.active = row.profile_name == profile_name
	_update_trigger()
	_close_dropdown()
	_set_dirty(false)
	active_profile_changed.emit(profile_name)


## Picking "New profile" doesn't ask for a name right away: it just
## marks the picker as pending (no profile currently active) and
## leaves the working curves alone, so the user keeps editing normally
## and only gets asked to name it when they click Save.
func _on_new_profile_pressed() -> void:
	_active_profile = ""
	for row in _rows:
		row.active = false
	_update_trigger()
	_close_dropdown()
	active_profile_changed.emit("")


func _on_row_delete_requested(profile_name: String) -> void:
	if not store.delete_profile(hardware_id, profile_name):
		return

	if _active_profile == profile_name:
		_active_profile = ""
		_update_trigger()
		active_profile_changed.emit("")

	var data: Dictionary = store.load_data(hardware_id)
	var profiles: Dictionary = data.get("profiles")
	if profiles == null:
		profiles = {}
	_rebuild_rows(profiles.keys())


func _on_engine_curve_changed(_curve: Dictionary) -> void:
	_set_dirty(true)


## Existing active profile: save straight to it, no prompt (the point
## of moving Save into the fan region is that it always targets
## whatever's currently picked). Pending "New profile": ask for a name
## first, since there's nothing to overwrite yet.
func _on_save_pressed() -> void:
	if not _active_profile.is_empty():
		_commit_save(_active_profile)
		return

	name_input.text = ""
	new_name_form.visible = true
	name_input.grab_focus.call_deferred()


func _close_new_name_form() -> void:
	new_name_form.visible = false


func _close_overwrite_box() -> void:
	overwrite_box.visible = false
	_pending_save_name = ""


func _try_save() -> void:
	var profile_name := name_input.text.strip_edges()
	if profile_name.is_empty():
		return

	var data: Dictionary = store.load_data(hardware_id)
	var profiles: Dictionary = data.get("profiles", {})

	if profiles.has(profile_name):
		_pending_save_name = profile_name
		overwrite_label.text = (
			'A profile named "%s" already exists. Overwrite it with the current curves?' % profile_name
		)
		overwrite_box.visible = true
		return

	_commit_save(profile_name)


func _confirm_overwrite() -> void:
	var profile_name := _pending_save_name
	_close_overwrite_box()
	_commit_save(profile_name)


func _commit_save(profile_name: String) -> void:
	if curve_engines.is_empty():
		logger.error("Cannot save profile '%s': no curve engines available" % profile_name)
		return

	var profile_curves: Dictionary = {}
	for fan_id in curve_engines:
		profile_curves[fan_id] = curve_engines[fan_id].get_curve()

	if not store.save_profile(hardware_id, profile_name, profile_curves):
		logger.error("Failed to save profile '%s'" % profile_name)
		return

	# Slider edits only ever touch the in-memory draft (see
	# CustomCurveEngine.set_point()): this is the one place that
	# actually pushes the edited curve to the hardware, for every fan
	# at once.
	for engine in curve_engines.values():
		engine.commit_draft()

	_active_profile = profile_name
	_persist_active_profile(profile_name)

	var data: Dictionary = store.load_data(hardware_id)
	var profiles: Dictionary = data.get("profiles")
	if profiles == null:
		profiles = {}
	_rebuild_rows(profiles.keys())
	_update_trigger()
	_close_dropdown()
	_close_new_name_form()
	_set_dirty(false)
	active_profile_changed.emit(profile_name)


## Commits every fan's draft curve to hardware and disk, straight to
## whichever profile is currently active (defaulting to "Default" if
## none is set, which shouldn't normally happen since FanModeManager
## always ensures one exists/is active before Custom Mode starts).
## Used by ModeSelectOverlay's standalone "Apply" button
## (core/ui/mode_select_overlay.gd/.tscn), which lets the user commit
## slider edits while this panel's own picker/save UI is hidden: same
## underlying save as _on_save_pressed(), but skips the naming/
## overwrite prompts entirely, since there's no "New profile" pending
## state reachable without the picker UI visible.
func apply_current() -> void:
	var profile_name := _active_profile
	if profile_name.is_empty():
		profile_name = FanCurveUtils.DEFAULT_PROFILE_NAME
	_commit_save(profile_name)


func _persist_active_profile(profile_name: String) -> void:
	var data: Dictionary = store.load_data(hardware_id)
	data["active_profile"] = profile_name
	store.save(hardware_id, data)


func _set_dirty(value: bool) -> void:
	if _dirty == value:
		return
	_dirty = value
	dirty_changed.emit(_dirty)
