extends Plugin

## The types below are this plugin's own (FanBackendRegistry,
## FanCurveStore, FanModeManager, ModeSelectOverlay, GameCurveManager,
## AsusWmiFanBackend, HwmonFanBackend) and are referenced via
## preload()'d consts, not bare class_name lookups: OGUI loads plugins
## from a zip at runtime (ProjectSettings.load_resource_pack()), which
## never populates Godot's global class_name cache, so bare names fail
## to resolve outside the file that declares them. QuickBarCard,
## LaunchManager, and Plugin below are OGUI's own core classes,
## compiled into the base game normally, so they resolve fine as bare
## names. See tasks/17-fix-class-name-resolution-em-plugin-empacotado.md.
const FanBackendRegistry = preload("res://plugins/fan-manager/core/backends/fan_backend_registry.gd")
const FanCurveStore = preload("res://plugins/fan-manager/core/persistence/fan_curve_store.gd")
const FanModeManager = preload("res://plugins/fan-manager/core/modes/fan_mode_manager.gd")
const ModeSelectOverlay = preload("res://plugins/fan-manager/core/ui/mode_select_overlay.gd")
const GameCurveManager = preload("res://plugins/fan-manager/core/modes/game_curve_manager.gd")
const AsusWmiFanBackend = preload("res://plugins/fan-manager/core/backends/asus_wmi_fan_backend.gd")
const HwmonFanBackend = preload("res://plugins/fan-manager/core/backends/hwmon_fan_backend.gd")
const FanBackend = preload("res://plugins/fan-manager/core/backends/fan_backend.gd")

var registry: FanBackendRegistry
var store: FanCurveStore
var mode_manager: FanModeManager
var mode_select_overlay: ModeSelectOverlay
var game_curve_manager: GameCurveManager


func _ready() -> void:
	registry = FanBackendRegistry.new()
	# Register more specific/vendor backends before the generic hwmon
	# fallback (FanBackendRegistry tries them in registration order).
	registry.register(AsusWmiFanBackend.new())
	registry.register(HwmonFanBackend.new())

	store = FanCurveStore.new()
	mode_manager = FanModeManager.new(registry, store)
	add_child(mode_manager)

	mode_select_overlay = load(plugin_base + "/core/ui/mode_select_overlay.tscn").instantiate()
	mode_select_overlay.mode_manager = mode_manager
	# Registers a card in the Quick Bar menu (same menu as "Quick
	# Settings"/"Performance"): NOT add_overlay()/OverlayContainer,
	# which --overlay-mode's scene doesn't even instantiate. See
	# tasks/16-quick-bar-em-vez-de-overlay.md.
	add_to_quick_bar(mode_select_overlay, null)

	# Backend detection retries in the background (see
	# FanModeManager._ready()), so .backend may still be null here even
	# though it'll be found a moment later. GameCurveManager needs
	# mode_select_overlay.profiles_panel, which only resolves once the
	# overlay's own _ready() has run (it just did, synchronously, via
	# add_to_quick_bar() above).
	mode_manager.backend_ready.connect(_on_backend_ready)
	# If detection already resolved on its first attempt (the common
	# case), backend_ready fired synchronously during add_child(mode_manager)
	# above, before this connection existed. Catch up manually so
	# GameCurveManager still gets built in that case.
	if mode_manager.backend:
		_on_backend_ready(mode_manager.backend)


## Signal handler for FanModeManager.backend_ready. Builds
## GameCurveManager once a backend is actually found; a no-op if
## detection never found one (backend_ready still fires with null so
## callers aren't left waiting forever).
func _on_backend_ready(backend: FanBackend) -> void:
	if not backend:
		return

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

	# add_to_quick_bar() wraps mode_select_overlay inside a QuickBarCard
	# it creates itself (MarginContainer/CardVBoxContainer/
	# ContentContainer, several levels up) and never hands us a
	# reference to that wrapper. Freeing only mode_select_overlay would
	# leave an empty, otherwise-untouched card behind in the Quick Bar
	# whose FocusGroupSetter/effects still hold direct references into
	# the subtree we just freed (crashes the next time the Quick Bar
	# touches it, e.g. on close/focus-change). Walk up and free the
	# whole card instead so nothing is left dangling.
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
