extends VBoxContainer
class_name ModeSelectOverlay

# bios/custom mode card shown in the quick bar. just reflects/drives
# FanModeManager, no mode-switching logic actually lives here.
#
# plain VBoxContainer root on purpose - gets added to a QuickBarCard's
# ContentContainer via Plugin.add_to_quick_bar(), which lays out children
# by min size not anchors. no scroll container either, the quick bar's own
# viewport already scrolls the whole card list.

const FanModeManager = preload("res://plugins/fan-manager/core/modes/fan_mode_manager.gd")
const GameCurveManager = preload("res://plugins/fan-manager/core/modes/game_curve_manager.gd")
const CurveSessionState = preload("res://plugins/fan-manager/core/modes/curve_session_state.gd")
const CustomCurveEditor = preload("res://plugins/fan-manager/core/ui/components/custom_curve_editor.gd")
const FanTabButton = preload("res://plugins/fan-manager/core/ui/components/fan_tab_button.gd")

const CURVE_EDITOR_SCENE := preload("res://plugins/fan-manager/core/ui/components/custom_curve_editor.tscn")
const FAN_TAB_SCENE := preload("res://plugins/fan-manager/core/ui/components/fan_tab_button.tscn")

# mode_id -> label shown in the dropdown, same order they get added in
# _populate_mode_dropdown()
const MODE_LABELS := {
	"bios": "BIOS Mode",
	"custom": "Custom Mode",
}

var mode_manager: FanModeManager

var logger := Log.get_logger("FanManager ModeSelectOverlay")

@onready var mode_dropdown := $%ModeDropdown as Dropdown
@onready var no_backend_label := $%NoBackendLabel as Label
@onready var custom_editor_slot := $%CustomEditorSlot as Control
@onready var fan_tabs_bar := $%FanTabsBar as HBoxContainer
@onready var editors_container := $%EditorsContainer as Control
@onready var dirty_badge := $%DirtyBadge as PanelContainer
@onready var per_game_toggle := $%PerGameToggle as Toggle
@onready var apply_button := $%ApplyButton as CardButton

var game_curve_manager: GameCurveManager

# fan_id -> CustomCurveEditor / FanTabButton, built the first time custom
# mode shows up. one editor per fan always, tabs only when there's more
# than one.
var _fan_editors: Dictionary = {}
var _fan_tab_buttons: Dictionary = {}
var _fans_built := false

var _mode_ids: Array[String] = []


func _ready() -> void:
	if not mode_manager or not mode_manager.backend:
		logger.warn("No FanModeManager/backend available; showing empty state")
		mode_dropdown.visible = false
		per_game_toggle.visible = false
		apply_button.visible = false
		no_backend_label.visible = true
		return

	no_backend_label.visible = false
	mode_manager.fan_mode_changed.connect(_on_fan_mode_changed)

	_populate_mode_dropdown()
	mode_dropdown.item_selected.connect(_on_mode_selected)
	apply_button.pressed.connect(_on_apply_pressed)

	_select_dropdown_for_mode(mode_manager.current_mode)
	_fix_dropdown_focus_neighbor()


# Dropdown copies our focus_neighbor_bottom onto its internal OptionButton
# as a raw path string, one level too shallow since option_button sits
# deeper than us. recompute it properly. also pin focus_neighbor_top to
# itself, since it's the topmost focusable in the card and the default
# (unset) lets Godot search outside the card for a neighbor above it,
# which can end up closing the quick bar unexpectedly.
func _fix_dropdown_focus_neighbor() -> void:
	var option_button := mode_dropdown.option_button
	var neighbor_path = option_button.get_path_to(per_game_toggle)
	option_button.focus_neighbor_bottom = neighbor_path
	option_button.focus_neighbor_top = option_button.get_path()


func _populate_mode_dropdown() -> void:
	mode_dropdown.clear()
	_mode_ids.clear()
	for mode_id in MODE_LABELS:
		mode_dropdown.add_item(MODE_LABELS[mode_id])
		_mode_ids.append(mode_id)


func _on_mode_selected(index: int) -> void:
	if index < 0 or index >= _mode_ids.size():
		logger.debug("_on_mode_selected(%d): index out of range (%d ids)" % [index, _mode_ids.size()])
		return

	var mode_id := _mode_ids[index]
	if mode_id == mode_manager.current_mode:
		logger.debug("_on_mode_selected(%d): '%s' already active, ignoring" % [index, mode_id])
		return

	logger.debug("_on_mode_selected(%d): switching to '%s'" % [index, mode_id])
	var switched_ok = mode_manager.set_mode(mode_id, true)
	if not switched_ok:
		logger.debug("_on_mode_selected(%d): switch to '%s' failed, reverting dropdown" % [index, mode_id])
		_select_dropdown_for_mode(mode_manager.current_mode)
		return

	_select_dropdown_for_mode(mode_id)

	# set_mode(mode_id, true) already made GameCurveManager commit/save on
	# its own (it listens for user_initiated mode switches), this flush
	# just makes sure that gets written to disk
	mode_manager.store.flush()


func _on_fan_mode_changed(mode: String, _user_initiated: bool) -> void:
	_select_dropdown_for_mode(mode)


func _on_curve_session_state_changed(state: CurveSessionState.State, _context_key: String) -> void:
	dirty_badge.visible = state == CurveSessionState.State.DIRTY


# called by plugin.gd once GameCurveManager exists
func bind_game_curve_manager(manager: GameCurveManager) -> void:
	game_curve_manager = manager
	per_game_toggle.button_pressed = manager.per_game_enabled
	per_game_toggle.toggled.connect(_on_per_game_toggled)
	manager.curve_applied.connect(_on_curve_applied)
	manager.curve_session.state_changed.connect(_on_curve_session_state_changed)


func _on_per_game_toggled(pressed: bool) -> void:
	if game_curve_manager:
		game_curve_manager.per_game_enabled = pressed


# CustomCurveEngine.load_curve() doesn't emit curve_changed, so the sliders
# wouldn't otherwise notice a per-context curve switch. re-binding forces
# each editor to re-pull and redraw.
func _on_curve_applied() -> void:
	if mode_manager.current_mode != "custom":
		return
	_resync_fan_editors()


func _resync_fan_editors() -> void:
	var engines := mode_manager.get_all_curve_engines()
	for fan_id in _fan_editors:
		if engines.has(fan_id):
			(_fan_editors[fan_id] as CustomCurveEditor).bind_engine(engines[fan_id])


# pushes the sliders' current curve to hardware+disk. apply button never
# goes through set_mode() so we have to poke curve_session directly here
func _on_apply_pressed() -> void:
	logger.debug("_on_apply_pressed(): committing (reason: user pressed Apply)")
	if game_curve_manager:
		game_curve_manager.curve_session.apply_pressed()
	mode_manager.store.flush()


func _select_dropdown_for_mode(mode: String) -> void:
	var idx := _mode_ids.find(mode)
	if idx != -1:
		mode_dropdown.selected = idx
	custom_editor_slot.visible = mode == "custom"
	apply_button.visible = mode == "custom"

	if mode != "custom":
		dirty_badge.visible = false
		return

	_ensure_fan_editors()
	_resync_fan_editors()

	# runs every time custom mode turns on, idempotent, just cheap
	# insurance against the apply button's focus neighbor going stale
	if not _fan_editors.is_empty():
		var first_fan_id = _fan_editors.keys()[0]
		_wire_focus_into_curve_editor.call_deferred(first_fan_id)


func _ensure_fan_editors() -> void:
	if _fans_built:
		return
	_fans_built = true

	var fans := mode_manager.backend.list_fans()
	fan_tabs_bar.visible = fans.size() > 1

	for fan_id in fans:
		var editor := CURVE_EDITOR_SCENE.instantiate() as CustomCurveEditor
		editor.set_anchors_preset(Control.PRESET_FULL_RECT)
		editor.visible = false
		editors_container.add_child(editor)
		_fan_editors[fan_id] = editor

		if fans.size() > 1:
			var tab := FAN_TAB_SCENE.instantiate() as FanTabButton
			tab.fan_id = fan_id
			var label = mode_manager.backend.get_fan_label(fan_id)
			tab.label_text = label
			tab.focus_entered.connect(_on_fan_tab_focused.bind(fan_id))
			fan_tabs_bar.add_child(tab)
			_fan_tab_buttons[fan_id] = tab

	if not fans.is_empty():
		_select_fan_tab(fans[0])


# bridges focus from the apply button down into the curve editor area,
# safe to call repeatedly/deferred
func _wire_focus_into_curve_editor(first_fan_id: String) -> void:
	var entry_point: Control
	if _fan_tab_buttons.has(first_fan_id):
		entry_point = _fan_tab_buttons[first_fan_id]
	else:
		var editor = _fan_editors[first_fan_id] as CustomCurveEditor
		entry_point = editor.get_first_row()

	if not entry_point:
		return

	apply_button.focus_neighbor_bottom = apply_button.get_path_to(entry_point)
	entry_point.focus_neighbor_top = entry_point.get_path_to(apply_button)
	logger.info(
		"Wired ApplyButton <-> %s (focus_neighbor_bottom=%s)"
		% [entry_point.name, apply_button.focus_neighbor_bottom]
	)


func _wire_tab_to_selected_editor(selected_fan_id: String) -> void:
	if not _fan_tab_buttons.has(selected_fan_id):
		return

	var selected_editor = _fan_editors[selected_fan_id] as CustomCurveEditor
	var first_row := selected_editor.get_first_row()
	if not first_row:
		return

	for id in _fan_tab_buttons:
		var tab := _fan_tab_buttons[id] as FanTabButton
		tab.focus_neighbor_bottom = tab.get_path_to(first_row)

	var selected_tab := _fan_tab_buttons[selected_fan_id] as FanTabButton
	first_row.focus_neighbor_top = first_row.get_path_to(selected_tab)


func _on_fan_tab_focused(fan_id: String) -> void:
	_select_fan_tab(fan_id)


func _select_fan_tab(fan_id: String) -> void:
	for id in _fan_editors:
		(_fan_editors[id] as CustomCurveEditor).visible = id == fan_id
	for id in _fan_tab_buttons:
		(_fan_tab_buttons[id] as FanTabButton).selected = id == fan_id

	_wire_tab_to_selected_editor(fan_id)
