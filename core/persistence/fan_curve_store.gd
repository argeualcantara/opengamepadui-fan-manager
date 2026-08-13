extends RefCounted
class_name FanCurveStore

## Persists fan mode/curve configuration per hardware.
##
## One JSON file per hardware_id under user://data/fan-manager/, held
## in memory as a single shared document once loaded (see load_data()).
## Callers (FanModeManager, ProfileManagerPanel, GameCurveManager)
## mutate it via the set_*() methods below, then call flush() once
## their own top-level operation is done — see enqueue()/flush()'s doc
## comments for why a mutation that needs to read some other object's
## live state should go through enqueue() instead of a plain set_*()
## call. Full schema:
## {
##   "hardware_id": "...",
##   "active_mode": "bios" | "custom",
##   "active_profile": "<name>" | null,
##   "profiles": {
##     "<name>": { "<fan_id>": { "<temp>": <percent>, ... }, ... }, ...
##   },
##   # Written by GameCurveManager. active_game_context is persisted on
##   # every app switch regardless of the toggle below; per_game_enabled
##   # only once it's been changed; game_curves only while the toggle is on:
##   "per_game_enabled": <bool>,
##   "active_game_context": "<context key>",
##   "game_curves": {
##     "<context key>": {
##       "mode": "bios" | "custom",
##       "active_profile": "<name>" | null,
##       "curve": { "<fan_id>": { "<temp>": <percent>, ... }, ... }
##     }, ...
##   }
## }
## <context key> is either "__steam_home__" (STEAM_HOME_KEY in
## GameCurveManager, nothing running) or the running app's launch item
## name, lowercased.

const DATA_DIR := "user://data/fan-manager"

var logger := Log.get_logger("FanManager FanCurveStore")

## In-memory copy of the document for the last hardware_id passed to
## load_data(): every call site now shares this same Dictionary
## instance (Dictionary is a reference type in GDScript), so a mutator
## call below is visible to every other holder immediately, without a
## disk round-trip. Only flush() actually touches disk.
var _data: Dictionary = {}
var _hardware_id: String = ""

## Mutations queued via enqueue(), drained by flush(). A queued
## Callable is not run until flush() calls it — so a job that reads
## "live" state (e.g. a CustomCurveEngine's current curve) always sees
## whatever that state has settled to by the time flush() actually
## runs, never a mid-transaction snapshot of it. See flush()'s doc
## comment for why this matters.
var _jobs: Array[Callable] = []
var _draining := false


## Returns true if a document has already been saved for hardware_id
## (vs. a genuinely first run).
func exists(hardware_id: String) -> bool:
	var result := FileAccess.file_exists(_path_for(hardware_id))
	logger.debug("exists('%s') -> %s" % [hardware_id, result])
	return result


## Returns the in-memory document for hardware_id, loading it from
## disk (or a fresh default) the first time it's requested. Every
## caller gets the same shared Dictionary instance: mutating it (or
## calling one of the set_*() mutators below) is immediately visible
## to every other caller, with no disk I/O until flush().
func load_data(hardware_id: String) -> Dictionary:
	if _hardware_id == hardware_id and not _data.is_empty():
		return _data

	_hardware_id = hardware_id
	_data = _read_from_disk(hardware_id)
	return _data


func _read_from_disk(hardware_id: String) -> Dictionary:
	var path := _path_for(hardware_id)

	if not FileAccess.file_exists(path):
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


## Writes data for hardware_id atomically (temp file + rename) so a
## crash mid-write can't leave a corrupt file. Returns true on success.
## Also (re)adopts data as the in-memory cache for hardware_id, so a
## subsequent load_data()/mutator call sees exactly what was written.
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

	file.store_string(JSON.stringify(data, "\t"))
	file = null  # close/flush before renaming, so the rename is atomic-safe

	var rename_err := DirAccess.rename_absolute(tmp_path, path)
	if rename_err != OK:
		logger.error("Unable to rename %s -> %s (error %d)" % [tmp_path, path, rename_err])
		return false

	logger.debug("save('%s'): wrote %s -> %s" % [hardware_id, tmp_path, path])
	logger.info("Saved fan curve data for hardware '%s'" % hardware_id)
	return true


## --- In-memory mutators: no disk I/O, just update the shared cache. ---
## Callers must have already made this hardware_id current via
## load_data() (FanModeManager/GameCurveManager/ProfileManagerPanel
## all do this before mutating). Combine with a later flush() call to
## actually persist.

func set_active_mode(mode: String) -> void:
	_data["active_mode"] = mode


func set_active_profile(profile_name) -> void:
	_data["active_profile"] = profile_name


func set_per_game_enabled(value: bool) -> void:
	_data["per_game_enabled"] = value

func get_per_game_enabled() -> bool:
	return _data.get("per_game_enabled", false)

func set_active_game_context(context_key: String) -> void:
	_data["active_game_context"] = context_key


func set_game_curve(context_key: String, mode: String, active_profile, curve: Dictionary) -> void:
	var game_curves: Dictionary = _data.get("game_curves", {})
	game_curves[context_key] = {"mode": mode, "active_profile": active_profile, "curve": curve}
	_data["game_curves"] = game_curves


## Queues job to run later, inside flush(), instead of immediately.
## Use this instead of a mutator directly whenever job needs to read
## some other object's "current" state (e.g. a CustomCurveEngine's
## live curve): since job only runs when flush() drains the queue,
## it's guaranteed to see that state as it stands at the end of
## whatever larger operation is under way, never mid-way through it.
func enqueue(job: Callable) -> void:
	_jobs.append(job)


## Runs every queued job in FIFO order, then writes the resulting
## in-memory document to disk once. Call this exactly once, at the
## very end of a top-level operation (a mode switch, a saved-context
## restore, a profile save) — never from a step in the middle of one,
## or a job enqueued earlier in that same operation would still be
## read too early. Re-entrant calls (a job that itself calls flush())
## are ignored; the outer call finishes the drain.
func flush() -> bool:
	if _draining:
		return false
	_draining = true
	while not _jobs.is_empty():
		var job: Callable = _jobs.pop_front()
		job.call()
	_draining = false
	return save(_hardware_id, _data)


## Saves (creating or overwriting) a named curve profile for
## hardware_id. Does not change active_mode/active_profile. Returns
## false if name is empty.
func save_profile(hardware_id: String, name: String, curve: Dictionary) -> bool:
	if name.is_empty():
		logger.error("Cannot save a profile with an empty name")
		return false

	logger.debug("save_profile('%s', '%s'): %s" % [hardware_id, name, curve])

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


## Deletes profile name for hardware_id. Clears active_profile if it
## pointed at this profile. Returns false if the profile doesn't exist.
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
	var was_active: bool = data.get("active_profile") == name
	if was_active:
		data["active_profile"] = null

	logger.debug(
		"delete_profile('%s', '%s'): was_active=%s, %d profile(s) remaining"
		% [hardware_id, name, was_active, profiles.size()]
	)

	var saved := save(hardware_id, data)
	if saved:
		logger.info("Deleted profile '%s' for hardware '%s'" % [name, hardware_id])
	return saved


## Returns the names of all saved profiles for hardware_id.
func list_profiles(hardware_id: String) -> Array[String]:
	var data := load_data(hardware_id)
	var profiles: Dictionary = data.get("profiles")

	if profiles == null:
		profiles = {}

	var names: Array[String] = []
	for profile_name in profiles.keys():
		names.append(profile_name)
	logger.debug("list_profiles('%s') -> %s" % [hardware_id, names])
	return names


## Returns a fresh, empty document for hardware_id (see the schema in
## the header comment).
func _default_data(hardware_id: String) -> Dictionary:
	return {
		"hardware_id": hardware_id,
		"active_mode": "bios",
		"active_profile": null,
		"profiles": {},
	}


## Returns the JSON file path on disk for hardware_id.
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
