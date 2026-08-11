extends GutTest

class MockBackend extends FanBackend:
	var _supported: bool
	var _hardware_id: String

	func _init(supported: bool, hardware_id: String) -> void:
		_supported = supported
		_hardware_id = hardware_id

	func is_supported() -> bool:
		return _supported

	func get_hardware_id() -> String:
		return _hardware_id


func test_detect_returns_first_supported_backend() -> void:
	var registry := FanBackendRegistry.new()
	var unsupported := MockBackend.new(false, "unsupported-device")
	var supported := MockBackend.new(true, "supported-device")

	registry.register(unsupported)
	registry.register(supported)

	var result := registry.detect()
	assert_eq(result, supported)


func test_detect_respects_registration_priority() -> void:
	var registry := FanBackendRegistry.new()
	var specific := MockBackend.new(true, "specific-device")
	var generic_fallback := MockBackend.new(true, "generic-device")

	registry.register(specific)
	registry.register(generic_fallback)

	var result := registry.detect()
	assert_eq(result, specific, "the first matching backend in registration order should win")


func test_detect_returns_null_when_no_backend_supported() -> void:
	var registry := FanBackendRegistry.new()
	registry.register(MockBackend.new(false, "device-a"))
	registry.register(MockBackend.new(false, "device-b"))

	var result := registry.detect()
	assert_null(result)


func test_get_backends_returns_registered_backends_in_order() -> void:
	var registry := FanBackendRegistry.new()
	var first := MockBackend.new(false, "a")
	var second := MockBackend.new(false, "b")

	registry.register(first)
	registry.register(second)

	var backends := registry.get_backends()
	assert_eq(backends.size(), 2)
	assert_eq(backends[0], first)
	assert_eq(backends[1], second)
