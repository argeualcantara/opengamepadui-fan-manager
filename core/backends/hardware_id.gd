extends RefCounted
class_name HardwareId

const PwmIo = preload("res://plugins/fan-manager/core/backends/pwm_io.gd")

## Shared hardware identification helper: ensures every FanBackend
## produces the same hardware_id for the same physical machine.

const UNKNOWN := "unknown-hardware"

const DMI_PRODUCT_NAME := "/sys/class/dmi/id/product_name"
const DMI_BOARD_NAME := "/sys/class/dmi/id/board_name"


## Returns a stable id derived from DMI product/board name, or
## [constant UNKNOWN] if neither is readable.
static func from_dmi() -> String:
	var product := _read_text(DMI_PRODUCT_NAME).strip_edges()
	var board := _read_text(DMI_BOARD_NAME).strip_edges()

	if product.is_empty() and board.is_empty():
		return UNKNOWN

	Log.get_logger("HardwareId").info("Detected device: product='%s' board='%s'" % [product, board])
	return "%s-%s" % [product, board]


static func _read_text(path: String) -> String:
	return PwmIo.read_text(path)
