extends PanelContainer
class_name TemperatureSliderRow

## A single focusable row in the custom curve editor: a temperature
## label, a percent "slider" (custom-drawn fill+thumb, not a native
## HSlider: see tasks/07-ui-editor-curva-sliders.md), and a value
## label. `ui_left`/`ui_right` step the value while focused; `ui_up`/
## `ui_down` are left alone so the parent list can move focus between
## rows (wired via CustomCurveEditor, not FocusGroup: this row isn't
## a direct VBoxContainer child of a plain layout FocusGroup expects).
##
## Follows the same focus-highlight tween pattern as
## core/ui/components/card_button.gd / mode_option_card.gd.

signal value_changed(temperature: int, percent: float)

const STEP := 1.0

@export var temperature: int = 0:
	set(v):
		temperature = v
		if temp_label:
			temp_label.text = "%d°C" % v

@export var highlight_speed := 0.1

var percent: float = 0.0

@onready var temp_label := $%TempLabel as Label
@onready var value_label := $%ValueLabel as Label
@onready var fill := $%Fill as Control
@onready var thumb := $%Thumb as Control
@onready var highlight := $%HighlightTexture as TextureRect

var _tween: Tween


func _ready() -> void:
	focus_mode = Control.FOCUS_ALL
	temp_label.text = "%d°C" % temperature
	_update_visual()

	focus_entered.connect(_on_focus)
	focus_exited.connect(_on_unfocus)
	mouse_entered.connect(_on_focus)
	mouse_exited.connect(_on_unfocus)
	theme_changed.connect(_on_theme_changed)
	_on_theme_changed()


## Mirrors card_button.gd: TextureRect.texture isn't a themed property
## Godot applies automatically, so the "highlight" icon has to be
## fetched and assigned manually (see mode_option_card.gd).
func _on_theme_changed() -> void:
	var highlight_texture := get_theme_icon("highlight", "CardButton")
	if highlight_texture:
		highlight.texture = highlight_texture


## Sets the displayed value without emitting value_changed: used when
## syncing from CustomCurveEngine.curve_changed (a programmatic update,
## as opposed to the user directly interacting with this row).
func set_percent_silently(p: float) -> void:
	percent = clampf(p, 0.0, 100.0)
	_update_visual()


func _update_visual() -> void:
	value_label.text = "%d%%" % int(round(percent))
	var fraction := percent / 100.0
	fill.anchor_right = fraction
	thumb.anchor_left = fraction
	thumb.anchor_right = fraction


func _gui_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_left"):
		_step(-STEP)
		accept_event()
	elif event.is_action_pressed("ui_right"):
		_step(STEP)
		accept_event()
	elif event is InputEventMouseButton and event.is_pressed():
		if (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			grab_focus()


func _step(delta: float) -> void:
	percent = clampf(percent + delta, 0.0, 100.0)
	_update_visual()
	value_changed.emit(temperature, percent)


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
