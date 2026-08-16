extends GutTest

## Exercises FanCurveStore against the real user:// filesystem (there's
## no lightweight in-memory FileAccess fake in Godot), using dedicated
## test hardware_ids that are cleaned up after every test so runs don't
## leak files into the developer's real user:// data dir.

var store: FanCurveStore
var _used_hardware_ids: Array[String] = []


func before_each() -> void:
	store = FanCurveStore.new()
	_used_hardware_ids = []


func after_each() -> void:
	for hardware_id in _used_hardware_ids:
		var path := store._path_for(hardware_id)
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)


func _track(hardware_id: String) -> String:
	_used_hardware_ids.append(hardware_id)
	return hardware_id


func test_exists_is_false_before_any_save() -> void:
	var hardware_id := _track("gut-test-exists-false")
	assert_false(store.exists(hardware_id))


func test_exists_is_true_after_save() -> void:
	var hardware_id := _track("gut-test-exists-true")
	store.save(hardware_id, store.load_data(hardware_id))
	assert_true(store.exists(hardware_id))


func test_load_returns_default_document_when_no_file_exists() -> void:
	var hardware_id := _track("gut-test-no-file")
	var data := store.load_data(hardware_id)

	assert_eq(data["hardware_id"], hardware_id)
	assert_eq(data["active_mode"], "bios")


func test_save_then_load_roundtrips_data() -> void:
	var hardware_id := _track("gut-test-roundtrip")
	var data := store.load_data(hardware_id)
	data["active_mode"] = "custom"

	assert_true(store.save(hardware_id, data))

	var reloaded := store.load_data(hardware_id)
	assert_eq(reloaded["active_mode"], "custom")


func test_set_game_curve_then_save_roundtrips_data() -> void:
	var hardware_id := _track("gut-test-game-curve-roundtrip")
	var curve := {"10": 0, "20": 0, "30": 20}

	store.load_data(hardware_id)
	store.set_game_curve("__default__", "custom", curve)
	store.flush()

	var reloaded := store.load_data(hardware_id)
	assert_eq(reloaded["game_curves"]["__default__"], {"mode": "custom", "curve": curve})


func test_sanitize_id_strips_unsafe_filename_characters() -> void:
	var hardware_id := _track("Weird Product/Name!*")
	var path := store._path_for(hardware_id)

	assert_false(path.contains(" "))
	assert_true(path.contains("Weird"))
	assert_true(path.contains("Product_Name"))
	assert_false(path.contains("!"))
	assert_false(path.contains("*"))

func test_sanitize_id_replaces_invalid_characters() -> void:
	var hardware_id := _track("???")
	var path := store._path_for(hardware_id)
	assert_eq(path, "user://data/fan-manager/___.json")

func test_sanitize_id_never_produces_empty_filename() -> void:
	var hardware_id := _track("")
	var path := store._path_for(hardware_id)
	assert_eq(path, "user://data/fan-manager/unknown.json")
