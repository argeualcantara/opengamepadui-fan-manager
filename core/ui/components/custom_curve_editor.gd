extends ScrollContainer
class_name CustomCurveEditor

## Generates the 10 fixed-temperature TemperatureSliderRow instances and
## keeps them in sync with a CustomCurveEngine: row edits call
## engine.set_point(), and engine.curve_changed re-syncs every row's
## displayed value.
##
## Wrapped in a ScrollContainer since all 10 rows don't fit the
## overlay's fixed height; focusing a row auto-scrolls it into view.
##
## Referenced via preload()'d consts, not bare class_name lookups: see
## hwmon_fan_backend.gd's header comment for why.
const CustomCurveEngine = preload("res://plugins/fan-manager/core/engine/custom_curve_engine.gd")
const TemperatureSliderRow = preload("res://plugins/fan-manager/core/ui/components/temperature_slider_row.gd")
const FanCurveUtils = preload("res://plugins/fan-manager/core/persistence/fan_curve_utils.gd")

const ROW_SCENE := preload("res://plugins/fan-manager/core/ui/components/temperature_slider_row.tscn")

var engine: CustomCurveEngine

@onready var rows_container := $%RowsContainer as VBoxContainer

var _rows: Array[TemperatureSliderRow] = []
var _syncing_from_engine := false


## Builds the 10 rows and wires their focus neighbors.
func _ready() -> void:
	for temperature in FanCurveUtils.FIXED_TEMPERATURE_POINTS:
		var row := ROW_SCENE.instantiate() as TemperatureSliderRow
		row.temperature = temperature
		row.value_changed.connect(_on_row_value_changed)
		row.focus_entered.connect(_on_row_focused.bind(row))
		rows_container.add_child(row)
		_rows.append(row)

	_wire_focus_neighbors.call_deferred()

	if engine:
		_attach_to_engine()


## Attaches to (or re-attaches to) new_engine: syncs displayed values
## immediately and listens for further changes. Safe to call again with
## a different engine instance.
func bind_engine(new_engine: CustomCurveEngine) -> void:
	if engine and engine.curve_changed.is_connected(_on_curve_changed):
		engine.curve_changed.disconnect(_on_curve_changed)

	engine = new_engine

	if not is_inside_tree():
		return

	_attach_to_engine()


## Returns the first (coldest) row, or null if rows haven't been built
## yet. Used by ModeSelectOverlay to bridge focus into this editor.
func get_first_row() -> TemperatureSliderRow:
	return _rows[0] if not _rows.is_empty() else null


## Connects to engine.curve_changed and syncs all rows to its current curve.
func _attach_to_engine() -> void:
	if not engine:
		return
	if not engine.curve_changed.is_connected(_on_curve_changed):
		engine.curve_changed.connect(_on_curve_changed)
	_sync_all_rows(engine.get_curve())


## Signal handler for TemperatureSliderRow.value_changed: forwards the
## edit to engine.set_point(), unless it's a programmatic sync.
func _on_row_value_changed(temperature: int, percent: float) -> void:
	if _syncing_from_engine or not engine:
		return
	engine.set_point(temperature, percent)


## Signal handler for CustomCurveEngine.curve_changed.
func _on_curve_changed(curve: Dictionary) -> void:
	_sync_all_rows(curve)


## Signal handler for a row's focus_entered: scrolls it into view.
func _on_row_focused(row: TemperatureSliderRow) -> void:
	ensure_control_visible(row)


## Sets every row's displayed value from curve without re-emitting
## value_changed back into the engine.
func _sync_all_rows(curve: Dictionary) -> void:
	_syncing_from_engine = true
	for row in _rows:
		row.set_percent_silently(curve.get(row.temperature, 0.0))
	_syncing_from_engine = false


## Chains ui_up/ui_down between the 10 rows, linearly, no wraparound:
## last row's "down" stays put; row 0's "up" is left unset for
## ModeSelectOverlay to wire to the selected fan tab.
func _wire_focus_neighbors() -> void:
	for i in _rows.size():
		var current := _rows[i]

		if i < _rows.size() - 1:
			var next := _rows[i + 1]
			current.focus_neighbor_bottom = current.get_path_to(next)
			current.focus_next = current.get_path_to(next)
		else:
			current.focus_neighbor_bottom = current.get_path()
			current.focus_next = current.get_path()

		if i > 0:
			var previous := _rows[i - 1]
			current.focus_neighbor_top = current.get_path_to(previous)
			current.focus_previous = current.get_path_to(previous)
