extends Control
class_name FanManagerSettingsMenu

## PwmIo is this plugin's own class (not OGUI core), so it's
## referenced via a preload()'d const, not a bare class_name lookup:
## see hwmon_fan_backend.gd's header comment for why. Toggle is OGUI's
## own core class (compiled into the base game), so it resolves fine
## as a bare name.
const PwmIo = preload("res://plugins/fan-manager/core/utils/pwm_io.gd")

var logger := Log.get_logger("FanManager SettingsMenu")

@onready var dry_run_toggle := $%DryRunToggle as Toggle


func _ready() -> void:
	dry_run_toggle.button_pressed = not PwmIo.dry_run
	dry_run_toggle.toggled.connect(_on_dry_run_toggled)


## dry_run defaults to true (writes only logged, never touch
## hardware); the toggle is framed as the opposite ("write to
## hardware") so pressing it ON is the deliberate, precautionary
## action that turns dry_run OFF.
func _on_dry_run_toggled(pressed: bool) -> void:
	PwmIo.dry_run = not pressed
	logger.info("PwmIo.dry_run set to %s via settings toggle" % PwmIo.dry_run)
