extends Plugin

## The types below are this plugin's own (FanBackendRegistry,
## FanCurveStore, FanModeManager, ModeSelectOverlay, GameCurveManager,
## AsusWmiFanBackend, HwmonFanBackend) and are referenced via
## preload()'d consts, not bare class_name lookups: OGUI loads plugins
## from a zip at runtime (ProjectSettings.load_resource_pack()), which
## never populates Godot's global class_name cache, so bare names fail
## to resolve outside the file that declares them. QuickBarCard,
## LaunchManager, and Plugin below are OGUI's own core classes,
## compiled into the base game normally, so they resolve fine as bare names.
const FanBackendRegistry = preload("res://plugins/fan-manager/core/backends/fan_backend_registry.gd")
const FanCurveStore = preload("res://plugins/fan-manager/core/persistence/fan_curve_store.gd")
const FanModeManager = preload("res://plugins/fan-manager/core/modes/fan_mode_manager.gd")
const ModeSelectOverlay = preload("res://plugins/fan-manager/core/ui/mode_select_overlay.gd")
const GameCurveManager = preload("res://plugins/fan-manager/core/modes/game_curve_manager.gd")
const AsusWmiFanBackend = preload("res://plugins/fan-manager/core/backends/asus_wmi_fan_backend.gd")
const HwmonFanBackend = preload("res://plugins/fan-manager/core/backends/hwmon_fan_backend.gd")

var registry: FanBackendRegistry
var store: FanCurveStore
var mode_manager: FanModeManager
var mode_select_overlay: ModeSelectOverlay
var game_curve_manager: GameCurveManager


func _ready() -> void:
	registry = FanBackendRegistry.new()
	# Vendor-specific backends first; registry.detect() tries them in order.
	registry.register(AsusWmiFanBackend.new())
	registry.register(HwmonFanBackend.new())

	store = FanCurveStore.new()
	mode_manager = FanModeManager.new(registry, store)
	add_child(mode_manager)

	mode_select_overlay = load(plugin_base + "/core/ui/mode_select_overlay.tscn").instantiate()
	mode_select_overlay.mode_manager = mode_manager
	# Adds a Quick Bar card, not add_overlay()
	add_to_quick_bar(mode_select_overlay, null)

	# profiles_panel only resolves once add_to_quick_bar() above has run
	# the overlay's _ready(). Skipped if no backend was detected.
	if mode_manager.backend:
		var launch_manager := load("res://core/global/launch_manager.tres") as LaunchManager
		game_curve_manager = GameCurveManager.new(
			launch_manager,
			store,
			mode_manager,
			mode_select_overlay.profiles_panel,
			mode_manager.hardware_id
		)
		add_child(game_curve_manager)
		mode_select_overlay.bind_game_curve_manager(game_curve_manager)


func get_settings_menu() -> Control:
	return load(plugin_base + "/core/settings_menu.tscn").instantiate()


func unload() -> void:
	if game_curve_manager:
		game_curve_manager.queue_free()
	if mode_manager:
		mode_manager.queue_free()

	if not mode_select_overlay:
		return

	# Free the whole QuickBarCard add_to_quick_bar() wrapped us in, not
	# just mode_select_overlay, otherwise an empty card is left behind
	# whose FocusGroupSetter still references the freed subtree.
	var card := _find_ancestor_of_type(mode_select_overlay, QuickBarCard)
	if card:
		card.queue_free()
	else:
		mode_select_overlay.queue_free()


func _find_ancestor_of_type(node: Node, type: Variant) -> Node:
	var current := node.get_parent()
	while current:
		if is_instance_of(current, type):
			return current
		current = current.get_parent()
	return null
