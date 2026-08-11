extends RefCounted
class_name FanBackendRegistry

## Selects the appropriate [FanBackend] for the current hardware.
##
## Backends are tried in registration order (most specific hardware
## first, generic fallbacks last). The first backend whose
## [method FanBackend.is_supported] returns true is used.
##
## FanBackend is referenced below via a preload()'d const, not a bare
## class_name lookup: see hwmon_fan_backend.gd's header comment for why.
const FanBackend = preload("res://plugins/fan-manager/core/backends/fan_backend.gd")

var logger := Log.get_logger("FanBackendRegistry")

var _backends: Array[FanBackend] = []


## Registers a backend. Order matters: register more specific/vendor
## backends before generic fallbacks.
func register(backend: FanBackend) -> void:
	_backends.append(backend)


## Returns the registered backends, in registration/priority order.
func get_backends() -> Array[FanBackend]:
	return _backends


## Detects and returns the first supported backend, or null if no
## registered backend recognizes the current hardware.
func detect() -> FanBackend:
	for backend in _backends:
		if backend.is_supported():
			logger.info(
				"Selected fan backend '{0}' for hardware '{1}'".format(
					[backend.get_script().get_global_name(), backend.get_hardware_id()]
				)
			)
			return backend

	logger.warn("No registered fan backend supports this hardware")
	return null
