extends VBoxContainer
class_name ModeSelectOverlay

## BIOS/Custom Mode select card shown in OGUI's Quick Bar menu.
## Reflects and drives FanModeManager: no mode-switching logic lives
## here, only UI state.
##
## Plain VBoxContainer root (not OverlayProvider) on purpose: this is
## added to a QuickBarCard's ContentContainer (also a VBoxContainer)
## via Plugin.add_to_quick_bar(), which lays out children by their
## reported minimum size, not by anchors. No internal ScrollContainer
## either: every child sits flat, one below the other. The Quick Bar's
## own outer viewport already scrolls the whole card list.
##
## FanModeManager/GameCurveManager/CustomCurveEditor/FanTabButton below
## are referenced via preload()'d consts, not bare class_name lookups:
## see hwmon_fan_backend.gd's header comment for why. Dropdown/Toggle
## are OGUI's own core classes (compiled into the base game), so they
## resolve fine as bare names, same as FocusGroup/Label.
const FanModeManager = preload("res://plugins/fan-manager/core/modes/fan_mode_manager.gd")
const GameCurveManager = preload("res://plugins/fan-manager/core/modes/game_curve_manager.gd")
const CurveSessionState = preload("res://plugins/fan-manager/core/modes/curve_session_state.gd")
const CustomCurveEditor = preload("res://plugins/fan-manager/core/ui/components/custom_curve_editor.gd")
const FanTabButton = preload("res://plugins/fan-manager/core/ui/components/fan_tab_button.gd")

const CURVE_EDITOR_SCENE := preload("res://plugins/fan-manager/core/ui/components/custom_curve_editor.tscn")
const FAN_TAB_SCENE := preload("res://plugins/fan-manager/core/ui/components/fan_tab_button.tscn")

## mode_id -> label shown in the dropdown and in the switch-failure
## error message. Order here is also the order items are added to the
## dropdown in _populate_mode_dropdown().
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

## fan_id -> CustomCurveEditor / FanTabButton, built once the first
## time Custom Mode is shown (tasks/14-suporte-multiplas-fans.md). One
## editor per fan, always instantiated; tabs only shown/used when there
## is more than one fan.
var _fan_editors: Dictionary = {}
var _fan_tab_buttons: Dictionary = {}
var _fans_built := false

## dropdown item index -> mode_id, in MODE_LABELS order. Rebuilt by
## _populate_mode_dropdown().
var _mode_ids: Array[String] = []


## Shows the empty state if no backend is available, otherwise wires
## the mode dropdown/toggle/apply signals and selects the current mode.
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


## Dropdown redirects focus to its internal OptionButton, whose own
## _ready() copies our focus_neighbor_bottom onto it verbatim as a raw
## path string, one level too shallow, since option_button sits one
## level deeper than ModeDropdown. Recomputes it correctly via
## get_path_to().
func _fix_dropdown_focus_neighbor() -> void:
	var option_button := mode_dropdown.option_button
	option_button.focus_neighbor_bottom = option_button.get_path_to(per_game_toggle)


## Builds the dropdown items in MODE_LABELS order.
func _populate_mode_dropdown() -> void:
	mode_dropdown.clear()
	_mode_ids.clear()
	for mode_id in MODE_LABELS:
		mode_dropdown.add_item(MODE_LABELS[mode_id])
		_mode_ids.append(mode_id)


## Signal handler for Dropdown.item_selected. Applies the mode; on
## failure (invalid mode or no backend, set_mode() no longer waits on
## the hardware write itself), reverts the dropdown's visible
## selection (Dropdown/OptionButton already moved it before this runs)
## back to the current mode.
func _on_mode_selected(index: int) -> void:
	if index < 0 or index >= _mode_ids.size():
		logger.debug("_on_mode_selected(%d): index out of range (%d ids)" % [index, _mode_ids.size()])
		return

	var mode_id := _mode_ids[index]
	if mode_id == mode_manager.current_mode:
		logger.debug("_on_mode_selected(%d): '%s' already active, ignoring" % [index, mode_id])
		return

	logger.debug("_on_mode_selected(%d): switching to '%s'" % [index, mode_id])
	if not mode_manager.set_mode(mode_id, true):
		logger.debug("_on_mode_selected(%d): switch to '%s' failed, reverting dropdown" % [index, mode_id])
		_select_dropdown_for_mode(mode_manager.current_mode)
		return

	_select_dropdown_for_mode(mode_id)

	# No separate commit call needed here: set_mode(mode_id, true)
	# already fired fan_mode_changed(mode_id, user_initiated=true),
	# which GameCurveManager._on_fan_mode_changed() reacts to by
	# calling curve_session.apply_pressed() itself (commits every
	# engine's draft to hardware while in custom mode, and stages the
	# game_curves write) — this flush() just drains that.
	mode_manager.store.flush()


## Signal handler for FanModeManager.fan_mode_changed.
func _on_fan_mode_changed(mode: String, _user_initiated: bool) -> void:
	_select_dropdown_for_mode(mode)


## Signal handler for GameCurveManager.curve_session.state_changed
## the badge now reflects the state machine directly.
func _on_curve_session_state_changed(state: CurveSessionState.State, _context_key: String) -> void:
	dirty_badge.visible = state == CurveSessionState.State.DIRTY


## Called by plugin.gd once GameCurveManager exists. Syncs the toggle
## to manager's state and wires it up.
func bind_game_curve_manager(manager: GameCurveManager) -> void:
	game_curve_manager = manager
	per_game_toggle.button_pressed = manager.per_game_enabled
	per_game_toggle.toggled.connect(_on_per_game_toggled)
	manager.curve_applied.connect(_on_curve_applied)
	manager.curve_session.state_changed.connect(_on_curve_session_state_changed)


## Signal handler for the per-game Toggle.
func _on_per_game_toggled(pressed: bool) -> void:
	if game_curve_manager:
		game_curve_manager.per_game_enabled = pressed


## Signal handler for GameCurveManager.curve_applied: CustomCurveEngine.
## load_curve() doesn't emit curve_changed, so the visible sliders
## wouldn't otherwise pick up a per-context curve switch (see
## curve_applied's doc comment). Re-binding forces each editor to
## re-pull and redraw the engine's current curve.
func _on_curve_applied() -> void:
	if mode_manager.current_mode != "custom":
		return
	_resync_fan_editors()


## Re-pulls each built CustomCurveEditor's displayed curve from its
## bound engine.
func _resync_fan_editors() -> void:
	var engines := mode_manager.get_all_curve_engines()
	for fan_id in _fan_editors:
		if engines.has(fan_id):
			(_fan_editors[fan_id] as CustomCurveEditor).bind_engine(engines[fan_id])


## Commits whatever's currently on the sliders (the draft curve) to
## hardware and disk. Apply never goes through set_mode() (this button
## only exists in Custom Mode — see apply_button.visible in
## _select_dropdown_for_mode()), so it can't rely on fan_mode_changed
## to notify GameCurveManager: calls curve_session.apply_pressed()
## directly instead, symmetric to what _on_fan_mode_changed() does for
## a real mode switch. That call is what actually pushes every
## engine's draft to hardware (GameCurveManager._on_curve_session_committed())
## and stages the game_curves write; it only enqueues that write
## though (see FanCurveStore.enqueue()'s doc comment), so flush()
## explicitly at the end to drain it.
func _on_apply_pressed() -> void:
	logger.debug("_on_apply_pressed(): committing (reason: user pressed Apply)")
	if game_curve_manager:
		game_curve_manager.curve_session.apply_pressed()
	mode_manager.store.flush()


## Selects mode in the dropdown, shows/hides the custom editor UI, and
## (when entering "custom") builds/binds the fan editors.
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

	# Re-applied every time Custom Mode turns on: idempotent, and cheap
	# insurance against ApplyButton's neighbor going stale.
	if not _fan_editors.is_empty():
		_wire_focus_into_curve_editor.call_deferred(_fan_editors.keys()[0])


## Builds one CustomCurveEditor per fan reported by the backend, plus a
## FanTabButton per fan when there's more than one (tab bar stays
## hidden for a single fan). Runs once.
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
			tab.label_text = mode_manager.backend.get_fan_label(fan_id)
			tab.focus_entered.connect(_on_fan_tab_focused.bind(fan_id))
			fan_tabs_bar.add_child(tab)
			_fan_tab_buttons[fan_id] = tab

	if not fans.is_empty():
		_select_fan_tab(fans[0])


## Bridges focus from ApplyButton down into the curve editor area: the
## first_fan_id's tab if the backend reports more than one fan,
## otherwise straight to the first TemperatureSliderRow of the single
## editor. Safe to call repeatedly/deferred.
func _wire_focus_into_curve_editor(first_fan_id: String) -> void:
	var entry_point: Control
	if _fan_tab_buttons.has(first_fan_id):
		entry_point = _fan_tab_buttons[first_fan_id]
	else:
		entry_point = (_fan_editors[first_fan_id] as CustomCurveEditor).get_first_row()

	if not entry_point:
		return

	apply_button.focus_neighbor_bottom = apply_button.get_path_to(entry_point)
	entry_point.focus_neighbor_top = entry_point.get_path_to(apply_button)
	logger.info(
		"Wired ApplyButton <-> %s (focus_neighbor_bottom=%s)"
		% [entry_point.name, apply_button.focus_neighbor_bottom]
	)


## Re-links every fan tab's "down" and selected_fan_id's editor's first
## row's "up" to each other, whenever the selected tab changes: down
## from any tab always goes to the selected editor's first row, up from
## that row goes back to whichever tab is currently selected.
func _wire_tab_to_selected_editor(selected_fan_id: String) -> void:
	if not _fan_tab_buttons.has(selected_fan_id):
		return

	var first_row := (_fan_editors[selected_fan_id] as CustomCurveEditor).get_first_row()
	if not first_row:
		return

	for id in _fan_tab_buttons:
		var tab := _fan_tab_buttons[id] as FanTabButton
		tab.focus_neighbor_bottom = tab.get_path_to(first_row)

	var selected_tab := _fan_tab_buttons[selected_fan_id] as FanTabButton
	first_row.focus_neighbor_top = first_row.get_path_to(selected_tab)


## Signal handler for FanTabButton.focus_entered: switches the visible
## editor as soon as a tab is focused, no separate confirm step.
func _on_fan_tab_focused(fan_id: String) -> void:
	_select_fan_tab(fan_id)


## Shows fan_id's editor and marks its tab selected, hiding the rest,
## and re-wires tab<->editor focus neighbors to the new selection.
func _select_fan_tab(fan_id: String) -> void:
	for id in _fan_editors:
		(_fan_editors[id] as CustomCurveEditor).visible = id == fan_id
	for id in _fan_tab_buttons:
		(_fan_tab_buttons[id] as FanTabButton).selected = id == fan_id

	_wire_tab_to_selected_editor(fan_id)
