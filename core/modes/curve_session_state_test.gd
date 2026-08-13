extends GutTest

## Pure transition-table tests for CurveSessionState: no engines, no
## store, no scene tree — see its own doc comment for why it's
## designed to be testable in isolation like this.

var session: CurveSessionState


func before_each() -> void:
	session = CurveSessionState.new()


func test_starts_untracked() -> void:
	assert_eq(session.state, CurveSessionState.State.UNTRACKED)
	assert_eq(session.context_key, "")


func test_context_switched_from_untracked_enters_loaded() -> void:
	session.context_switched("hades")

	assert_eq(session.state, CurveSessionState.State.LOADED)
	assert_eq(session.context_key, "hades")


func test_context_switched_discards_dirty_state() -> void:
	session.context_switched("hades")
	session.slider_edited()
	assert_eq(session.state, CurveSessionState.State.DIRTY)

	session.context_switched("__steam_home__")

	assert_eq(
		session.state, CurveSessionState.State.LOADED,
		"switching context must discard an unsaved edit from the previous one"
	)
	assert_eq(session.context_key, "__steam_home__")


func test_mode_changed_to_custom_reenters_loaded_keeping_context() -> void:
	session.context_switched("hades")
	session.slider_edited()

	session.mode_changed_to_custom()

	assert_eq(session.state, CurveSessionState.State.LOADED)
	assert_eq(session.context_key, "hades", "context must not change on a same-context mode switch")


func test_slider_edited_from_loaded_becomes_dirty() -> void:
	session.context_switched("hades")

	session.slider_edited()

	assert_eq(session.state, CurveSessionState.State.DIRTY)
	assert_eq(session.context_key, "hades")


func test_slider_edited_from_committed_becomes_dirty() -> void:
	session.context_switched("hades")
	session.apply_pressed()
	assert_eq(session.state, CurveSessionState.State.COMMITTED)

	session.slider_edited()

	assert_eq(session.state, CurveSessionState.State.DIRTY)


func test_slider_edited_while_untracked_is_noop() -> void:
	session.slider_edited()

	assert_eq(session.state, CurveSessionState.State.UNTRACKED)
	assert_eq(session.context_key, "")


func test_apply_pressed_from_dirty_becomes_committed() -> void:
	session.context_switched("hades")
	session.slider_edited()

	session.apply_pressed()

	assert_eq(session.state, CurveSessionState.State.COMMITTED)
	assert_eq(session.context_key, "hades")


func test_apply_pressed_without_edits_still_commits() -> void:
	# Mirrors ModeSelectOverlay's real Apply button, which has no
	# dirty guard: pressing Apply on an already-clean curve still
	# commits it (re-saves the same values), it just doesn't error.
	session.context_switched("hades")

	session.apply_pressed()

	assert_eq(session.state, CurveSessionState.State.COMMITTED)


func test_apply_pressed_while_untracked_is_noop() -> void:
	session.apply_pressed()

	assert_eq(session.state, CurveSessionState.State.UNTRACKED)
	assert_eq(session.context_key, "")


func test_per_game_toggled_off_snaps_to_default_from_any_state() -> void:
	session.context_switched("hades")
	session.slider_edited()

	session.per_game_toggled_off()

	assert_eq(session.state, CurveSessionState.State.LOADED)
	assert_eq(session.context_key, CurveSessionState.DEFAULT_PROFILE_CONTEXT_KEY)


func test_per_game_toggled_off_works_even_while_untracked() -> void:
	session.per_game_toggled_off()

	assert_eq(session.state, CurveSessionState.State.LOADED)
	assert_eq(session.context_key, CurveSessionState.DEFAULT_PROFILE_CONTEXT_KEY)


func test_per_game_toggled_on_enters_loaded_with_given_context() -> void:
	session.per_game_toggled_on("trials of mana")

	assert_eq(session.state, CurveSessionState.State.LOADED)
	assert_eq(session.context_key, "trials of mana")


func test_state_changed_emits_on_every_transition_including_repeats() -> void:
	var emissions: Array = []
	session.state_changed.connect(func(state, context_key): emissions.append([state, context_key]))

	session.context_switched("hades")
	session.apply_pressed()
	session.apply_pressed()  # repeat: still a real event, must still emit

	assert_eq(emissions.size(), 3, "every transition call must emit, even a same-value repeat")
	assert_eq(emissions[1], [CurveSessionState.State.COMMITTED, "hades"])
	assert_eq(emissions[2], [CurveSessionState.State.COMMITTED, "hades"])
