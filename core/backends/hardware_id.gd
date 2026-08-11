extends RefCounted
class_name HardwareId

## Shared hardware identification helper. Used by every FanBackend so
## the same physical machine always produces the same hardware_id
## regardless of which backend ends up controlling it (e.g. if
## AsusWmiFanBackend isn't available and HwmonFanBackend takes over as
## fallback, saved curve profiles must still apply).

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
	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		return ""
	return file.get_as_text()
