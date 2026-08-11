extends Node
class_name FanModeManager

## Orchestrates switching between BIOS, OS, and Custom fan modes
## (REQUIREMENTS.md §2.2, §2.4): detects the active FanBackend, cleanly
## stops whatever the previous mode was doing before applying the new
## one, persists the active mode, and reapplies it automatically on
## startup so the user never has to reconfigure after a restart.
##
## FanBackendRegistry/FanCurveStore/CustomCurveEngine/FanBackend/
## FanCurveUtils below are referenced via preload()'d consts, not bare
## class_name lookups (see hwmon_fan_backend.gd's header comment /
## tasks/17-fix-class-name-resolution-em-plugin-empacotado.md).
const FanBackendRegistry = preload("res://plugins/fan-manager/core/backends/fan_backend_registry.gd")
const FanCurveStore = preload("res://plugins/fan-manager/core/persistence/fan_curve_store.gd")
const CustomCurveEngine = preload("res://plugins/fan-manager/core/engine/custom_curve_engine.gd")
const FanBackend = preload("res://plugins/fan-manager/core/backends/fan_backend.gd")
const FanCurveUtils = preload("res://plugins/fan-manager/core/persistence/fan_curve_utils.gd")

signal mode_changed(mode: String)

const VALID_MODES := ["bios", "custom"]

var logger := Log.get_logger("FanModeManager")

var registry: FanBackendRegistry
var store: FanCurveStore

## One CustomCurveEngine per fan_id, created lazily as fans are
## discovered: a fixed count isn't known until the backend is
## detected, so it can't be injected up front like the old single
## engine was (tasks/14-suporte-multiplas-fans.md).
var curve_engines: Dictionary = {}

var backend: FanBackend
var hardware_id: String = ""
var current_mode: String = ""


func _init(p_registry: FanBackendRegistry, p_store: FanCurveStore) -> void:
	registry = p_registry
	store = p_store


func _ready() -> void:
	backend = registry.detect()
	if not backend:
		logger.warn("No fan backend available; fan mode management disabled")
		return

	hardware_id = backend.get_hardware_id()

	if not store.exists(hardware_id):
		# Genuinely first run for this hardware: nothing to reapply, so
		# don't write pwm1_enable at all. Adopt whatever the hardware is
		# already doing instead of imposing an assumed default.
		_adopt_current_hardware_mode()
		return

	var data: Dictionary = store.load_data(hardware_id)
	var saved_mode: String = data.get("active_mode", "bios")

	if not set_mode(saved_mode):
		logger.warn(
			"Failed to reapply saved mode '%s' on startup, falling back to bios" % saved_mode
		)
		set_mode("bios")


func _adopt_current_hardware_mode() -> void:
	var detected := backend.get_current_mode()
	if detected not in VALID_MODES:
		detected = "bios"

	current_mode = detected
	_persist_active_mode(detected)

	# Deliberately NOT _start_custom_mode() here: that path creates the
	# built-in "Default" profile when none is set, which would
	# overwrite whatever curve the hardware already had: exactly what
	# this whole method exists to avoid. If the hardware was somehow
	# already in custom mode before the plugin ever ran, read back
	# whatever curve is actually active instead.
	if detected == "custom":
		_adopt_current_custom_curve()

	mode_changed.emit(detected)
	logger.info(
		"First run for hardware '%s': adopted current mode '%s' without writing pwm1_enable"
		% [hardware_id, detected]
	)


## Switches to the given mode ("bios" or "custom"), cleanly stopping
## the previous mode's activity first. Persists the new mode on
## success. Returns false (and logs) if the mode is invalid or the
## switch fails.
func set_mode(mode: String) -> bool:
	if not backend:
		logger.error("Cannot set mode '%s': no fan backend available" % mode)
		return false

	if mode not in VALID_MODES:
		logger.error("Unknown fan mode '%s'" % mode)
		return false

	var previous_mode := current_mode if not current_mode.is_empty() else "(none)"

	# Stop whatever the previous mode was doing before touching the
	# backend, so no state (e.g. custom-curve polling) leaks across
	# the switch regardless of which mode we're leaving/entering.
	for engine in curve_engines.values():
		engine.stop()

	if not backend.set_mode(mode):
		logger.error("Backend failed to switch to mode '%s'" % mode)
		return false

	if mode == "custom":
		_start_custom_mode()

	current_mode = mode
	_persist_active_mode(mode)
	mode_changed.emit(mode)
	logger.info("Switched fan mode from '%s' to '%s'" % [previous_mode, mode])
	return true


func get_curve_engine(fan_id: String) -> CustomCurveEngine:
	return curve_engines.get(fan_id)


func get_all_curve_engines() -> Dictionary:
	return curve_engines


func _ensure_curve_engine(fan_id: String) -> CustomCurveEngine:
	if curve_engines.has(fan_id):
		return curve_engines[fan_id]

	var engine := CustomCurveEngine.new()
	add_child(engine)
	curve_engines[fan_id] = engine
	return engine


## Applies a curve to every fan reported by the backend. A saved
## profile bundles one curve per fan_id (tasks/14); each engine gets
## only its own slice, kept fully independent of the others.
func _start_custom_mode() -> void:
	var fans := backend.list_fans()
	if fans.is_empty():
		logger.error("Cannot start custom mode: no fans available")
		return

	var data: Dictionary = store.load_data(hardware_id)
	var active_profile = data.get("active_profile")
	var profiles: Dictionary = data.get("profiles")
	if profiles == null:
		profiles = {}

	var profile_curves: Dictionary = {}
	var profile_name := ""

	if active_profile != null and profiles.has(active_profile):
		# Saved profiles are always already aligned to the UI's fixed
		# 10-point grid: they were created by that same editor in the
		# first place.
		profile_curves = profiles[active_profile]
		profile_name = active_profile
	elif profiles.has(FanCurveUtils.DEFAULT_PROFILE_NAME):
		profile_curves = profiles[FanCurveUtils.DEFAULT_PROFILE_NAME]
		profile_name = FanCurveUtils.DEFAULT_PROFILE_NAME
		_persist_active_profile(profile_name)
		logger.info(
			"No active profile set; falling back to '%s' for hardware '%s'"
			% [profile_name, hardware_id]
		)
	else:
		# First time ever entering Custom Mode on this hardware with no
		# profiles at all: create the built-in balanced default,
		# applied identically to every fan, as a real, visible, editable
		# profile (not just an ephemeral in-memory curve).
		for fan_id in fans:
			profile_curves[fan_id] = FanCurveUtils.DEFAULT_BALANCED_CURVE.duplicate()
		profile_name = FanCurveUtils.DEFAULT_PROFILE_NAME
		store.save_profile(hardware_id, profile_name, profile_curves)
		_persist_active_profile(profile_name)
		logger.info(
			"Created built-in '%s' profile for hardware '%s'" % [profile_name, hardware_id]
		)

	if active_profile != null and profiles.has(active_profile):
		logger.info("Applied profile '%s' for hardware '%s'" % [profile_name, hardware_id])

	for fan_id in fans:
		var engine := _ensure_curve_engine(fan_id)

		# Re-entering Custom Mode after switching away: reuse whatever
		# is already in memory instead of reloading from disk, so
		# unsaved edits survive a round trip through another mode
		# (REQUIREMENTS.md §2.3 / tasks/07 acceptance criteria).
		var curve: Dictionary = engine.get_curve()
		if curve.is_empty():
			curve = profile_curves.get(fan_id, FanCurveUtils.DEFAULT_BALANCED_CURVE.duplicate())

		# The engine is always the source of truth for the working
		# curve (the UI editor reads/writes through it): whether it
		# also polls continuously depends on
		# backend.requires_software_polling(), and that decision lives
		# inside CustomCurveEngine.start() itself.
		engine.start(backend, fan_id, curve)


## Only used by _adopt_current_hardware_mode() for the rare case the
## hardware was already in custom mode before the plugin ever ran.
## Reads back whatever curve is actually active per fan: does NOT
## create/use the "Default" profile (that's for a deliberate switch
## into Custom Mode, see _start_custom_mode()), so it doesn't overwrite
## it with an assumption. Note this still writes the curve-point
## registers back (an approximation of what's already there, since it
## round-trips through resampling): it just never touches pwm_enable.
func _adopt_current_custom_curve() -> void:
	var fans := backend.list_fans()
	if fans.is_empty():
		return

	for fan_id in fans:
		var curve := FanCurveUtils.resample_to_fixed_points(backend.get_bios_curve(fan_id))
		var engine := _ensure_curve_engine(fan_id)
		engine.start(backend, fan_id, curve)


func _persist_active_mode(mode: String) -> void:
	var data: Dictionary = store.load_data(hardware_id)
	data["active_mode"] = mode
	store.save(hardware_id, data)


func _persist_active_profile(profile_name: String) -> void:
	var data: Dictionary = store.load_data(hardware_id)
	data["active_profile"] = profile_name
	store.save(hardware_id, data)
