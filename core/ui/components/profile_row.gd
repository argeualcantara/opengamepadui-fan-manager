extends PanelContainer
class_name ProfileRow

## A single focusable row in the saved-profiles list: name + a
## mouse-only delete button. Selecting the row (click or ui_accept)
## loads that profile; the delete button removes it.
##
## The delete button intentionally has focus_mode = FOCUS_NONE: v1
## only supports deleting a profile by mouse/touch. Gamepad-only
## deletion is a known gap, not covered by this activity's acceptance
## criteria; see tasks/08-ui-perfis-salvar-carregar.md.
##
## Follows the same focus-highlight tween pattern as
## card_button.gd / mode_option_card.gd.

signal selected(profile_name: String)
signal delete_requested(profile_name: String)

@export var profile_name := "":
	set(v):
		profile_name = v
		if name_label:
			name_label.text = v

@export var active := false:
	set(v):
		active = v
		if status_dot:
			status_dot.modulate = Color(0.314, 0.980, 0.482) if v else Color(0.565, 0.573, 0.753)
		if name_label:
			name_label.modulate = Color(0.314, 0.980, 0.482) if v else Color(1, 1, 1)

@export var highlight_speed := 0.1

@onready var name_label := $%NameLabel as Label
@onready var status_dot := $%StatusDot as Control
@onready var delete_button := $%DeleteButton as Button
@onready var highlight := $%HighlightTexture as TextureRect

var _tween: Tween


func _ready() -> void:
	focus_mode = Control.FOCUS_ALL
	name_label.text = profile_name

	focus_entered.connect(_on_focus)
	focus_exited.connect(_on_unfocus)
	mouse_entered.connect(_on_focus)
	mouse_exited.connect(_on_unfocus)
	theme_changed.connect(_on_theme_changed)
	_on_theme_changed()

	delete_button.pressed.connect(func(): delete_requested.emit(profile_name))


## Mirrors card_button.gd: TextureRect.texture isn't a themed property
## Godot applies automatically, so the "highlight" icon has to be
## fetched and assigned manually (see mode_option_card.gd).
func _on_theme_changed() -> void:
	var highlight_texture := get_theme_icon("highlight", "CardButton")
	if highlight_texture:
		highlight.texture = highlight_texture


func _gui_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_accept"):
		selected.emit(profile_name)
		accept_event()
	elif event is InputEventMouseButton and event.is_pressed():
		if (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			grab_focus()
			selected.emit(profile_name)


func _on_focus() -> void:
	if _tween:
		_tween.kill()
	_tween = get_tree().create_tween()
	_tween.tween_property(highlight, "visible", true, 0)
	_tween.tween_property(highlight, "modulate", Color(1, 1, 1, 0), 0)
	_tween.tween_property(highlight, "modulate", Color(1, 1, 1, 1), highlight_speed)


func _on_unfocus() -> void:
	if _tween:
		_tween.kill()
	_tween = get_tree().create_tween()
	_tween.tween_property(highlight, "modulate", Color(1, 1, 1, 1), 0)
	_tween.tween_property(highlight, "modulate", Color(1, 1, 1, 0), highlight_speed)
	_tween.tween_property(highlight, "visible", false, 0)
