extends PanelContainer
class_name FanTabButton

# small focusable tab to switch between per-fan curve editors when there's
# more than one fan. same focus-highlight pattern as ModeOptionCard, plus a
# bottom indicator bar for the selected state.

signal pressed

@export var fan_id := ""

@export var label_text := "":
	set(v):
		label_text = v
		if name_label:
			name_label.text = v

@export var selected := false:
	set(v):
		selected = v
		if indicator:
			indicator.visible = v

@export var highlight_speed := 0.1

@onready var name_label := %NameLabel as Label
@onready var indicator := %Indicator as ColorRect
@onready var highlight := %HighlightTexture as TextureRect

var _tween: Tween


func _ready() -> void:
	name_label.text = label_text
	indicator.visible = selected

	focus_entered.connect(_on_focus)
	focus_exited.connect(_on_unfocus)
	mouse_entered.connect(_on_focus)
	mouse_exited.connect(_on_unfocus)
	theme_changed.connect(_on_theme_changed)
	_on_theme_changed()


# TextureRect.texture isn't a themed property godot applies on its own,
# same deal as card_button.gd
func _on_theme_changed() -> void:
	var highlight_texture := get_theme_icon("highlight", "CardButton")
	if highlight_texture:
		highlight.texture = highlight_texture


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
		var left_click = mb.button_index == MOUSE_BUTTON_LEFT and mb.is_pressed()
		if left_click:
			pressed.emit()
		return

	var accept_pressed = event.is_action_pressed("ui_accept")
	if accept_pressed:
		pressed.emit()
