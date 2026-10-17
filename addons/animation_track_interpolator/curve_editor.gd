@tool
extends Control
## 过渡权重曲线编辑器（图表操作方式）。
##
## 横轴 x = 归一化时间 t（0~1）；纵轴 y = 过渡权重（0 = 起始值，1 = 终点值，
## 超出 0~1 表示预动作 / 回弹）。支持三种图形模型（见 Core.SHAPE_*）：
##
## - 多控制点：任意个控制点，用 Hermite 平滑连接；双击空白加点，右键点删点；
## - 贝塞尔：h1 / h2 两个手柄（同 CSS cubic-bezier）；
## - 弹性：振幅 / 周期两个手柄，做带回弹的缓动。
##
## 操作：左键拖动图形手柄；空白处按住左键或中键平移视图（需开启「允许拖动」）；滚轮以光标为中心缩放。

const Core: GDScript = preload("res://addons/animation_track_interpolator/track_interpolator_core.gd")

## 图形内容变化（拖拽结束 / 增删点 / 参数改变）。
signal shape_changed(shape: Dictionary)
## 用户开始操作图形：面板据此把「插值方式」切到「自定义曲线」。
signal edit_started()

const PADDING: float = 12.0
const POINT_RADIUS: float = 4.0
const HANDLE_RADIUS: float = 5.0
const HIT_RADIUS: float = 10.0
const SAMPLES: int = 96

## 默认视图纵轴范围：0~1 两侧各留一点，方便看清越界与回弹。
const Y_MIN: float = -0.6
const Y_MAX: float = 1.6
const ZOOM_MIN: float = 0.25
const ZOOM_MAX: float = 6.0
const ZOOM_STEP: float = 1.15
const PAN_LIMIT: float = 2.0

## 弹性手柄的摆放位置与取值范围。
const AMP_HANDLE_X: float = 0.08
const AMP_BASE_Y: float = 1.0
const AMP_Y_SCALE: float = 0.25
const AMP_MIN: float = 0.2
const AMP_MAX: float = 2.0
const PERIOD_HANDLE_Y: float = -0.35
const PERIOD_MIN: float = 0.05
const PERIOD_MAX: float = 1.0

const EPS: float = 0.0001

const COLOR_BG: Color = Color(0.11, 0.11, 0.13, 1.0)
const COLOR_GRID: Color = Color(1.0, 1.0, 1.0, 0.06)
const COLOR_GRID_STRONG: Color = Color(1.0, 1.0, 1.0, 0.16)
const COLOR_UNIT: Color = Color(1.0, 1.0, 1.0, 0.22)
const COLOR_REF: Color = Color(1.0, 1.0, 1.0, 0.16)
const COLOR_CURVE: Color = Color(0.45, 0.8, 1.0)
const COLOR_HANDLE: Color = Color(0.9, 0.9, 0.95)
const COLOR_HANDLE_EDGE: Color = Color(0.3, 0.6, 0.9)
const COLOR_HANDLE_ACTIVE: Color = Color(1.0, 0.85, 0.4)
const COLOR_GUIDE: Color = Color(0.64, 0.66, 0.72, 0.55)
const COLOR_LABEL: Color = Color(0.8, 0.84, 0.9, 0.9)

var _shape: Dictionary = Core.default_shape()
var _drag_handle: String = ""
var _hover_handle: String = ""
var _panning: bool = false
## 是否允许平移视图（由面板的「允许拖动」选框控制）。
var _pan_enabled: bool = true
var _zoom: float = 1.0
var _pan: Vector2 = Vector2.ZERO


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = false
	custom_minimum_size = Vector2(custom_minimum_size.x, maxf(custom_minimum_size.y, 130.0))


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED or what == NOTIFICATION_THEME_CHANGED:
		queue_redraw()


# ---------------------------------------------------------------- 对外接口

## 当前图形（副本）。
func get_shape() -> Dictionary:
	return _shape.duplicate(true)


## 整体替换图形（缺省项用默认值补齐）。
func set_shape(shape: Dictionary) -> void:
	var merged: Dictionary = Core.default_shape()
	for key: Variant in shape.keys():
		merged[key] = shape[key]
	var points: PackedVector2Array = merged.get("points", PackedVector2Array())
	merged["points"] = Core.normalize_points(points)
	_shape = merged
	_drag_handle = ""
	_hover_handle = ""
	queue_redraw()


## 当前图形模型（Core.SHAPE_*）。
func get_mode() -> int:
	return int(_shape.get("mode", Core.SHAPE_POINTS))


## 切换图形模型；各模型自己的参数会保留，来回切换不会丢。
func set_mode(mode: int) -> void:
	if get_mode() == mode:
		return
	_shape["mode"] = mode
	_drag_handle = ""
	_hover_handle = ""
	queue_redraw()


## 用一组预设控制点重置为「多控制点」图形。
func set_preset_points(points: PackedVector2Array) -> void:
	_shape["mode"] = Core.SHAPE_POINTS
	_shape["points"] = Core.normalize_points(points)
	_drag_handle = ""
	_hover_handle = ""
	queue_redraw()


## 视图复位（缩放与平移回到初始状态）。
func reset_view() -> void:
	_zoom = 1.0
	_pan = Vector2.ZERO
	queue_redraw()


## 是否允许平移视图。关掉时会立刻中断正在进行的平移。
func set_pan_enabled(enabled: bool) -> void:
	if _pan_enabled == enabled:
		return
	_pan_enabled = enabled
	if not enabled:
		_panning = false
	queue_redraw()


func is_pan_enabled() -> bool:
	return _pan_enabled


# ---------------------------------------------------------------- 视图换算

func _plot_rect() -> Rect2:
	var width: float = maxf(size.x - PADDING * 2.0, 1.0)
	var height: float = maxf(size.y - PADDING * 2.0, 1.0)
	return Rect2(PADDING, PADDING, width, height)


## 当前可见的数据范围（受缩放与平移影响）。
func _view_rect() -> Rect2:
	var center: Vector2 = Vector2(0.5, (Y_MIN + Y_MAX) * 0.5) + _pan
	var half: Vector2 = Vector2(0.5, (Y_MAX - Y_MIN) * 0.5) / _zoom
	return Rect2(center - half, half * 2.0)


func _to_local(data: Vector2) -> Vector2:
	var rect: Rect2 = _plot_rect()
	var view: Rect2 = _view_rect()
	var px: float = rect.position.x + (data.x - view.position.x) / view.size.x * rect.size.x
	var py: float = rect.position.y + (1.0 - (data.y - view.position.y) / view.size.y) * rect.size.y
	return Vector2(px, py)


func _to_data(local: Vector2) -> Vector2:
	var rect: Rect2 = _plot_rect()
	var view: Rect2 = _view_rect()
	var x: float = view.position.x + (local.x - rect.position.x) / rect.size.x * view.size.x
	var y: float = view.position.y + (1.0 - (local.y - rect.position.y) / rect.size.y) * view.size.y
	return Vector2(x, y)


## 网格步长：跟随缩放级别，让可见范围内大致保持 8 格。
func _grid_step() -> float:
	var target: float = _view_rect().size.x / 8.0
	for candidate: float in PackedFloat64Array([0.01, 0.02, 0.05, 0.1, 0.2, 0.25, 0.5, 1.0, 2.0]):
		if candidate >= target:
			return candidate
	return 2.0


func _clamp_pan() -> void:
	_pan = Vector2(clampf(_pan.x, -PAN_LIMIT, PAN_LIMIT), clampf(_pan.y, -PAN_LIMIT, PAN_LIMIT))


# ---------------------------------------------------------------- 手柄

## 当前模型下所有可拖拽手柄的 id。
func _handle_ids() -> PackedStringArray:
	match get_mode():
		Core.SHAPE_BEZIER:
			return PackedStringArray(["h1", "h2"])
		Core.SHAPE_ELASTIC:
			return PackedStringArray(["amp", "period"])
	var ids: PackedStringArray = PackedStringArray()
	var points: PackedVector2Array = _shape.get("points", PackedVector2Array())
	for i: int in range(points.size()):
		ids.append("p%d" % i)
	return ids


## 手柄在数据空间里的位置。
func _handle_position(id: String) -> Vector2:
	match get_mode():
		Core.SHAPE_BEZIER:
			return _shape.get(id, Vector2.ZERO)
		Core.SHAPE_ELASTIC:
			if id == "amp":
				return Vector2(AMP_HANDLE_X, AMP_BASE_Y + float(_shape.get("amplitude", 1.0)) * AMP_Y_SCALE)
			return Vector2(float(_shape.get("period", 0.3)), PERIOD_HANDLE_Y)
	var points: PackedVector2Array = _shape.get("points", PackedVector2Array())
	var index: int = int(id.substr(1))
	if index >= 0 and index < points.size():
		return points[index]
	return Vector2.ZERO


func _pick(local: Vector2) -> String:
	var best: String = ""
	var best_distance: float = HIT_RADIUS
	for id: String in _handle_ids():
		var distance: float = _to_local(_handle_position(id)).distance_to(local)
		if distance <= best_distance:
			best_distance = distance
			best = id
	return best


# ---------------------------------------------------------------- 绘制

func _draw() -> void:
	var rect: Rect2 = _plot_rect()
	var view: Rect2 = _view_rect()
	draw_rect(Rect2(Vector2.ZERO, size), COLOR_BG, true)

	# 网格：步长跟着缩放走。
	var step: float = _grid_step()
	var gx: float = floorf(view.position.x / step) * step
	while gx <= view.end.x + EPS:
		var strong: bool = absf(gx) < EPS or absf(gx - 1.0) < EPS
		var px: float = _to_local(Vector2(gx, 0.0)).x
		draw_line(Vector2(px, rect.position.y), Vector2(px, rect.end.y), COLOR_GRID_STRONG if strong else COLOR_GRID, 1.0)
		gx += step
	var gy: float = floorf(view.position.y / step) * step
	while gy <= view.end.y + EPS:
		var strong_y: bool = absf(gy) < EPS or absf(gy - 1.0) < EPS
		var py: float = _to_local(Vector2(0.0, gy)).y
		draw_line(Vector2(rect.position.x, py), Vector2(rect.end.x, py), COLOR_GRID_STRONG if strong_y else COLOR_GRID, 1.0)
		gy += step

	# 0~1 单位方框与线性参考线。
	draw_rect(Rect2(_to_local(Vector2(0.0, 1.0)), _to_local(Vector2(1.0, 0.0)) - _to_local(Vector2(0.0, 1.0))), COLOR_UNIT, false, 1.0)
	draw_line(_to_local(Vector2(0.0, 0.0)), _to_local(Vector2(1.0, 1.0)), COLOR_REF, 1.0)

	_draw_guides()
	_draw_curve()
	_draw_handles()


## 贝塞尔的引导线、弹性手柄的参考轴。
func _draw_guides() -> void:
	match get_mode():
		Core.SHAPE_BEZIER:
			draw_line(_to_local(Vector2(0.0, 0.0)), _to_local(_handle_position("h1")), COLOR_GUIDE, 1.0)
			draw_line(_to_local(Vector2(1.0, 1.0)), _to_local(_handle_position("h2")), COLOR_GUIDE, 1.0)
		Core.SHAPE_ELASTIC:
			var rect: Rect2 = _plot_rect()
			var amp_y: float = _to_local(_handle_position("amp")).y
			var per_x: float = _to_local(_handle_position("period")).x
			draw_dashed_line(Vector2(rect.position.x, amp_y), Vector2(rect.end.x, amp_y), COLOR_GUIDE, 1.0, 4.0)
			draw_dashed_line(Vector2(per_x, rect.position.y), Vector2(per_x, rect.end.y), COLOR_GUIDE, 1.0, 4.0)
			_draw_label(_handle_position("amp") + Vector2(0.02, 0.0), "振幅 %.2f" % float(_shape.get("amplitude", 1.0)))
			_draw_label(_handle_position("period") + Vector2(0.0, -0.09), "周期 %.2f" % float(_shape.get("period", 0.3)))


func _draw_curve() -> void:
	var view: Rect2 = _view_rect()
	var polyline: PackedVector2Array = PackedVector2Array()
	for i: int in range(SAMPLES + 1):
		var x: float = view.position.x + view.size.x * float(i) / float(SAMPLES)
		var weight: float = Core.shape_weight(_shape, clampf(x, 0.0, 1.0))
		polyline.append(_to_local(Vector2(x, weight)))
	draw_polyline(polyline, COLOR_CURVE, 2.0, true)


func _draw_handles() -> void:
	var radius: float = HANDLE_RADIUS if get_mode() != Core.SHAPE_POINTS else POINT_RADIUS
	for id: String in _handle_ids():
		var center: Vector2 = _to_local(_handle_position(id))
		var fill: Color = COLOR_HANDLE
		if id == _drag_handle or id == _hover_handle:
			fill = COLOR_HANDLE_ACTIVE
		draw_circle(center, radius, fill)
		draw_arc(center, radius, 0.0, TAU, 20, COLOR_HANDLE_EDGE, 1.0, true)


func _draw_label(data_position: Vector2, text: String) -> void:
	var font: Font = get_theme_default_font()
	if font == null:
		return
	var size_px: int = maxi(get_theme_default_font_size() - 3, 8)
	draw_string(font, _to_local(data_position) + Vector2(2.0, -4.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, size_px, COLOR_LABEL)


# ---------------------------------------------------------------- 交互

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_handle_motion(event)
	elif event is InputEventMouseButton:
		_handle_button(event)


func _handle_motion(event: InputEventMouseMotion) -> void:
	if _panning:
		var rect: Rect2 = _plot_rect()
		var view: Rect2 = _view_rect()
		_pan -= Vector2(event.relative.x / rect.size.x * view.size.x, -event.relative.y / rect.size.y * view.size.y)
		_clamp_pan()
		queue_redraw()
		accept_event()
		return
	if not _drag_handle.is_empty():
		_move_handle(_drag_handle, _to_data(event.position))
		accept_event()
		return
	var hovered: String = _pick(event.position)
	if hovered != _hover_handle:
		_hover_handle = hovered
		queue_redraw()


func _handle_button(event: InputEventMouseButton) -> void:
	var local: Vector2 = event.position
	if event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_UP:
		_zoom_at(local, ZOOM_STEP)
		accept_event()
		return
	if event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		_zoom_at(local, 1.0 / ZOOM_STEP)
		accept_event()
		return
	if event.button_index == MOUSE_BUTTON_MIDDLE:
		_panning = event.pressed and _pan_enabled
		accept_event()
		return
	if event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
		_remove_handle(_pick(local))
		accept_event()
		return
	if event.button_index != MOUSE_BUTTON_LEFT:
		return
	var picked: String = _pick(local)
	if event.pressed:
		if not picked.is_empty():
			_drag_handle = picked
			_hover_handle = picked
			edit_started.emit()
			queue_redraw()
		elif event.double_click and get_mode() == Core.SHAPE_POINTS:
			_add_point(_to_data(local))
		else:
			_panning = _pan_enabled
		accept_event()
		return
	if not _drag_handle.is_empty():
		_drag_handle = ""
		shape_changed.emit(get_shape())
	elif _panning:
		_panning = false
	queue_redraw()
	accept_event()


func _zoom_at(local: Vector2, factor: float) -> void:
	var before: Vector2 = _to_data(local)
	_zoom = clampf(_zoom * factor, ZOOM_MIN, ZOOM_MAX)
	var after: Vector2 = _to_data(local)
	_pan += before - after
	_clamp_pan()
	queue_redraw()


## 拖动某个手柄。各模型对手柄的自由度约束不同（贝塞尔的 x 夹在 0~1，弹性只取单轴）。
func _move_handle(id: String, data: Vector2) -> void:
	match get_mode():
		Core.SHAPE_BEZIER:
			_shape[id] = Vector2(clampf(data.x, 0.0, 1.0), clampf(data.y, Y_MIN, Y_MAX))
		Core.SHAPE_ELASTIC:
			if id == "amp":
				_shape["amplitude"] = clampf((data.y - AMP_BASE_Y) / AMP_Y_SCALE, AMP_MIN, AMP_MAX)
			elif id == "period":
				_shape["period"] = clampf(data.x, PERIOD_MIN, PERIOD_MAX)
		_:
			_move_point(int(id.substr(1)), data)
	queue_redraw()


## 多控制点：双击空白处加一个点（不要贴在首尾，方便继续拖动）。
func _add_point(data: Vector2) -> void:
	var points: PackedVector2Array = _shape.get("points", PackedVector2Array())
	points.append(Vector2(clampf(data.x, 0.02, 0.98), clampf(data.y, Y_MIN, Y_MAX)))
	_shape["points"] = Core.normalize_points(points)
	edit_started.emit()
	shape_changed.emit(get_shape())
	queue_redraw()


## 多控制点：拖动某个点，x 夹在左右邻点之间（首尾点的 x 锁死）。
func _move_point(index: int, data: Vector2) -> void:
	var points: PackedVector2Array = _shape.get("points", PackedVector2Array())
	if index < 0 or index >= points.size():
		return
	var point: Vector2 = data
	if index <= 0:
		point.x = 0.0
	elif index >= points.size() - 1:
		point.x = 1.0
	else:
		var left: float = points[index - 1].x + 0.01
		var right: float = points[index + 1].x - 0.01
		point.x = clampf(point.x, left, maxf(left, right))
	point.y = clampf(point.y, Y_MIN, Y_MAX)
	points[index] = point
	_shape["points"] = points


## 右键删除手柄：只有多控制点的中间点可删。
func _remove_handle(id: String) -> void:
	if get_mode() != Core.SHAPE_POINTS or not id.begins_with("p"):
		return
	var index: int = int(id.substr(1))
	var points: PackedVector2Array = _shape.get("points", PackedVector2Array())
	if index <= 0 or index >= points.size() - 1:
		return
	points.remove_at(index)
	_shape["points"] = points
	_drag_handle = ""
	_hover_handle = ""
	edit_started.emit()
	shape_changed.emit(get_shape())
	queue_redraw()
