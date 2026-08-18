extends RefCounted
class_name HardwareId

const PwmIo = preload("res://plugins/fan-manager/core/utils/pwm_io.gd")

# makes sure every FanBackend produces the same hardware_id for the same
# physical machine

const UNKNOWN := "unknown-hardware"

const DMI_PRODUCT_NAME := "/sys/class/dmi/id/product_name"
const DMI_BOARD_NAME := "/sys/class/dmi/id/board_name"


static func from_dmi() -> String:
	var logger := Log.get_logger("FanManager HardwareId")
	var product = PwmIo.read_text(DMI_PRODUCT_NAME)
	var board = PwmIo.read_text(DMI_BOARD_NAME)
	logger.debug(
		"Read DMI: %s='%s' %s='%s'"
		% [DMI_PRODUCT_NAME, product, DMI_BOARD_NAME, board]
	)

	if product.is_empty() and board.is_empty():
		logger.warn("Neither %s nor %s is readable; using '%s'" % [DMI_PRODUCT_NAME, DMI_BOARD_NAME, UNKNOWN])
		return UNKNOWN

	logger.info("Detected device: product='%s' board='%s'" % [product, board])
	return "%s-%s" % [product, board]

