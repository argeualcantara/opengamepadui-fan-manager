extends RefCounted
class_name FanCurveStore

## Persists fan mode/curve configuration per hardware.
##
## One JSON file per hardware_id under user://data/fan-manager/. See
## REQUIREMENTS.md §3 for the document schema:
## {
##   "hardware_id": "...",
##   "active_mode": "bios" | "custom",
##   "active_profile": "<name>" | null,
##   "profiles": { "<name>": { "<temp>": <percent>, ... }, ... }
## }

const DATA_DIR := "user://data/fan-manager"

var logger := Log.get_logger("FanCurveStore")


## Returns true if a document has already been saved for this hardware
##: used to distinguish "genuinely first run" (nothing chosen yet,
## adopt whatever the hardware is already doing) from "we have a saved
## active_mode to reapply."
func exists(hardware_id: String) -> bool:
	return FileAccess.file_exists(_path_for(hardware_id))


## Loads the persisted document for the given hardware. Returns a fresh
## default document (not yet written to disk) if none exists yet, or if
## the file on disk is missing/corrupt.
func load_data(hardware_id: String) -> Dictionary:
	var path := _path_for(hardware_id)

	if not FileAccess.file_exists(path):
		return _default_data(hardware_id)

	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		logger.error("Unable to open %s for reading" % path)
		return _default_data(hardware_id)

	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		logger.error("Corrupt fan curve data at %s, falling back to defaults" % path)
		return _default_data(hardware_id)

	return parsed as Dictionary


## Writes the given document for the given hardware, atomically (write
## to a temp file, then rename over the target) so a crash mid-write
## can't leave a corrupt/truncated JSON file behind.
func save(hardware_id: String, data: Dictionary) -> bool:
	var path := _path_for(hardware_id)
	var dir_path := path.get_base_dir()

	var mkdir_err := DirAccess.make_dir_recursive_absolute(dir_path)
	if mkdir_err != OK and mkdir_err != ERR_ALREADY_EXISTS:
		logger.error("Unable to create directory %s (error %d)" % [dir_path, mkdir_err])
		return false

	var tmp_path := path + ".tmp"
	var file := FileAccess.open(tmp_path, FileAccess.WRITE)
	if not file:
		logger.error("Unable to open %s for writing" % tmp_path)
		return false

	file.store_string(JSON.stringify(data, "\t"))
	file = null  # close/flush before renaming, so the rename is atomic-safe

	var rename_err := DirAccess.rename_absolute(tmp_path, path)
	if rename_err != OK:
		logger.error("Unable to rename %s -> %s (error %d)" % [tmp_path, path, rename_err])
		return false

	logger.info("Saved fan curve data for hardware '%s'" % hardware_id)
	return true


## Saves (creating or overwriting) a named custom curve profile for the
## given hardware. Does not change active_mode/active_profile: see
## FanModeManager (activity 04) for switching to the saved profile.
func save_profile(hardware_id: String, name: String, curve: Dictionary) -> bool:
	if name.is_empty():
		logger.error("Cannot save a profile with an empty name")
		return false

	# load_data(), not load(): a bare call resolves to the Godot global
	# load() (loads a Resource from a path) instead of this class's own
	# method of the same name, since this method's name shadows the
	# global one. That silently mistypes `data` as Resource instead of
	# Dictionary, which then fails static type-checking on every use
	# below it: only surfaces once the whole plugin actually compiles
	# (see tasks/17), so it went unnoticed until now.
	var data := load_data(hardware_id)
	var profiles: Dictionary = data.get("profiles")
	if profiles == null:
		profiles = {}

	profiles[name] = curve
	data["profiles"] = profiles

	var saved := save(hardware_id, data)
	if saved:
		logger.info("Saved profile '%s' for hardware '%s'" % [name, hardware_id])
	return saved


## Deletes a named profile. If it was the active profile, active_profile
## is cleared (set to null) so the caller isn't left pointing at a
## profile that no longer exists.
func delete_profile(hardware_id: String, name: String) -> bool:
	var data := load_data(hardware_id)
	var profiles: Dictionary = data.get("profiles")

	if profiles == null:
		profiles = {}

	if not profiles.has(name):
		logger.warn("Cannot delete profile '%s': not found for hardware '%s'" % [name, hardware_id])
		return false

	profiles.erase(name)
	data["profiles"] = profiles
	if data.get("active_profile") == name:
		data["active_profile"] = null

	var saved := save(hardware_id, data)
	if saved:
		logger.info("Deleted profile '%s' for hardware '%s'" % [name, hardware_id])
	return saved


## Returns the names of all saved profiles for the given hardware.
func list_profiles(hardware_id: String) -> Array[String]:
	var data := load_data(hardware_id)
	var profiles: Dictionary = data.get("profiles")

	if profiles == null:
		profiles = {}


	var names: Array[String] = []
	for profile_name in profiles.keys():
		names.append(profile_name)
	return names


func _default_data(hardware_id: String) -> Dictionary:
	return {
		"hardware_id": hardware_id,
		"active_mode": "bios",
		"active_profile": null,
		"profiles": {},
	}


func _path_for(hardware_id: String) -> String:
	return "%s/%s.json" % [DATA_DIR, _sanitize_id(hardware_id)]


## hardware_id values are derived from free-form hardware strings (e.g.
## DMI product/board names) and may contain spaces, slashes, or other
## characters unsafe for a filename. Anything outside [A-Za-z0-9_-] is
## replaced with "_".
func _sanitize_id(hardware_id: String) -> String:
	var sanitized := ""
	var allowed := "abcdefghijklmnopqrstuvwxyz0123456789_-"
	for i in hardware_id.length():
		var c := hardware_id[i]
		if allowed.contains(c.to_lower()):
			sanitized += c
		else:
			sanitized += "_"

	if sanitized.is_empty():
		return "unknown"
	return sanitized
