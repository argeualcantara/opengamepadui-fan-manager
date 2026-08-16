extends Plugin

const FanBackendRegistry = preload("res://plugins/fan-manager/core/backends/fan_backend_registry.gd")
const FanCurveStore = preload("res://plugins/fan-manager/core/persistence/fan_curve_store.gd")
const FanModeManager = preload("res://plugins/fan-manager/core/modes/fan_mode_manager.gd")
const ModeSelectOverlay = preload("res://plugins/fan-manager/core/ui/mode_select_overlay.gd")
const GameCurveManager = preload("res://plugins/fan-manager/core/modes/game_curve_manager.gd")
const AsusWmiFanBackend = preload("res://plugins/fan-manager/core/backends/asus_wmi_fan_backend.gd")
const HwmonFanBackend = preload("res://plugins/fan-manager/core/backends/hwmon_fan_backend.gd")
const HardwareWriteQueue = preload("res://plugins/fan-manager/core/utils/hardware_write_queue.gd")

var registry: FanBackendRegistry
var store: FanCurveStore
var mode_manager: FanModeManager
var mode_select_overlay: ModeSelectOverlay
var game_curve_manager: GameCurveManager
var write_queue: HardwareWriteQueue


func _ready() -> void:
	write_queue = HardwareWriteQueue.new()

	registry = FanBackendRegistry.new()
	# vendor backends first, detect() tries them in this order
	registry.register(AsusWmiFanBackend.new())
	registry.register(HwmonFanBackend.new())

	store = FanCurveStore.new()
	mode_manager = FanModeManager.new(registry, store, write_queue)
	add_child(mode_manager)

	var overlay_scene = load(plugin_base + "/core/ui/mode_select_overlay.tscn")
	mode_select_overlay = overlay_scene.instantiate()
	mode_select_overlay.mode_manager = mode_manager
	add_to_quick_bar(mode_select_overlay, null)

	# skipped if no backend was detected
	if mode_manager.backend:
		var launch_manager := load("res://core/global/launch_manager.tres") as LaunchManager
		game_curve_manager = GameCurveManager.new(
			launch_manager,
			store,
			mode_manager,
			mode_manager.hardware_id
		)
		add_child(game_curve_manager)
		mode_select_overlay.bind_game_curve_manager(game_curve_manager)

		# GameCurveManager._ready() (already ran via add_child above) might
		# have loaded a per-game curve and fired curve_applied before we
		# connected to it just now, so force a resync here just in case
		mode_select_overlay._on_curve_applied()

		var data: Dictionary = store.load_data(mode_manager.hardware_id)
		logger.debug("full saved config on plugin load: %s" % JSON.stringify(data, "\t"))


func get_settings_menu() -> Control:
	var settings_scene = load(plugin_base + "/core/settings_menu.tscn")
	return settings_scene.instantiate()


func unload() -> void:
	if write_queue:
		write_queue.shutdown()

	if game_curve_manager:
		game_curve_manager.queue_free()
	if mode_manager:
		mode_manager.queue_free()

	if not mode_select_overlay:
		return

	# free the whole QuickBarCard, not just the overlay, otherwise an empty
	# card is left behind pointing at the freed subtree
	var card := _find_ancestor_of_type(mode_select_overlay, QuickBarCard)
	if card:
		card.queue_free()
	else:
		mode_select_overlay.queue_free()


func _find_ancestor_of_type(node: Node, type: Variant) -> Node:
	var current := node.get_parent()
	while current:
		var is_match = is_instance_of(current, type)
		if is_match:
			return current
		current = current.get_parent()
	return null
