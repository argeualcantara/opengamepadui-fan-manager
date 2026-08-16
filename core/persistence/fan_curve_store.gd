extends RefCounted
class_name FanCurveStore

# saves fan mode/curve config per hardware, one json file under
# user://data/fan-manager/. kept in memory once loaded (load_data()),
# callers mutate it with the set_*() below then call flush() when done.
#
# schema:
# {
#   "hardware_id": "...",
#   "active_mode": "bios" | "custom",
#   "per_game_enabled": <bool>,
#   "active_game_context": "<context key>",
#   "game_curves": {
#     "<context key>": {
#       "mode": "bios" | "custom",
#       "curve": { "<fan_id>": { "<temp>": <percent>, ... }, ... }
#     }, ...
#   }
# }
# context key is "__default__" (per-game off, or nothing seen yet),
# "__steam_home__" (nothing running), or the app's name lowercased.

const DATA_DIR := "user://data/fan-manager"

var logger := Log.get_logger("FanManager FanCurveStore")

# same dictionary instance shared by everyone who calls load_data() for this
# hardware_id, so mutating it is visible everywhere without touching disk.
# only flush() actually writes.
var _data: Dictionary = {}
var _hardware_id: String = ""

# jobs queued with enqueue(), run when flush() drains them - so a job that
# reads some other object's live state (like an engine's current curve)
# always sees it as it stands at the end, not mid-operation.
var _jobs: Array[Callable] = []
var _draining := false


func exists(hardware_id: String) -> bool:
	var path = _path_for(hardware_id)
	var result := FileAccess.file_exists(path)
	logger.debug("exists('%s') -> %s" % [hardware_id, result])
	return result


func load_data(hardware_id: String) -> Dictionary:
	if _hardware_id == hardware_id and not _data.is_empty():
		return _data

	_hardware_id = hardware_id
	_data = _read_from_disk(hardware_id)
	return _data


func _read_from_disk(hardware_id: String) -> Dictionary:
	var path := _path_for(hardware_id)

	var file_exists = FileAccess.file_exists(path)
	if not file_exists:
		logger.debug("load_data('%s'): %s doesn't exist yet, returning defaults" % [hardware_id, path])
		return _default_data(hardware_id)

	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		logger.error("Unable to open %s for reading" % path)
		return _default_data(hardware_id)

	var raw_text := file.get_as_text()
	var parsed: Variant = JSON.parse_string(raw_text)
	if typeof(parsed) != TYPE_DICTIONARY:
		logger.error("Corrupt fan curve data at %s, falling back to defaults" % path)
		return _default_data(hardware_id)

	logger.debug("load_data('%s') <- %s" % [hardware_id, path])
	return parsed as Dictionary


# writes atomically (temp file + rename) so a crash mid-write can't leave a
# corrupt file
func save(hardware_id: String, data: Dictionary) -> bool:
	_hardware_id = hardware_id
	_data = data

	var path := _path_for(hardware_id)
	var dir_path := path.get_base_dir()
	logger.debug("save('%s') -> %s: keys=%s" % [hardware_id, path, data.keys()])

	var mkdir_err := DirAccess.make_dir_recursive_absolute(dir_path)
	if mkdir_err != OK and mkdir_err != ERR_ALREADY_EXISTS:
		logger.error("Unable to create directory %s (error %d)" % [dir_path, mkdir_err])
		return false

	var tmp_path := path + ".tmp"
	var file := FileAccess.open(tmp_path, FileAccess.WRITE)
	if not file:
		logger.error("Unable to open %s for writing" % tmp_path)
		return false

	var json_text = JSON.stringify(data, "\t")
	file.store_string(json_text)
	file = null  # close it before renaming

	var rename_err := DirAccess.rename_absolute(tmp_path, path)
	if rename_err != OK:
		logger.error("Unable to rename %s -> %s (error %d)" % [tmp_path, path, rename_err])
		return false

	logger.debug("save('%s'): wrote %s -> %s" % [hardware_id, tmp_path, path])
	logger.info("Saved fan curve data for hardware '%s'" % hardware_id)
	return true


# --- in-memory mutators, no disk I/O. caller needs to have called
# load_data() first, then flush() when they're actually done. ---

func set_active_mode(mode: String) -> void:
	_data["active_mode"] = mode


func set_per_game_enabled(value: bool) -> void:
	_data["per_game_enabled"] = value

func get_per_game_enabled() -> bool:
	return _data.get("per_game_enabled", false)

func set_active_game_context(context_key: String) -> void:
	_data["active_game_context"] = context_key


func set_game_curve(context_key: String, mode: String, curve: Dictionary) -> void:
	var game_curves: Dictionary = _data.get("game_curves", {})
	game_curves[context_key] = {"mode": mode, "curve": curve}
	_data["game_curves"] = game_curves


func enqueue(job: Callable) -> void:
	_jobs.append(job)


# runs every queued job then writes to disk once. call this exactly once at
# the end of whatever you're doing, not in the middle - otherwise a job
# queued earlier in the same operation would get read too soon.
func flush() -> bool:
	if _draining:
		return false
	_draining = true
	while not _jobs.is_empty():
		var job: Callable = _jobs.pop_front()
		job.call()
	_draining = false
	return save(_hardware_id, _data)


func _default_data(hardware_id: String) -> Dictionary:
	return {
		"hardware_id": hardware_id,
		"active_mode": "bios",
	}


func _path_for(hardware_id: String) -> String:
	return "%s/%s.json" % [DATA_DIR, _sanitize_id(hardware_id)]


# hardware_id comes from stuff like DMI product/board names, can have
# spaces/slashes/whatever, not safe as a filename. strip anything not
# alphanumeric/underscore/dash.
func _sanitize_id(hardware_id: String) -> String:
	var sanitized := ""
	var allowed := "abcdefghijklmnopqrstuvwxyz0123456789_-"
	for i in hardware_id.length():
		var c := hardware_id[i]
		var c_lower = c.to_lower()
		if allowed.contains(c_lower):
			sanitized += c
		else:
			sanitized += "_"

	if sanitized.is_empty():
		return "unknown"
	return sanitized
