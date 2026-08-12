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

var registry: FanBackendRegistry
var store: FanCurveStore
var mode_manager: FanModeManager
var mode_select_overlay: ModeSelectOverlay
var game_curve_manager: GameCurveManager

## Bounded retries for the Quick Bar Menu to exist: OGUI's
## PluginLoader.init() is called from CardUiOverlayMode._init(), which
## runs before that scene (and its QuickBarMenu child, the sole member
## of the "quick-bar" group Plugin.add_to_quick_bar() looks up) has
## entered the tree — plugin_manager is add_child()'d during that
## _init(), landing at a lower sibling index than QuickBarMenu, so its
## whole ready-cascade (including this plugin) runs before QuickBarMenu
## even enters the tree. add_to_quick_bar() has no retry of its own —
## it just silently no-ops if the group is empty — so without this
## wait, the card is never added at all. Total worst-case wait: ~2s.
const QUICK_BAR_WAIT_RETRIES := 20
const QUICK_BAR_WAIT_DELAY := 0.1


func _ready() -> void:
	print("FAN-MANAGER DEBUG: _ready() start, is_inside_tree=%s, ticks=%d" % [is_inside_tree(), Time.get_ticks_msec()])

	registry = FanBackendRegistry.new()
	# Register more specific/vendor backends before the generic hwmon
	# fallback (FanBackendRegistry tries them in registration order).
	registry.register(AsusWmiFanBackend.new())
	registry.register(HwmonFanBackend.new())

	store = FanCurveStore.new()
	mode_manager = FanModeManager.new(registry, store)
	add_child(mode_manager)
	print("FAN-MANAGER DEBUG: FanModeManager ready, backend=%s" % (mode_manager.backend.get_script().get_global_name() if mode_manager.backend else "null"))

	mode_select_overlay = load(plugin_base + "/core/ui/mode_select_overlay.tscn").instantiate()
	mode_select_overlay.mode_manager = mode_manager

	print("FAN-MANAGER DEBUG: about to wait for quick-bar, ticks=%d" % Time.get_ticks_msec())
	await _wait_for_quick_bar_menu()
	# Registers a card in the Quick Bar menu (same menu as "Quick
	# Settings"/"Performance"): NOT add_overlay()/OverlayContainer,
	# which --overlay-mode's scene doesn't even instantiate. See
	# tasks/16-quick-bar-em-vez-de-overlay.md.
	print("FAN-MANAGER DEBUG: calling add_to_quick_bar(), ticks=%d" % Time.get_ticks_msec())
	add_to_quick_bar(mode_select_overlay, null)
	print("FAN-MANAGER DEBUG: add_to_quick_bar() returned, overlay in tree=%s" % mode_select_overlay.is_inside_tree())

	# GameCurveManager needs mode_select_overlay.profiles_panel, which
	# only resolves once the overlay's own _ready() has run (it just
	# did, synchronously, via add_to_quick_bar() above): can't be built
	# any earlier. Skipped entirely if no backend was detected, same
	# guard the overlay itself uses.
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

	print("FAN-MANAGER DEBUG: _ready() complete")


## Polls until a node in the "quick-bar" group exists (or retries run
## out, logged and left for add_to_quick_bar() to fail its own way).
func _wait_for_quick_bar_menu() -> void:
	print("FAN-MANAGER DEBUG: _wait_for_quick_bar_menu() start")
	for attempt in range(QUICK_BAR_WAIT_RETRIES):
		if get_tree().get_first_node_in_group("quick-bar"):
			print("FAN-MANAGER DEBUG: quick-bar found after %d attempt(s)" % (attempt + 1))
			return
		if attempt < QUICK_BAR_WAIT_RETRIES - 1:
			await get_tree().create_timer(QUICK_BAR_WAIT_DELAY).timeout
	print("FAN-MANAGER DEBUG: quick-bar NOT found after %d attempts" % QUICK_BAR_WAIT_RETRIES)


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
