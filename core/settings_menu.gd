extends Control
class_name FanManagerSettingsMenu

const PwmIo = preload("res://plugins/fan-manager/core/utils/pwm_io.gd")

var logger := Log.get_logger("FanManager SettingsMenu")

@onready var dry_run_toggle := $%DryRunToggle as Toggle


func _ready() -> void:
	dry_run_toggle.button_pressed = not PwmIo.dry_run
	dry_run_toggle.toggled.connect(_on_dry_run_toggled)


# toggle is framed as "write to hardware" (the opposite of dry_run), so
# turning it on is the deliberate action that turns dry_run off
func _on_dry_run_toggled(pressed: bool) -> void:
	PwmIo.dry_run = not pressed
	logger.info("PwmIo.dry_run set to %s via settings toggle" % PwmIo.dry_run)
