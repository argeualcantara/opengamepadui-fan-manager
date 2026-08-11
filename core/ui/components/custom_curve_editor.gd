extends ScrollContainer
class_name CustomCurveEditor

## Generates the 10 fixed-temperature TemperatureSliderRow instances
## (REQUIREMENTS.md §2.3) and keeps them in sync with a
## CustomCurveEngine: row edits call engine.set_point(), and the
## engine's curve_changed signal (fired on every edit, including
## monotonicity pushes) re-syncs every row's displayed value.
##
## Wrapped in a ScrollContainer since all 10 rows don't fit in the
## overlay's fixed height at once: focusing a row auto-scrolls it
## into view, since ScrollContainer doesn't do that on its own.
##
## CustomCurveEngine/TemperatureSliderRow/FanCurveUtils below are
## referenced via preload()'d consts, not bare class_name lookups (see
## hwmon_fan_backend.gd's header comment /
## tasks/17-fix-class-name-resolution-em-plugin-empacotado.md).
const CustomCurveEngine = preload("res://plugins/fan-manager/core/engine/custom_curve_engine.gd")
const TemperatureSliderRow = preload("res://plugins/fan-manager/core/ui/components/temperature_slider_row.gd")
const FanCurveUtils = preload("res://plugins/fan-manager/core/persistence/fan_curve_utils.gd")

const ROW_SCENE := preload("res://plugins/fan-manager/core/ui/components/temperature_slider_row.tscn")

var engine: CustomCurveEngine

@onready var rows_container := $%RowsContainer as VBoxContainer

var _rows: Array[TemperatureSliderRow] = []
var _syncing_from_engine := false


func _ready() -> void:
	for temperature in FanCurveUtils.FIXED_TEMPERATURE_POINTS:
		var row := ROW_SCENE.instantiate() as TemperatureSliderRow
		row.temperature = temperature
		row.value_changed.connect(_on_row_value_changed)
		row.focus_entered.connect(_on_row_focused.bind(row))
		rows_container.add_child(row)
		_rows.append(row)

	_wire_focus_neighbors()

	if engine:
		_attach_to_engine()


## Attaches to (or re-attaches to) the given engine: syncs displayed
## values from it immediately and listens for further changes. Safe to
## call again with a different engine instance (e.g. a fresh
## CustomCurveEngine after the plugin reloads).
func bind_engine(new_engine: CustomCurveEngine) -> void:
	if engine and engine.curve_changed.is_connected(_on_curve_changed):
		engine.curve_changed.disconnect(_on_curve_changed)

	engine = new_engine

	if not is_inside_tree():
		return

	_attach_to_engine()


func _attach_to_engine() -> void:
	if not engine:
		return
	if not engine.curve_changed.is_connected(_on_curve_changed):
		engine.curve_changed.connect(_on_curve_changed)
	_sync_all_rows(engine.get_curve())


func _on_row_value_changed(temperature: int, percent: float) -> void:
	if _syncing_from_engine or not engine:
		return
	engine.set_point(temperature, percent)


func _on_curve_changed(curve: Dictionary) -> void:
	_sync_all_rows(curve)


func _on_row_focused(row: TemperatureSliderRow) -> void:
	ensure_control_visible(row)


func _sync_all_rows(curve: Dictionary) -> void:
	_syncing_from_engine = true
	for row in _rows:
		row.set_percent_silently(curve.get(row.temperature, 0.0))
	_syncing_from_engine = false


## Chains ui_up/ui_down between the 10 rows (wrapping top<->bottom).
## Not done via FocusGroup: FocusGroup's automatic VBoxContainer wiring
## only considers direct children with focus_mode == FOCUS_ALL, and
## each row here needs its own custom ui_left/ui_right handling
## (see TemperatureSliderRow), so the neighbor links are set directly
## instead: same underlying mechanism FocusGroup itself uses.
func _wire_focus_neighbors() -> void:
	for i in _rows.size():
		var current := _rows[i]
		var next := _rows[(i + 1) % _rows.size()]
		var previous := _rows[(i - 1 + _rows.size()) % _rows.size()]

		current.focus_neighbor_bottom = current.get_path_to(next)
		current.focus_next = current.get_path_to(next)
		current.focus_neighbor_top = current.get_path_to(previous)
		current.focus_previous = current.get_path_to(previous)
