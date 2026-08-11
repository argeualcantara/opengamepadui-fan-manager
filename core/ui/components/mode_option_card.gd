extends PanelContainer
class_name ModeOptionCard

## A single focusable, selectable row in the fan mode list (BIOS/OS/
## Custom). Mirrors OGUI's core/ui/components/card_button.gd (focus
## highlight tween, ui_accept handling) since that component only
## supports a single centered label, not the name+description+checkmark
## layout this list needs.

signal pressed

@export var mode_id := ""

@export var mode_name := "":
	set(v):
		mode_name = v
		if name_label:
			name_label.text = v

@export_multiline var description := "":
	set(v):
		description = v
		if description_label:
			description_label.text = v

@export var selected := false:
	set(v):
		selected = v
		if check_icon:
			check_icon.visible = v

@export var highlight_speed := 0.1

@onready var name_label := %NameLabel as Label
@onready var description_label := %DescriptionLabel as Label
@onready var check_icon := %CheckIcon as TextureRect
@onready var highlight := %HighlightTexture as TextureRect

var _tween: Tween


func _ready() -> void:
	name_label.text = mode_name
	description_label.text = description
	check_icon.visible = selected

	focus_entered.connect(_on_focus)
	focus_exited.connect(_on_unfocus)
	mouse_entered.connect(_on_focus)
	mouse_exited.connect(_on_unfocus)


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


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.is_pressed():
			pressed.emit()
		return

	if event.is_action_pressed("ui_accept"):
		pressed.emit()
