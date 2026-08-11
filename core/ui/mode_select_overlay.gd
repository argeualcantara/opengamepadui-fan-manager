extends VBoxContainer
class_name ModeSelectOverlay

## BIOS/OS/Custom Mode select card shown in OGUI's Quick Bar menu
## (tasks/06-ui-select-modo-overlay.md, restructured for the Quick Bar
## by tasks/16-quick-bar-em-vez-de-overlay.md). Reflects and drives
## FanModeManager: no mode-switching logic lives here, only UI state.
##
## Plain VBoxContainer (not OverlayProvider) on purpose: this is added
## to a QuickBarCard's ContentContainer (also a VBoxContainer) via
## Plugin.add_to_quick_bar(), which lays out children by their
## reported minimum size, not by anchors. The previous OverlayProvider
## version relied on anchor-based centering meant for a full-screen
## OverlayContainer, which --overlay-mode's scene doesn't even have.
##
## FanModeManager/ModeOptionCard/ProfileManagerPanel/GameCurveManager/
## CustomCurveEditor/FanTabButton below are referenced via preload()'d
## consts, not bare class_name lookups (see hwmon_fan_backend.gd's
## header comment / tasks/17-fix-class-name-resolution-em-plugin-empacotado.md).
const FanModeManager = preload("res://plugins/fan-manager/core/modes/fan_mode_manager.gd")
const ModeOptionCard = preload("res://plugins/fan-manager/core/ui/components/mode_option_card.gd")
const ProfileManagerPanel = preload("res://plugins/fan-manager/core/ui/components/profile_manager_panel.gd")
const GameCurveManager = preload("res://plugins/fan-manager/core/modes/game_curve_manager.gd")
const CustomCurveEditor = preload("res://plugins/fan-manager/core/ui/components/custom_curve_editor.gd")
const FanTabButton = preload("res://plugins/fan-manager/core/ui/components/fan_tab_button.gd")

const CURVE_EDITOR_SCENE := preload("res://plugins/fan-manager/core/ui/components/custom_curve_editor.tscn")
const FAN_TAB_SCENE := preload("res://plugins/fan-manager/core/ui/components/fan_tab_button.tscn")

var mode_manager: FanModeManager

var logger := Log.get_logger("ModeSelectOverlay")

@onready var focus_group := $%FocusGroup as FocusGroup
@onready var bios_card := $%BiosCard as ModeOptionCard
@onready var os_card := $%OsCard as ModeOptionCard
@onready var custom_card := $%CustomCard as ModeOptionCard
@onready var error_label := $%ErrorLabel as Label
@onready var no_backend_label := $%NoBackendLabel as Label
@onready var mode_list := $%ModeList as Control
@onready var custom_editor_slot := $%CustomEditorSlot as Control
@onready var fan_tabs_bar := $%FanTabsBar as HBoxContainer
@onready var editors_container := $%EditorsContainer as Control
@onready var profiles_panel := $%ProfilesPanel as ProfileManagerPanel
@onready var dirty_badge := $%DirtyBadge as Label
@onready var per_game_toggle := $%PerGameToggle as CheckBox

var game_curve_manager: GameCurveManager

## fan_id -> CustomCurveEditor / FanTabButton, built once the first
## time Custom Mode is shown (tasks/14-suporte-multiplas-fans.md). One
## editor per fan, always instantiated; tabs only shown/used when there
## is more than one fan.
var _fan_editors: Dictionary = {}
var _fan_tab_buttons: Dictionary = {}
var _fans_built := false


func _ready() -> void:
	bios_card.mode_id = "bios"
	bios_card.mode_name = "BIOS Mode"
	bios_card.description = "Uses the fan curve defined by the BIOS/firmware."

	os_card.mode_id = "os"
	os_card.mode_name = "OS Mode"
	os_card.description = "Uses the fan curve defined by the operating system."

	custom_card.mode_id = "custom"
	custom_card.mode_name = "Custom Mode"
	custom_card.description = "Uses the curve customized by the user."

	bios_card.pressed.connect(_on_card_pressed.bind(bios_card))
	os_card.pressed.connect(_on_card_pressed.bind(os_card))
	custom_card.pressed.connect(_on_card_pressed.bind(custom_card))

	error_label.visible = false
	profiles_panel.dirty_changed.connect(_on_dirty_changed)

	if not mode_manager or not mode_manager.backend:
		logger.warn("No FanModeManager/backend available; showing empty state")
		mode_list.visible = false
		per_game_toggle.visible = false
		no_backend_label.visible = true
		return

	no_backend_label.visible = false
	mode_manager.mode_changed.connect(_on_mode_changed)
	os_card.visible = mode_manager.backend.supports_os_mode()
	_select_card_for_mode(mode_manager.current_mode)

	focus_group.grab_focus.call_deferred()


func _on_card_pressed(card: ModeOptionCard) -> void:
	if card.mode_id == mode_manager.current_mode:
		return

	if not mode_manager.set_mode(card.mode_id):
		error_label.text = "Unable to switch to %s. Please try again." % card.mode_name
		error_label.visible = true
		return

	error_label.visible = false
	_select_card_for_mode(card.mode_id)


func _on_mode_changed(mode: String) -> void:
	error_label.visible = false
	_select_card_for_mode(mode)


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


func _select_card_for_mode(mode: String) -> void:
	bios_card.selected = mode == "bios"
	os_card.selected = mode == "os"
	custom_card.selected = mode == "custom"
	custom_editor_slot.visible = mode == "custom"

	if mode != "custom":
		dirty_badge.visible = false
		return

	_ensure_fan_editors()

	var engines := mode_manager.get_all_curve_engines()
	for fan_id in _fan_editors:
		if engines.has(fan_id):
			(_fan_editors[fan_id] as CustomCurveEditor).bind_engine(engines[fan_id])

	profiles_panel.refresh(mode_manager.store, mode_manager.hardware_id, engines)


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


func _on_fan_tab_pressed(fan_id: String) -> void:
	_select_fan_tab(fan_id)


func _select_fan_tab(fan_id: String) -> void:
	for id in _fan_editors:
		(_fan_editors[id] as CustomCurveEditor).visible = id == fan_id
	for id in _fan_tab_buttons:
		(_fan_tab_buttons[id] as FanTabButton).selected = id == fan_id
