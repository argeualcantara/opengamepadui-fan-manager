extends ScrollContainer
class_name ModeSelectOverlay

## BIOS/OS/Custom Mode select card shown in OGUI's Quick Bar menu
## (tasks/06-ui-select-modo-overlay.md, restructured for the Quick Bar
## by tasks/16-quick-bar-em-vez-de-overlay.md). Reflects and drives
## FanModeManager: no mode-switching logic lives here, only UI state.
##
## Root is a ScrollContainer (not OverlayProvider, and not a plain
## VBoxContainer as before) on purpose: this is added to a
## QuickBarCard's ContentContainer (also a VBoxContainer) via
## Plugin.add_to_quick_bar(), which lays out children by their
## reported minimum size, not by anchors. The previous OverlayProvider
## version relied on anchor-based centering meant for a full-screen
## OverlayContainer, which --overlay-mode's scene doesn't even have.
## All the actual content lives in the child `ScrollContent`
## VBoxContainer; this root just caps how tall the card is allowed to
## grow (MAX_PANEL_HEIGHT) and scrolls internally past that, instead of
## the whole Quick Bar ballooning to fit Custom Mode's 10 sliders. See
## _update_scroll_cap().
##
## FanModeManager/ProfileManagerPanel/GameCurveManager/
## CustomCurveEditor/FanTabButton below are referenced via preload()'d
## consts, not bare class_name lookups (see hwmon_fan_backend.gd's
## header comment / tasks/17-fix-class-name-resolution-em-plugin-empacotado.md).
## Dropdown/Toggle are OGUI's own core classes (compiled into the base
## game), so they resolve fine as bare names, same as FocusGroup/Label.
const FanModeManager = preload("res://plugins/fan-manager/core/modes/fan_mode_manager.gd")
const ProfileManagerPanel = preload("res://plugins/fan-manager/core/ui/components/profile_manager_panel.gd")
const GameCurveManager = preload("res://plugins/fan-manager/core/modes/game_curve_manager.gd")
const CustomCurveEditor = preload("res://plugins/fan-manager/core/ui/components/custom_curve_editor.gd")
const FanTabButton = preload("res://plugins/fan-manager/core/ui/components/fan_tab_button.gd")

const CURVE_EDITOR_SCENE := preload("res://plugins/fan-manager/core/ui/components/custom_curve_editor.tscn")
const FAN_TAB_SCENE := preload("res://plugins/fan-manager/core/ui/components/fan_tab_button.tscn")

## mode_id -> label shown in the dropdown and in the switch-failure
## error message. Order here is also the order items are added to the
## dropdown in _populate_mode_dropdown().
const MODE_LABELS := {
	"bios": "BIOS Mode",
	"os": "OS Mode",
	"custom": "Custom Mode",
}

## Tallest the card is allowed to grow before it scrolls internally
## instead of pushing the rest of the Quick Bar down (mainly hit in
## Custom Mode, once the 10 TemperatureSliderRow instances and, when
## the backend reports more than one fan, FanTabsBar are all visible).
const MAX_PANEL_HEIGHT := 420.0

var mode_manager: FanModeManager

var logger := Log.get_logger("ModeSelectOverlay")

@onready var scroll_content := $%ScrollContent as VBoxContainer
@onready var focus_group := $%FocusGroup as FocusGroup
@onready var mode_dropdown := $%ModeDropdown as Dropdown
@onready var error_label := $%ErrorLabel as Label
@onready var no_backend_label := $%NoBackendLabel as Label
@onready var mode_list := $%ModeList as Control
@onready var custom_editor_slot := $%CustomEditorSlot as Control
@onready var fan_tabs_bar := $%FanTabsBar as HBoxContainer
@onready var editors_container := $%EditorsContainer as Control
@onready var profiles_panel := $%ProfilesPanel as ProfileManagerPanel
@onready var dirty_badge := $%DirtyBadge as Label
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

## dropdown item index -> mode_id. Rebuilt by _populate_mode_dropdown();
## "os" is only added when the backend supports it, so index doesn't
## always line up 1:1 with MODE_LABELS.
var _mode_ids: Array[String] = []


func _ready() -> void:
	error_label.visible = false
	profiles_panel.dirty_changed.connect(_on_dirty_changed)

	if not mode_manager or not mode_manager.backend:
		logger.warn("No FanModeManager/backend available; showing empty state")
		mode_list.visible = false
		per_game_toggle.visible = false
		apply_button.visible = false
		no_backend_label.visible = true
		_update_scroll_cap.call_deferred()
		return

	no_backend_label.visible = false
	mode_manager.mode_changed.connect(_on_mode_changed)

	_populate_mode_dropdown()
	mode_dropdown.item_selected.connect(_on_mode_selected)
	apply_button.pressed.connect(_on_apply_pressed)

	_select_dropdown_for_mode(mode_manager.current_mode)

	focus_group.grab_focus.call_deferred()
	_update_scroll_cap.call_deferred()
	_wire_dropdown_exit_focus.call_deferred()


## The only cross-boundary focus link that can't be set declaratively
## in the .tscn: ModeList's FocusGroup treats ModeDropdown as its sole
## child, so its own _ready() (already run by the time ours runs)
## unconditionally overwrites ModeDropdown's focus_neighbor_* to point
## to itself on all 4 sides (FocusGroup._single_set_focus_tree()) —
## any NodePath set on it in the .tscn is clobbered the same way.
## Dropdown then proxies focus_neighbor_bottom to its internal
## OptionButton once, in Dropdown._ready() (also already run): setting
## mode_dropdown.focus_neighbor_bottom here would land on the outer
## wrapper, too late to matter, so this goes through
## mode_dropdown.option_button directly instead.
##
## Must be called deferred (see the call site in _ready()): PackedScene
## .instantiate() runs _ready() on the whole subtree immediately, before
## plugin.gd's add_to_quick_bar() has attached it to the live tree, and
## get_path_to() below hard-errors ("not inside tree") when called
## before that attachment happens. Same reason focus_group.grab_focus
## and _update_scroll_cap are already deferred here too.
func _wire_dropdown_exit_focus() -> void:
	var dropdown_option := mode_dropdown.option_button
	dropdown_option.focus_neighbor_bottom = dropdown_option.get_path_to(per_game_toggle)


## Builds the dropdown items in MODE_LABELS order, skipping "OS Mode"
## entirely on hardware that doesn't support it (REQUIREMENTS.md §2.2:
## hide/disable when unavailable; omitting the item is simpler than a
## disabled OptionButton entry and matches what the old OsCard.visible
## = false did).
func _populate_mode_dropdown() -> void:
	mode_dropdown.clear()
	_mode_ids.clear()
	for mode_id in MODE_LABELS:
		if mode_id == "os" and not mode_manager.backend.supports_os_mode():
			continue
		mode_dropdown.add_item(MODE_LABELS[mode_id])
		_mode_ids.append(mode_id)


func _on_mode_selected(index: int) -> void:
	if index < 0 or index >= _mode_ids.size():
		return

	var mode_id := _mode_ids[index]
	if mode_id == mode_manager.current_mode:
		return

	if not mode_manager.set_mode(mode_id):
		error_label.text = "Unable to switch to %s. Please try again." % MODE_LABELS[mode_id]
		error_label.visible = true
		# Dropdown.select()/OptionButton already moved the visible
		# selection to the failed item (unlike the old ModeOptionCard
		# list, which never changed `selected` until this method called
		# _select_card_for_mode() on success): revert it so the UI
		# doesn't show a mode that was never actually applied.
		_select_dropdown_for_mode(mode_manager.current_mode)
		return

	error_label.visible = false
	_select_dropdown_for_mode(mode_id)


func _on_mode_changed(mode: String) -> void:
	error_label.visible = false
	_select_dropdown_for_mode(mode)


func _on_dirty_changed(is_dirty: bool) -> void:
	dirty_badge.visible = is_dirty


## Called by plugin.gd once GameCurveManager exists (it needs
## `profiles_panel`, which only resolves after this overlay's own
## _ready() has run, so it can't be constructed any earlier).
func bind_game_curve_manager(manager: GameCurveManager) -> void:
	game_curve_manager = manager
	per_game_toggle.button_pressed = manager.per_game_enabled
	per_game_toggle.toggled.connect(_on_per_game_toggled)


func _on_per_game_toggled(pressed: bool) -> void:
	if game_curve_manager:
		game_curve_manager.per_game_enabled = pressed


## Commits whatever's currently on the sliders (the draft curve) to
## hardware and disk, standing in for ProfileManagerPanel's own Save
## button while its picker UI is hidden: see
## ProfileManagerPanel.apply_current().
func _on_apply_pressed() -> void:
	profiles_panel.apply_current()


func _select_dropdown_for_mode(mode: String) -> void:
	var idx := _mode_ids.find(mode)
	if idx != -1:
		mode_dropdown.selected = idx
	custom_editor_slot.visible = mode == "custom"
	apply_button.visible = mode == "custom"

	if mode != "custom":
		dirty_badge.visible = false
		_update_scroll_cap.call_deferred()
		return

	_ensure_fan_editors()

	var engines := mode_manager.get_all_curve_engines()
	for fan_id in _fan_editors:
		if engines.has(fan_id):
			(_fan_editors[fan_id] as CustomCurveEditor).bind_engine(engines[fan_id])

	profiles_panel.refresh(mode_manager.store, mode_manager.hardware_id, engines)
	_update_scroll_cap.call_deferred()


## Recomputes how tall ScrollContent naturally wants to be (after
## whatever visibility/child changes the caller just made land in a
## layout pass, hence call_deferred() at every call site instead of
## calling this directly) and caps this ScrollContainer's own minimum
## size at MAX_PANEL_HEIGHT. Below the cap this just tracks the content
## exactly (no dead space, no scrollbar); at/above it the container
## stops growing and the overflow scrolls instead, e.g. Custom Mode
## with every slider visible.
func _update_scroll_cap() -> void:
	var natural_height := scroll_content.get_combined_minimum_size().y
	custom_minimum_size.y = minf(natural_height, MAX_PANEL_HEIGHT)


## Builds one CustomCurveEditor per fan reported by the backend, and a
## FanTabButton per fan when there's more than one (a single fan keeps
## the tab bar hidden: identical to the pre-multi-fan layout). Runs
## once; the fan list for a given hardware/backend never changes at
## runtime.
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
			tab.pressed.connect(_on_fan_tab_pressed.bind(fan_id))
			fan_tabs_bar.add_child(tab)
			_fan_tab_buttons[fan_id] = tab

	if not fans.is_empty():
		_select_fan_tab(fans[0])
		_wire_focus_into_curve_editor(fans[0])


## Bridges focus from ApplyButton down into the fixed entry point of
## the curve editor area: the first fan tab if the backend reports more
## than one fan (tab order never changes, so this is wired once here,
## unlike _wire_tab_to_selected_editor()'s row0<->tab link, which
## tracks whichever tab is currently selected), otherwise straight to
## the first TemperatureSliderRow of the single editor. Wires both
## directions: CustomCurveEditor no longer wraps row 0 back to row 9
## (see _wire_focus_neighbors()), so there's no existing loop here to
## clobber.
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


## Re-links every fan tab's "down" and the newly-selected editor's
## first row's "up" to each other, whenever the selected tab changes
## (called from _select_fan_tab(), both on initial build and on every
## tab switch): REQUIREMENTS-driven UX spec is "down from any tab goes
## to the selected editor's first row; up from the first row goes back
## to whichever tab is currently selected" — deliberately not "the tab
## that was focused before descending", since those can differ (moving
## focus with ui_left/ui_right doesn't select a tab, only pressing
## ui_accept on it does; see FanTabButton._gui_input()).
## No-op for single-fan hardware: there's no tab bar to link, and
## ApplyButton already points straight at the only row that exists
## (wired once in _wire_focus_into_curve_editor()).
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


func _on_fan_tab_pressed(fan_id: String) -> void:
	_select_fan_tab(fan_id)


func _select_fan_tab(fan_id: String) -> void:
	for id in _fan_editors:
		(_fan_editors[id] as CustomCurveEditor).visible = id == fan_id
	for id in _fan_tab_buttons:
		(_fan_tab_buttons[id] as FanTabButton).selected = id == fan_id

	_wire_tab_to_selected_editor(fan_id)
