extends VBoxContainer
class_name ProfileManagerPanel

## Profile picker + save button shown above the fan curve editor in
## Custom Mode. A single Trigger button shows the active profile (or a
## pending "New profile" placeholder); pressing it opens a dropdown to
## switch/delete profiles or start a new one. Save always targets
## whichever profile is currently active with no extra confirmation; a
## name is only asked for when there is no active profile yet.
##
## Referenced via preload()'d consts, not bare class_name lookups: see
## hwmon_fan_backend.gd's header comment for why.
const FanCurveStore = preload("res://plugins/fan-manager/core/persistence/fan_curve_store.gd")
const ProfileTriggerButton = preload("res://plugins/fan-manager/core/ui/components/profile_trigger_button.gd")
const ProfileRow = preload("res://plugins/fan-manager/core/ui/components/profile_row.gd")
const FanCurveUtils = preload("res://plugins/fan-manager/core/persistence/fan_curve_utils.gd")

## Fires whenever the active profile marker changes: selecting,
## saving/overwriting, deleting the active one, or picking "New
## profile" (profile_name == "" in the last two cases). Used by
## GameCurveManager to know when to snapshot per-game state.
signal active_profile_changed(profile_name: String)

const ROW_SCENE := preload("res://plugins/fan-manager/core/ui/components/profile_row.tscn")

var logger := Log.get_logger("FanManager ProfileManagerPanel")

var store: FanCurveStore
var hardware_id: String = ""

## fan_id -> CustomCurveEngine. A saved profile bundles one curve per
## fan: save/apply all iterate every engine here. Dirty-tracking used
## to live here too; it's now owned by GameCurveManager's
## CurveSessionState (tasks/18) instead.
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


## Wires all button/input signals and starts with dropdown/forms closed.
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
## change): reloads the profile list/active marker from disk.
func refresh(p_store: FanCurveStore, p_hardware_id: String, p_curve_engines: Dictionary) -> void:
	store = p_store
	hardware_id = p_hardware_id
	curve_engines = p_curve_engines

	var data: Dictionary = store.load_data(hardware_id)
	var raw_active = data.get("active_profile")
	_active_profile = raw_active if raw_active != null else ""

	var profiles: Dictionary = data.get("profiles")
	if profiles == null:
		profiles = {}
	_rebuild_rows(profiles.keys())
	_update_trigger()


## Rebuilds the dropdown's profile rows from names, marking the one
## matching _active_profile as active.
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


## Syncs the trigger button's pending/name state to _active_profile.
func _update_trigger() -> void:
	trigger.pending = _active_profile.is_empty()
	if not _active_profile.is_empty():
		trigger.profile_name = _active_profile


## Opens the dropdown if closed, closes it if open.
func _toggle_dropdown() -> void:
	if dropdown.visible:
		_close_dropdown()
	else:
		dropdown.visible = true
		trigger.open = true


func _close_dropdown() -> void:
	dropdown.visible = false
	trigger.open = false


## Loads profile_name into the working curve of every fan and marks it
## active. No-op (with a warning) if the profile no longer exists.
## Public so GameCurveManager can reapply a saved profile.
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
	active_profile_changed.emit(profile_name)


## Marks the picker pending (no active profile), leaving the working
## curves untouched; a name is only asked for at Save time.
func _on_new_profile_pressed() -> void:
	_active_profile = ""
	for row in _rows:
		row.active = false
	_update_trigger()
	_close_dropdown()
	active_profile_changed.emit("")


## Deletes profile_name from disk and the row list. Clears the active
## marker (and emits active_profile_changed) if it was the active one.
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


## With an active profile, saves straight to it (no prompt). With none
## active ("New profile" pending), opens the name form instead.
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


## Reads the name form's input; if it collides with an existing
## profile, shows the overwrite confirmation instead of saving
## directly.
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


## Confirms the pending overwrite from the confirmation box and saves.
func _confirm_overwrite() -> void:
	var profile_name := _pending_save_name
	_close_overwrite_box()
	_commit_save(profile_name)


## Saves every fan's current curve under profile_name (creating or
## overwriting), commits the drafts to hardware, marks it active, and
## refreshes the UI.
func _commit_save(profile_name: String) -> void:
	if curve_engines.is_empty():
		logger.error("Cannot save profile '%s': no curve engines available" % profile_name)
		return

	var profile_curves: Dictionary = {}
	for fan_id in curve_engines:
		profile_curves[fan_id] = curve_engines[fan_id].get_curve()

	var is_per_game_enabled: bool = store.get_per_game_enabled()
	if not is_per_game_enabled:
		if not store.save_profile(hardware_id, profile_name, profile_curves):
			logger.error("Failed to save profile '%s'" % profile_name)
			return

	# Slider edits only touch the in-memory draft; this pushes it to
	# hardware for every fan.
	for engine in curve_engines.values():
		engine.commit_draft()

	_active_profile = profile_name
	_persist_active_profile(profile_name)
	if not is_per_game_enabled:
		var data: Dictionary = store.load_data(hardware_id)
		var profiles: Dictionary = data.get("profiles")
		if profiles == null:
			profiles = {}
		_rebuild_rows(profiles.keys())
		_update_trigger()
		_close_dropdown()
		_close_new_name_form()
	# Emitted before flush() on purpose: GameCurveManager listens to
	# this and enqueues a per-game snapshot job in response (see
	# store.enqueue()'s doc comment) — flush() below is what actually
	# runs that job and writes everything to disk in one shot.
	active_profile_changed.emit(profile_name)
	store.flush()


## Commits every fan's draft curve to hardware and disk, straight to
## whichever profile is active (falling back to "Default"), skipping
## the naming/overwrite prompts. Used by ModeSelectOverlay's standalone
## "Apply" button, when this panel's own picker/save UI is hidden.
func apply_current() -> void:
	var profile_name := _active_profile
	if profile_name.is_empty():
		profile_name = FanCurveUtils.DEFAULT_PROFILE_NAME
	_commit_save(profile_name)


## Stages profile_name as the active profile. In-memory only — see
## _commit_save(), which is the only caller and flushes once at its
## own end.
func _persist_active_profile(profile_name: String) -> void:
	store.load_data(hardware_id)
	store.set_active_profile(profile_name)
