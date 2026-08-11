extends PanelContainer
class_name ProfileTriggerButton

## The "current profile" button shown above the fan curve editor in
## Custom Mode. Pressing it just emits `pressed`; ProfileManagerPanel
## owns whether the dropdown is open and tells this component what to
## display. Mirrors ModeOptionCard/FanTabButton's focus-highlight
## tween pattern.

signal pressed

@export var profile_name := "":
	set(v):
		profile_name = v
		_update_label()

## True while no named profile is active yet ("New profile" was picked
## but nothing has been saved under a name). Swaps the dot to the
## unselected/muted color and the label to a placeholder, instead of
## showing (and implying) a real saved profile name.
@export var pending := false:
	set(v):
		pending = v
		_update_label()
		if dot:
			dot.modulate = Color(0.565, 0.573, 0.753) if v else Color(0.314, 0.980, 0.482)

## True while ProfileManagerPanel's dropdown is currently open: only
## flips the chevron glyph, the dropdown itself lives in the parent.
@export var open := false:
	set(v):
		open = v
		if chevron:
			chevron.text = "▴" if v else "▾"

@export var highlight_speed := 0.1

@onready var dot := %Dot as Control
@onready var name_label := %NameLabel as Label
@onready var chevron := %Chevron as Label
@onready var highlight := %HighlightTexture as TextureRect

var _tween: Tween


## Syncs label/chevron/dot to the current export values and wires
## focus/hover/theme signals.
func _ready() -> void:
	_update_label()
	chevron.text = "▴" if open else "▾"
	dot.modulate = Color(0.565, 0.573, 0.753) if pending else Color(0.314, 0.980, 0.482)

	focus_entered.connect(_on_focus)
	focus_exited.connect(_on_unfocus)
	mouse_entered.connect(_on_focus)
	mouse_exited.connect(_on_unfocus)
	theme_changed.connect(_on_theme_changed)
	_on_theme_changed()


## Fetches the "highlight" icon manually: TextureRect.texture isn't a
## themed property Godot applies automatically (mirrors card_button.gd).
func _on_theme_changed() -> void:
	var highlight_texture := get_theme_icon("highlight", "CardButton")
	if highlight_texture:
		highlight.texture = highlight_texture


## Sets the label to the pending placeholder or profile_name.
func _update_label() -> void:
	if not name_label:
		return
	name_label.text = "New profile (unsaved)" if pending else profile_name


## Signal handler for focus_entered/mouse_entered: fades the highlight in.
func _on_focus() -> void:
	if _tween:
		_tween.kill()
	_tween = get_tree().create_tween()
	_tween.tween_property(highlight, "visible", true, 0)
	_tween.tween_property(highlight, "modulate", Color(1, 1, 1, 0), 0)
	_tween.tween_property(highlight, "modulate", Color(1, 1, 1, 1), highlight_speed)


## Signal handler for focus_exited/mouse_exited: fades the highlight out.
func _on_unfocus() -> void:
	if _tween:
		_tween.kill()
	_tween = get_tree().create_tween()
	_tween.tween_property(highlight, "modulate", Color(1, 1, 1, 1), 0)
	_tween.tween_property(highlight, "modulate", Color(1, 1, 1, 0), highlight_speed)
	_tween.tween_property(highlight, "visible", false, 0)


## Emits pressed on left-click or ui_accept.
func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.is_pressed():
			pressed.emit()
		return

	if event.is_action_pressed("ui_accept"):
		pressed.emit()
