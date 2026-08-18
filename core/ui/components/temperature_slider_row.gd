extends PanelContainer
class_name TemperatureSliderRow

# one row in the custom curve editor: temperature label, a custom-drawn
# percent slider (not a native HSlider), and a value label. ui_left/right
# step the value while focused, ui_up/down are left alone so
# CustomCurveEditor can wire focus between rows itself.
#
# same focus-highlight tween pattern as card_button.gd

signal value_changed(temperature: int, percent: float)

const STEP := 1.0

# holding ui_left/right keeps stepping - HOLD_INITIAL_DELAY is the pause
# after the first step before it starts auto-repeating, HOLD_REPEAT_INTERVAL
# is the pace once it does
const HOLD_INITIAL_DELAY := 0.4
const HOLD_REPEAT_INTERVAL := 0.06

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

# -1 while ui_left is held, 1 while ui_right, 0 otherwise. _process() only
# runs while this isn't 0.
var _held_direction := 0
var _hold_timer := 0.0


func _ready() -> void:
	focus_mode = Control.FOCUS_ALL
	temp_label.text = "%d°C" % temperature
	_update_visual()
	set_process(false)

	focus_entered.connect(_on_focus)
	focus_exited.connect(_on_unfocus)
	focus_exited.connect(_stop_hold)
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


# used for programmatic syncs (e.g. from CustomCurveEngine.curve_changed),
# doesn't emit value_changed like a real user edit would
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
	var left_pressed = event.is_action_pressed("ui_left")
	var right_pressed = event.is_action_pressed("ui_right")
	var left_released = event.is_action_released("ui_left")
	var right_released = event.is_action_released("ui_right")

	if left_pressed:
		_step(-STEP)
		_start_hold(-1)
		accept_event()
	elif right_pressed:
		_step(STEP)
		_start_hold(1)
		accept_event()
	elif left_released or right_released:
		_stop_hold()
		accept_event()
	elif event is InputEventMouseButton and event.is_pressed():
		var mouse_event = event as InputEventMouseButton
		if mouse_event.button_index == MOUSE_BUTTON_LEFT:
			grab_focus()


func _step(delta: float) -> void:
	percent = clampf(percent + delta, 0.0, 100.0)
	_update_visual()
	value_changed.emit(temperature, percent)


# the initial press already applied one step above, so this only starts
# ticking after HOLD_INITIAL_DELAY, otherwise a plain tap would double-step
func _start_hold(direction: int) -> void:
	_held_direction = direction
	_hold_timer = HOLD_INITIAL_DELAY
	set_process(true)


func _stop_hold() -> void:
	_held_direction = 0
	set_process(false)


func _process(delta: float) -> void:
	if _held_direction == 0:
		set_process(false)
		return
	_hold_timer -= delta
	if _hold_timer <= 0.0:
		_step(_held_direction * STEP)
		_hold_timer = HOLD_REPEAT_INTERVAL


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
