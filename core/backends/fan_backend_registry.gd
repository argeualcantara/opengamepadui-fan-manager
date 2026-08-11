extends RefCounted
class_name FanBackendRegistry

## Selects the [FanBackend] for the current hardware: tries backends
## in registration order, returns the first whose is_supported() is
## true.
##
## Referenced via preload()'d consts, not bare class_name lookups: see
## hwmon_fan_backend.gd's header comment for why.
const FanBackend = preload("res://plugins/fan-manager/core/backends/fan_backend.gd")
const HardwareId = preload("res://plugins/fan-manager/core/backends/hardware_id.gd")

var logger := Log.get_logger("FanManager FanBackendRegistry", Log.LEVEL.DEBUG)

var _backends: Array[FanBackend] = []


## Registers a backend. Order matters: register more specific/vendor
## backends before generic fallbacks.
func register(backend: FanBackend) -> void:
	_backends.append(backend)
	logger.debug(
		"Registered backend '%s' (priority %d)"
		% [backend.get_script().get_global_name(), _backends.size() - 1]
	)


## Returns the registered backends, in registration/priority order.
func get_backends() -> Array[FanBackend]:
	return _backends


## Returns the first supported backend, or null if none recognize the
## current hardware.
func detect() -> FanBackend:
	var hardware_id := HardwareId.from_dmi()
	logger.info(
		"Detected hardware '%s'; probing %d registered backend(s)"
		% [hardware_id, _backends.size()]
	)

	for backend in _backends:
		var backend_name: String = backend.get_script().get_global_name()
		var supported := backend.is_supported()
		logger.debug("Probed backend '%s': is_supported=%s" % [backend_name, supported])
		if supported:
			logger.info(
				"Selected fan backend '{0}' for hardware '{1}'".format(
					[backend_name, hardware_id]
				)
			)
			return backend

	logger.warn("No registered fan backend supports hardware '%s'" % hardware_id)
	return null
