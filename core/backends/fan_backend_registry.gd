extends RefCounted
class_name FanBackendRegistry

## Selects the appropriate [FanBackend] for the current hardware.
##
## Backends are tried in registration order (most specific hardware
## first, generic fallbacks last). The first backend whose
## [method FanBackend.is_supported] returns true is used.
##
## FanBackend/HardwareId are referenced below via preload()'d consts,
## not bare class_name lookups: see hwmon_fan_backend.gd's header
## comment for why.
const FanBackend = preload("res://plugins/fan-manager/core/backends/fan_backend.gd")
const HardwareId = preload("res://plugins/fan-manager/core/backends/hardware_id.gd")

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
## registered backend recognizes the current hardware. Identifies the
## hardware (DMI) once, up front, before probing any backend: purely a
## diagnostic/ordering change (every backend already derives the same
## id from HardwareId.from_dmi() internally for get_hardware_id()) —
## which backend gets picked is still decided entirely by
## is_supported(), tried in registration order.
func detect() -> FanBackend:
	var hardware_id := HardwareId.from_dmi()
	logger.info("Detected hardware '%s'; probing registered backends" % hardware_id)

	for backend in _backends:
		if backend.is_supported():
			logger.info(
				"Selected fan backend '{0}' for hardware '{1}'".format(
					[backend.get_script().get_global_name(), hardware_id]
				)
			)
			return backend

	logger.warn("No registered fan backend supports hardware '%s'" % hardware_id)
	return null
