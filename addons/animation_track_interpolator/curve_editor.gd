@tool
extends Control
## 过渡权重曲线编辑器。
##
## 横轴 x = 归一化时间 t（0~1）；纵轴 y = 过渡权重（0 = 起始值，1 = 终点值，
## 超出 0~1 表示预动作 / 回弹）。控制点可拖动，双击空白处加点，右键控制点删点。
## 首尾控制点的 x 固定在 0 与 1，保证首尾关键帧的值不被改动。

const Core: GDScript = preload("res://addons/animation_track_interpolator/track_interpolator_core.gd")

signal points_changed(points: PackedVector2Array)
## 用户开始拖动/增删控制点：面板据此切到「自定义曲线」。
signal edit_started()

const PADDING: float = 12.0
const POINT_RADIUS: float = 4.0
const HIT_RADIUS: float = 9.0
const SAMPLES: int = 72
const Y_MIN: float = -0.5
const Y_MAX: float = 1.5

const COLOR_BG: Color = Color(0.11, 0.11, 0.13, 1.0)
const COLOR_GRID: Color = Color(1.0, 1.0, 1.0, 0.07)
const COLOR_GRID_STRONG: Color = Color(1.0, 1.0, 1.0, 0.16)
const COLOR_REF: Color = Color(1.0, 1.0, 1.0, 0.18)
const COLOR_CURVE: Color = Color(0.45, 0.8, 1.0)
const COLOR_POINT: Color = Color(0.9, 0.9, 0.95)
const COLOR_POINT_EDGE: Color = Color(0.3, 0.6, 0.9)
const COLOR_POINT_ACTIVE: Color = Color(1.0, 0.85, 0.4)

var _points: PackedVector2Array = PackedVector2Array([Vector2(0.0, 0.0), Vector2(1.0, 1.0)])
var _drag_index: int = -1
var _hover_index: int = -1


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = false
	custom_minimum_size = Vector2(custom_minimum_size.x, maxf(custom_minimum_size.y, 110.0))


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED or what == NOTIFICATION_THEME_CHANGED:
		queue_redraw()


# ---------------------------------------------------------------- 对外接口

## 当前控制点（副本）。
func get_points() -> PackedVector2Array:
	return _points.duplicate()


## 整体替换控制点（会做一次规范化）。
func set_points(points: PackedVector2Array) -> void:
	_points = Core.normalize_points(points)
	_drag_index = -1
	_hover_index = -1
	queue_redraw()


# ---------------------------------------------------------------- 坐标换算

func _plot_rect() -> Rect2:
	var width: float = maxf(size.x - PADDING * 2.0, 1.0)
	var height: float = maxf(size.y - PADDING * 2.0, 1.0)
	return Rect2(PADDING, PADDING, width, height)


## 数据坐标 (x∈0~1, y∈Y_MIN~Y_MAX) -> 控件内像素坐标。
func _to_local(point: Vector2) -> Vector2:
	var rect: Rect2 = _plot_rect()
	var px: float = rect.position.x + clampf(point.x, 0.0, 1.0) * rect.size.x
	var py: float = rect.position.y + (1.0 - (point.y - Y_MIN) / (Y_MAX - Y_MIN)) * rect.size.y
	return Vector2(px, py)


## 控件内像素坐标 -> 数据坐标。
func _to_data(local: Vector2) -> Vector2:
	var rect: Rect2 = _plot_rect()
	var x: float = clampf((local.x - rect.position.x) / rect.size.x, 0.0, 1.0)
	var y: float = Y_MIN + (1.0 - (local.y - rect.position.y) / rect.size.y) * (Y_MAX - Y_MIN)
	return Vector2(x, y)


## 找到离 local 最近、且在吸附半径内的控制点索引；没有则 -1。
func _pick(local: Vector2) -> int:
	var best: int = -1
	var best_distance: float = HIT_RADIUS
	for i: int in range(_points.size()):
		var distance: float = _to_local(_points[i]).distance_to(local)
		if distance <= best_distance:
			best_distance = distance
			best = i
	return best


# ---------------------------------------------------------------- 绘制

func _draw() -> void:
	var rect: Rect2 = _plot_rect()
	draw_rect(Rect2(Vector2.ZERO, size), COLOR_BG, true)

	for i: int in range(5):
		var gx: float = float(i) / 4.0
		var edge: bool = i == 0 or i == 4
		var px: float = rect.position.x + gx * rect.size.x
		draw_line(Vector2(px, rect.position.y), Vector2(px, rect.end.y), COLOR_GRID_STRONG if edge else COLOR_GRID, 1.0)
	for gy: float in PackedFloat64Array([0.0, 0.5, 1.0]):
		var py: float = _to_local(Vector2(0.0, gy)).y
		var strong: bool = is_equal_approx(gy, 0.0) or is_equal_approx(gy, 1.0)
		draw_line(Vector2(rect.position.x, py), Vector2(rect.end.x, py), COLOR_GRID_STRONG if strong else COLOR_GRID, 1.0)

	draw_line(_to_local(Vector2(0.0, 0.0)), _to_local(Vector2(1.0, 1.0)), COLOR_REF, 1.0)

	var polyline: PackedVector2Array = PackedVector2Array()
	for i: int in range(SAMPLES + 1):
		var t: float = float(i) / float(SAMPLES)
		polyline.append(_to_local(Vector2(t, Core.sample_curve(_points, t))))
	draw_polyline(polyline, COLOR_CURVE, 2.0, true)

	for i: int in range(_points.size()):
		var center: Vector2 = _to_local(_points[i])
		var fill: Color = COLOR_POINT
		if i == _drag_index:
			fill = COLOR_POINT_ACTIVE
		elif i == _hover_index:
			fill = COLOR_POINT_ACTIVE
		draw_circle(center, POINT_RADIUS, fill)
		draw_arc(center, POINT_RADIUS, 0.0, TAU, 20, COLOR_POINT_EDGE, 1.0, true)


# ---------------------------------------------------------------- 交互

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_handle_motion(event)
		return
	if event is InputEventMouseButton:
		_handle_button(event)


func _handle_motion(event: InputEventMouseMotion) -> void:
	if _drag_index >= 0:
		_move_point(_drag_index, event.position)
		accept_event()
		return
	var hovered: int = _pick(event.position)
	if hovered != _hover_index:
		_hover_index = hovered
		queue_redraw()


func _handle_button(event: InputEventMouseButton) -> void:
	var picked: int = _pick(event.position)
	if event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			if picked >= 0:
				_drag_index = picked
				_hover_index = picked
				edit_started.emit()
				queue_redraw()
			elif event.double_click:
				_add_point(_to_data(event.position))
			accept_event()
		elif _drag_index >= 0:
			_drag_index = -1
			points_changed.emit(get_points())
			queue_redraw()
			accept_event()
		return
	if event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
		if picked > 0 and picked < _points.size() - 1:
			_points.remove_at(picked)
			_drag_index = -1
			_hover_index = -1
			edit_started.emit()
			points_changed.emit(get_points())
			queue_redraw()
			accept_event()


## 双击空白处加一个控制点（不要贴在首尾，方便继续拖动）。
func _add_point(point: Vector2) -> void:
	_points.append(Vector2(clampf(point.x, 0.02, 0.98), clampf(point.y, Y_MIN, Y_MAX)))
	_points = Core.normalize_points(_points)
	edit_started.emit()
	points_changed.emit(get_points())
	queue_redraw()


## 拖动控制点：x 夹在左右邻点之间（首尾点 x 锁死），y 夹在可视范围内。
func _move_point(index: int, local: Vector2) -> void:
	var point: Vector2 = _to_data(local)
	if index <= 0:
		point.x = 0.0
	elif index >= _points.size() - 1:
		point.x = 1.0
	else:
		var left: float = _points[index - 1].x + 0.01
		var right: float = _points[index + 1].x - 0.01
		point.x = clampf(point.x, left, maxf(left, right))
	point.y = clampf(point.y, Y_MIN, Y_MAX)
	_points[index] = point
	queue_redraw()
