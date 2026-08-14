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
	assert_eq(data["active_profile"], null)
	assert_eq(data["profiles"], {})


func test_save_then_load_roundtrips_data() -> void:
	var hardware_id := _track("gut-test-roundtrip")
	var data := store.load_data(hardware_id)
	data["active_mode"] = "custom"
	data["active_profile"] = "Silencioso"

	assert_true(store.save(hardware_id, data))

	var reloaded := store.load_data(hardware_id)
	assert_eq(reloaded["active_mode"], "custom")
	assert_eq(reloaded["active_profile"], "Silencioso")


func test_save_profile_adds_and_lists_it() -> void:
	var hardware_id := _track("gut-test-save-profile")
	var curve := {"10": 0, "20": 0, "30": 20}

	assert_true(store.save_profile(hardware_id, "Silencioso", curve))

	var profiles := store.list_profiles(hardware_id)
	assert_true(profiles.has("Silencioso"))

	var data := store.load_data(hardware_id)
	assert_eq(data["profiles"]["Silencioso"], curve)


func test_save_profile_overwrites_existing_name_without_duplicating() -> void:
	var hardware_id := _track("gut-test-overwrite-profile")

	store.save_profile(hardware_id, "Perfil", {"10": 0})
	store.save_profile(hardware_id, "Perfil", {"10": 50})

	var profiles := store.list_profiles(hardware_id)
	assert_eq(profiles.count("Perfil"), 1)

	var data := store.load_data(hardware_id)
	assert_eq(data["profiles"]["Perfil"], {"10": 50})


func test_save_profile_rejects_empty_name() -> void:
	var hardware_id := _track("gut-test-empty-name")
	assert_false(store.save_profile(hardware_id, "", {"10": 0}))


func test_delete_profile_removes_it() -> void:
	var hardware_id := _track("gut-test-delete-profile")
	store.save_profile(hardware_id, "Temporario", {"10": 0})

	assert_true(store.delete_profile(hardware_id, "Temporario"))
	assert_false(store.list_profiles(hardware_id).has("Temporario"))


func test_delete_profile_clears_active_profile_if_it_was_active() -> void:
	var hardware_id := _track("gut-test-delete-active-profile")
	var data := store.load_data(hardware_id)
	data["active_profile"] = "Ativo"
	data["profiles"] = {"Ativo": {"10": 0}}
	store.save(hardware_id, data)

	store.delete_profile(hardware_id, "Ativo")

	var reloaded := store.load_data(hardware_id)
	assert_eq(reloaded["active_profile"], null)


func test_delete_nonexistent_profile_returns_false() -> void:
	var hardware_id := _track("gut-test-delete-missing")
	assert_false(store.delete_profile(hardware_id, "NaoExiste"))


func test_list_profiles_empty_when_none_saved() -> void:
	var hardware_id := _track("gut-test-empty-profiles")
	assert_eq(store.list_profiles(hardware_id), [])


func test_different_hardware_ids_do_not_share_profiles() -> void:
	var hardware_a := _track("gut-test-hardware-a")
	var hardware_b := _track("gut-test-hardware-b")

	store.save_profile(hardware_a, "SoNoA", {"10": 0})

	assert_true(store.list_profiles(hardware_a).has("SoNoA"))
	assert_false(store.list_profiles(hardware_b).has("SoNoA"))


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
