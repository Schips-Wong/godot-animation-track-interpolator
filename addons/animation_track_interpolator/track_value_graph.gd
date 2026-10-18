@tool
extends Control
## 当前选中轨道的数值曲线可视化（参考 Blender 的曲线编辑器）。
##
## 横轴 = 时间（秒），纵轴 = 通道值。按轨道自身的插值方式（含关键帧 transition 缓动）
## 采样出每个通道的曲线，并在曲线上标出关键帧；蓝色底纹表示「生效范围」，
## 范围外的关键帧会被画暗（它们不会被插值改写）。
##
## 操作（统一的图表操作模式）：
## - 左键：单击选择关键帧点；按住「已经选中」的点拖动修改数值（左键不平移视图）；双击适配视图；
## - 右键：无动作；
## - 中键：单击无动作，按住拖动平移视图；
## - 滚轮：缩放（Ctrl 只缩放时间，Shift 只缩放数值）。

const Core: GDScript = preload("res://addons/animation_track_interpolator/track_interpolator_core.gd")

## 拖动关键帧点结束：把「修改前 / 修改后」的整条关键帧交给面板，走统一的撤销/重做。
signal keys_edited(track_index: int, key_index: int, before_keys: Array, after_keys: Array)

## 内边距：左侧留给数值标签，底部留给时间标签（实际底部还会按字体度量补足）。
const PAD_LEFT: float = 44.0
const PAD_RIGHT: float = 10.0
const PAD_TOP: float = 10.0
const PAD_BOTTOM: float = 26.0

const SAMPLES_PER_SEGMENT: int = 24
const KEY_RADIUS: float = 3.5
## 编辑模式下拾取关键帧点的半径（像素）。
const KEY_HIT_RADIUS: float = 9.0
const ZOOM_STEP: float = 1.2
const MIN_SPAN: float = 0.000001

const COLOR_BG: Color = Color(0.11, 0.11, 0.13)
const COLOR_BORDER: Color = Color(1.0, 1.0, 1.0, 0.18)
const COLOR_GRID: Color = Color(1.0, 1.0, 1.0, 0.07)
const COLOR_GRID_STRONG: Color = Color(1.0, 1.0, 1.0, 0.18)
const COLOR_TEXT: Color = Color(0.72, 0.76, 0.82, 0.9)
const COLOR_TEXT_DIM: Color = Color(0.6, 0.64, 0.7, 0.65)
const COLOR_RANGE: Color = Color(0.35, 0.62, 1.0, 0.1)
const COLOR_RANGE_EDGE: Color = Color(0.45, 0.72, 1.0, 0.5)
const COLOR_HOVER: Color = Color(1.0, 1.0, 1.0, 0.35)
const COLOR_PANEL_BG: Color = Color(0.06, 0.06, 0.08, 0.92)
const COLOR_KEY_ACTIVE: Color = Color(1.0, 0.85, 0.4)

const CHANNEL_COLORS: Array[Color] = [
	Color(1.0, 0.42, 0.42),
	Color(0.55, 0.9, 0.5),
	Color(0.45, 0.72, 1.0),
	Color(1.0, 0.8, 0.4),
]
const CHANNEL_NAMES: Array[String] = ["X", "Y", "Z", "W"]
const COLOR_CHANNEL_NAMES: Array[String] = ["R", "G", "B", "A"]
const SINGLE_CHANNEL_NAME: String = "值"

var _animation: Animation = null
var _track_index: int = -1

## 关键帧缓存（界面空间：旋转轨道已换成欧拉角（度），并做了展开避免 ±180° 跳变）。
var _times: PackedFloat64Array = PackedFloat64Array()
var _transitions: PackedFloat64Array = PackedFloat64Array()
var _channel_values: Array[PackedFloat64Array] = []
var _channel_names: PackedStringArray = PackedStringArray()
var _has_angle: bool = false
var _discrete: bool = false

## 生效范围（秒）；NaN 表示不显示。
var _range_from: float = NAN
var _range_to: float = NAN

## 视图（数据空间）。_user_view 为 true 时不再自动适配，直到调用 fit_view()。
var _view: Rect2 = Rect2(0.0, -1.0, 1.0, 2.0)
var _user_view: bool = false
var _panning: bool = false
var _hover_time: float = NAN
## 缓存的底部留白（只有字体变化时需要重算）。
var _bottom_pad_cache: float = PAD_BOTTOM

## 编辑模式与关键帧拖动状态。
var _edit_enabled: bool = false
var _hover_channel: int = -1
var _hover_index: int = -1
## 已选中的关键帧点；只有它才能被按住拖动。
var _selected_channel: int = -1
var _selected_index: int = -1
var _dragging_key: bool = false
var _drag_channel: int = -1
var _drag_index: int = -1
var _drag_start_value: float = 0.0
var _drag_value: float = 0.0
var _drag_start_y: float = 0.0
var _drag_start_local: Vector2 = Vector2.ZERO
var _drag_changed: bool = false
var _drag_start_channels: PackedFloat64Array = PackedFloat64Array()
var _drag_template: Variant = null
var _drag_initial_keys: Array = []


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	focus_mode = Control.FOCUS_NONE
	_update_bottom_pad()


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_RESIZED:
			if not _user_view:
				_fit_if_possible()
			queue_redraw()
		NOTIFICATION_THEME_CHANGED:
			_update_bottom_pad()
			queue_redraw()
		NOTIFICATION_MOUSE_EXIT:
			if not is_nan(_hover_time) or _hover_index >= 0:
				_hover_time = NAN
				_hover_channel = -1
				_hover_index = -1
				_update_cursor()
				queue_redraw()


# ---------------------------------------------------------------- 对外接口

## 设置要显示的轨道；animation 为 null 或 track_index < 0 时清空图表。
func set_track(animation: Animation, track_index: int) -> void:
	var same_source: bool = animation == _animation and track_index == _track_index
	if not same_source:
		if _dragging_key:
			_cancel_key_drag()
		_clear_selection()
		_disconnect_source()
		_animation = animation
		_track_index = track_index
		_connect_source()
	_rebuild(not same_source or not _user_view)


## 生效范围（秒）：范围外的关键帧会画暗。from >= to 时等价于清空。
func set_active_range(from_time: float, to_time: float) -> void:
	if from_time >= to_time:
		clear_active_range()
		return
	_range_from = from_time
	_range_to = to_time
	queue_redraw()


func clear_active_range() -> void:
	_range_from = NAN
	_range_to = NAN
	queue_redraw()


## 把视图适配到该轨道的全部关键帧。
func fit_view() -> void:
	_user_view = false
	_fit_if_possible()
	queue_redraw()


func has_data() -> bool:
	return not _times.is_empty() and not _channel_values.is_empty()


## 是否允许直接拖动关键帧点修改数值。
func set_edit_enabled(enabled: bool) -> void:
	if _edit_enabled == enabled:
		return
	if not enabled:
		_cancel_key_drag()
	_edit_enabled = enabled
	_hover_channel = -1
	_hover_index = -1
	_clear_selection()
	_update_cursor()
	queue_redraw()


func is_edit_enabled() -> bool:
	return _edit_enabled


# ---------------------------------------------------------------- 数据源

func _connect_source() -> void:
	if _animation == null or not is_instance_valid(_animation):
		return
	if not _animation.changed.is_connected(_on_source_changed):
		_animation.changed.connect(_on_source_changed)
	if _animation.has_signal("tracks_changed") and not _animation.tracks_changed.is_connected(_on_source_changed):
		_animation.tracks_changed.connect(_on_source_changed)


func _disconnect_source() -> void:
	if _animation == null or not is_instance_valid(_animation):
		return
	if _animation.changed.is_connected(_on_source_changed):
		_animation.changed.disconnect(_on_source_changed)
	if _animation.has_signal("tracks_changed") and _animation.tracks_changed.is_connected(_on_source_changed):
		_animation.tracks_changed.disconnect(_on_source_changed)


## 轨道关键帧被编辑器直接改动时也能跟上。
func _on_source_changed() -> void:
	if _animation == null or not is_instance_valid(_animation):
		_animation = null
		_track_index = -1
		_rebuild(true)
		return
	# 拖动过程中若外部改了关键帧，索引可能已经对不上，直接放弃这次拖动。
	if _dragging_key:
		_dragging_key = false
		_clear_drag_data()
		_hover_channel = -1
		_hover_index = -1
		_update_cursor()
	_rebuild(not _user_view)


## 读取轨道的全部关键帧并缓存。
func _rebuild(refit: bool) -> void:
	_times = PackedFloat64Array()
	_transitions = PackedFloat64Array()
	_channel_values.clear()
	_channel_names = PackedStringArray()
	_has_angle = false
	_discrete = false

	if _animation == null or not is_instance_valid(_animation):
		queue_redraw()
		return
	if _track_index < 0 or _track_index >= _animation.get_track_count():
		queue_redraw()
		return
	var count: int = _animation.track_get_key_count(_track_index)
	if count <= 0:
		queue_redraw()
		return
	var template: Variant = _animation.track_get_key_value(_track_index, 0)
	var channels: int = Core.edit_channel_count(template)
	if channels <= 0 or channels > CHANNEL_COLORS.size():
		queue_redraw()
		return

	_has_angle = Core.is_angle_edit(template)
	_discrete = _animation.track_get_interpolation_type(_track_index) == Animation.INTERPOLATION_NEAREST
	_channel_names = _build_channel_names(channels, template)
	for channel: int in range(channels):
		_channel_values.append(PackedFloat64Array())
	for i: int in range(count):
		_times.append(_animation.track_get_key_time(_track_index, i))
		_transitions.append(_animation.track_get_key_transition(_track_index, i))
		var values: PackedFloat64Array = Core.value_to_edit_channels(_animation.track_get_key_value(_track_index, i))
		for channel: int in range(channels):
			# Packed 数组是值类型：必须先取出来、改完再写回。
			var column: PackedFloat64Array = _channel_values[channel]
			column.append(values[channel] if channel < values.size() else 0.0)
			_channel_values[channel] = column
	if _has_angle:
		_unwrap_angles()
	# 选中的点可能因为外部增删关键帧而失效。
	if _selected_channel < 0 or _selected_channel >= _channel_values.size() \
			or _selected_index < 0 or _selected_index >= _times.size():
		_clear_selection()
	if _hover_channel < 0 or _hover_channel >= _channel_values.size() \
			or _hover_index < 0 or _hover_index >= _times.size():
		_hover_channel = -1
		_hover_index = -1
	if refit or _view.size.x <= MIN_SPAN or _view.size.y <= MIN_SPAN:
		_view = _compute_fit_view()
	queue_redraw()


func _build_channel_names(channels: int, template: Variant) -> PackedStringArray:
	if channels == 1:
		return PackedStringArray([SINGLE_CHANNEL_NAME])
	var source: Array[String] = COLOR_CHANNEL_NAMES if typeof(template) == TYPE_COLOR else CHANNEL_NAMES
	var names: PackedStringArray = PackedStringArray()
	for i: int in range(channels):
		names.append(source[i])
	return names


## 旋转轨道按欧拉角显示：逐帧取最短角度差展开，曲线才不会在 ±180° 处来回跳。
func _unwrap_angles() -> void:
	for channel: int in range(_channel_values.size()):
		var values: PackedFloat64Array = _channel_values[channel]
		if values.size() < 2:
			continue
		var previous_raw: float = values[0]
		for i: int in range(1, values.size()):
			var raw: float = values[i]
			values[i] = values[i - 1] + Core.shortest_delta(previous_raw, raw)
			previous_raw = raw
		_channel_values[channel] = values


# ---------------------------------------------------------------- 视图换算

func _plot_rect() -> Rect2:
	var width: float = maxf(size.x - PAD_LEFT - PAD_RIGHT, 1.0)
	var height: float = maxf(size.y - PAD_TOP - _bottom_pad(), 1.0)
	return Rect2(PAD_LEFT, PAD_TOP, width, height)


## 底部留白：至少要放得下时间标签的上沿 + 下沿（不同编辑器字体大小都能完整显示）。
func _bottom_pad() -> float:
	return _bottom_pad_cache


func _update_bottom_pad() -> void:
	var font: Font = get_theme_default_font()
	if font == null:
		_bottom_pad_cache = PAD_BOTTOM
		return
	var font_size: int = maxi(get_theme_default_font_size() - 1, 8)
	_bottom_pad_cache = maxf(PAD_BOTTOM, font.get_ascent(font_size) + font.get_descent(font_size) + 8.0)


func _to_local(point: Vector2) -> Vector2:
	var plot: Rect2 = _plot_rect()
	var u: float = (point.x - _view.position.x) / maxf(_view.size.x, MIN_SPAN)
	var v: float = (point.y - _view.position.y) / maxf(_view.size.y, MIN_SPAN)
	return Vector2(plot.position.x + u * plot.size.x, plot.end.y - v * plot.size.y)


func _to_data(local: Vector2) -> Vector2:
	var plot: Rect2 = _plot_rect()
	var u: float = (local.x - plot.position.x) / maxf(plot.size.x, 1.0)
	var v: float = (plot.end.y - local.y) / maxf(plot.size.y, 1.0)
	return Vector2(_view.position.x + u * _view.size.x, _view.position.y + v * _view.size.y)


func _fit_if_possible() -> void:
	if _times.is_empty():
		_view = Rect2(0.0, -1.0, 1.0, 2.0)
		return
	_view = _compute_fit_view()


## 自动适配：时间取关键帧跨度，数值取所有通道的极值（留一点边距）。
func _compute_fit_view() -> Rect2:
	var x_min: float = _times[0]
	var x_max: float = _times[_times.size() - 1]
	if x_max - x_min <= MIN_SPAN:
		x_max = x_min + 1.0
	var y_min: float = INF
	var y_max: float = -INF
	for column: PackedFloat64Array in _channel_values:
		for value: float in column:
			y_min = minf(y_min, value)
			y_max = maxf(y_max, value)
	if not is_finite(y_min) or not is_finite(y_max):
		y_min = -1.0
		y_max = 1.0
	if y_max - y_min <= MIN_SPAN:
		var grow: float = maxf(absf(y_max) * 0.25, 0.5)
		y_min -= grow
		y_max += grow
	else:
		var pad_y: float = (y_max - y_min) * 0.12
		y_min -= pad_y
		y_max += pad_y
	var pad_x: float = (x_max - x_min) * 0.02
	return Rect2(Vector2(x_min - pad_x, y_min), Vector2(x_max - x_min + pad_x * 2.0, y_max - y_min))


# ---------------------------------------------------------------- 采样

## 关键帧之间的取值：线性 + 关键帧 transition 缓动（与 Godot 的过渡一致）。
func _sample_in_segment(channel: int, key_index: int, time: float) -> float:
	var values: PackedFloat64Array = _channel_values[channel]
	if key_index + 1 >= _times.size():
		return values[values.size() - 1]
	var span: float = _times[key_index + 1] - _times[key_index]
	if span <= MIN_SPAN:
		return values[key_index + 1]
	if _discrete:
		return values[key_index]
	var t: float = clampf((time - _times[key_index]) / span, 0.0, 1.0)
	return lerpf(values[key_index], values[key_index + 1], _ease_weight(t, _transitions[key_index]))


func _sample_channel(channel: int, time: float) -> float:
	var values: PackedFloat64Array = _channel_values[channel]
	if values.is_empty():
		return 0.0
	if time <= _times[0]:
		return values[0]
	if time >= _times[_times.size() - 1]:
		return values[values.size() - 1]
	# 二分找到 time 所在的区间。
	var low: int = 0
	var high: int = _times.size() - 1
	while high - low > 1:
		var mid: int = (low + high) >> 1
		if _times[mid] <= time:
			low = mid
		else:
			high = mid
	return _sample_in_segment(channel, low, time)


## 与 Godot 的 Math::ease 一致：transition = 1 为线性。
static func _ease_weight(t: float, transition: float) -> float:
	return _ease(clampf(t, 0.0, 1.0), transition)


static func _ease(x: float, curve: float) -> float:
	if x <= 0.0:
		return 0.0
	if x >= 1.0:
		return 1.0
	if curve > 0.0:
		if curve < 1.0:
			return 1.0 - pow(1.0 - x, 1.0 / curve)
		return pow(x, curve)
	if curve < 0.0:
		return 1.0 - _ease(1.0 - x, -curve)
	return 0.0


# ---------------------------------------------------------------- 绘制

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), COLOR_BG, true)
	var plot: Rect2 = _plot_rect()
	if not has_data():
		_draw_empty(plot)
		draw_rect(plot, COLOR_BORDER, false, 1.0)
		return
	_draw_range(plot)
	_draw_grid(plot)
	_draw_curves()
	_draw_keys(plot)
	if _dragging_key:
		_draw_drag_guide(plot)
	_draw_legend(plot)
	if not is_nan(_hover_time):
		_draw_hover(plot)
	draw_rect(plot, COLOR_BORDER, false, 1.0)


func _draw_empty(plot: Rect2) -> void:
	var font: Font = get_theme_default_font()
	if font == null:
		return
	draw_string(
		font,
		Vector2(plot.position.x, plot.position.y + plot.size.y * 0.5),
		"选择数值轨道后显示曲线",
		HORIZONTAL_ALIGNMENT_CENTER,
		plot.size.x,
		get_theme_default_font_size(),
		COLOR_TEXT_DIM
	)


## 生效范围底纹与两条边界虚线。
func _draw_range(plot: Rect2) -> void:
	if not _has_range():
		return
	var left: float = clampf(_to_local(Vector2(_range_from, 0.0)).x, plot.position.x, plot.end.x)
	var right: float = clampf(_to_local(Vector2(_range_to, 0.0)).x, plot.position.x, plot.end.x)
	if right <= left:
		return
	draw_rect(Rect2(left, plot.position.y, right - left, plot.size.y), COLOR_RANGE, true)
	for x: float in [left, right]:
		draw_dashed_line(Vector2(x, plot.position.y), Vector2(x, plot.end.y), COLOR_RANGE_EDGE, 1.0, 4.0)


func _draw_grid(plot: Rect2) -> void:
	var font: Font = get_theme_default_font()
	var font_size: int = maxi(get_theme_default_font_size() - 1, 8)

	var x_step: float = _nice_step(_view.size.x, maxf(plot.size.x / 74.0, 2.0))
	# 时间标签以基线定位：基线 = 绘图区底部 + 字体上沿，给下沿（下沉部分）留出空间。
	var ascent: float = font.get_ascent(font_size) if font != null else 0.0
	var time_baseline: float = plot.end.y + ascent + 2.0
	var x: float = ceilf(_view.position.x / x_step) * x_step
	while x <= _view.end.x + MIN_SPAN:
		var px: float = _to_local(Vector2(x, 0.0)).x
		draw_line(
			Vector2(px, plot.position.y),
			Vector2(px, plot.end.y),
			COLOR_GRID_STRONG if is_zero_approx(x) else COLOR_GRID,
			1.0
		)
		if font != null:
			var text: String = _format_number(x, x_step) + "s"
			var text_width: float = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
			# 夹在控件内，避免首尾的时间标签被左右边缘裁掉一半。
			var label_left: float = clampf(px - text_width * 0.5, 0.0, maxf(size.x - text_width, 0.0))
			draw_string(
				font,
				Vector2(label_left, time_baseline),
				text,
				HORIZONTAL_ALIGNMENT_LEFT,
				-1,
				font_size,
				COLOR_TEXT_DIM
			)
		x += x_step

	var y_step: float = _nice_step(_view.size.y, maxf(plot.size.y / 34.0, 2.0))
	var y: float = ceilf(_view.position.y / y_step) * y_step
	while y <= _view.end.y + MIN_SPAN:
		var py: float = _to_local(Vector2(0.0, y)).y
		draw_line(
			Vector2(plot.position.x, py),
			Vector2(plot.end.x, py),
			COLOR_GRID_STRONG if is_zero_approx(y) else COLOR_GRID,
			1.0
		)
		if font != null:
			draw_string(
				font,
				Vector2(0.0, py + float(font_size) * 0.36),
				_format_number(y, y_step) + ("°" if _has_angle else ""),
				HORIZONTAL_ALIGNMENT_RIGHT,
				PAD_LEFT - 6.0,
				font_size,
				COLOR_TEXT_DIM
			)
		y += y_step


func _draw_curves() -> void:
	for channel: int in range(_channel_values.size()):
		var points: PackedVector2Array = _build_polyline(channel)
		if points.size() >= 2:
			draw_polyline(points, CHANNEL_COLORS[channel], 1.8, true)


func _build_polyline(channel: int) -> PackedVector2Array:
	var points: PackedVector2Array = PackedVector2Array()
	for i: int in range(_times.size() - 1):
		# 只采样落在可视范围内的部分。
		var from_time: float = maxf(_times[i], _view.position.x)
		var to_time: float = minf(_times[i + 1], _view.end.x)
		if to_time < from_time:
			continue
		for step: int in range(SAMPLES_PER_SEGMENT + 1):
			var time: float = lerpf(from_time, to_time, float(step) / float(SAMPLES_PER_SEGMENT))
			points.append(_to_local(Vector2(time, _sample_in_segment(channel, i, time))))
	return points


func _draw_keys(plot: Rect2) -> void:
	for i: int in range(_times.size()):
		var in_range: bool = _is_time_in_range(_times[i])
		for channel: int in range(_channel_values.size()):
			var point: Vector2 = _to_local(Vector2(_times[i], _channel_values[channel][i]))
			if point.x < plot.position.x - 1.0 or point.x > plot.end.x + 1.0:
				continue
			if point.y < plot.position.y - 1.0 or point.y > plot.end.y + 1.0:
				continue
			var color: Color = CHANNEL_COLORS[channel]
			if not in_range:
				color.a = 0.3
			var selected: bool = channel == _selected_channel and i == _selected_index
			var dragging: bool = _dragging_key and channel == _drag_channel and i == _drag_index
			var hovered: bool = _edit_enabled and channel == _hover_channel and i == _hover_index
			if selected or dragging:
				draw_circle(point, KEY_RADIUS + 1.5, color)
				draw_arc(point, KEY_RADIUS + 4.0, 0.0, TAU, 24, COLOR_KEY_ACTIVE, 2.0, true)
			elif hovered:
				draw_circle(point, KEY_RADIUS + 1.0, color)
				draw_arc(point, KEY_RADIUS + 3.0, 0.0, TAU, 20, Color(1.0, 1.0, 1.0, 0.55), 1.0, true)
			else:
				draw_circle(point, KEY_RADIUS, color)


## 拖动关键帧时画一条水平参考线，方便对齐数值。
func _draw_drag_guide(plot: Rect2) -> void:
	var y: float = _to_local(Vector2(0.0, _drag_value)).y
	if y < plot.position.y or y > plot.end.y:
		return
	draw_dashed_line(Vector2(plot.position.x, y), Vector2(plot.end.x, y), COLOR_KEY_ACTIVE, 1.0, 4.0)


## 右上角的通道图例（X / Y / Z / W 或「值」）。
func _draw_legend(plot: Rect2) -> void:
	var font: Font = get_theme_default_font()
	if font == null:
		return
	var font_size: int = maxi(get_theme_default_font_size() - 2, 8)
	var total: float = 0.0
	var widths: PackedFloat64Array = PackedFloat64Array()
	for channel: int in range(_channel_values.size()):
		var text: String = _channel_names[channel]
		var width: float = 14.0 + font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		widths.append(width)
		total += width
	var left: float = plot.end.x - total - 4.0
	var top: float = plot.position.y + 3.0
	draw_rect(Rect2(left - 4.0, top, total + 6.0, float(font_size) + 6.0), COLOR_PANEL_BG, true)
	var x: float = left
	for channel: int in range(_channel_values.size()):
		draw_rect(Rect2(x, top + 4.0, 7.0, 7.0), CHANNEL_COLORS[channel], true)
		draw_string(
			font,
			Vector2(x + 11.0, top + float(font_size) + 1.0),
			_channel_names[channel],
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			font_size,
			COLOR_TEXT
		)
		x += widths[channel]


## 悬停读数：竖直游标 + 各通道在该时刻的取值。
func _draw_hover(plot: Rect2) -> void:
	var x: float = _to_local(Vector2(_hover_time, 0.0)).x
	if x < plot.position.x or x > plot.end.x:
		return
	draw_line(Vector2(x, plot.position.y), Vector2(x, plot.end.y), COLOR_HOVER, 1.0)
	var font: Font = get_theme_default_font()
	var font_size: int = maxi(get_theme_default_font_size() - 2, 8)
	var lines: PackedStringArray = PackedStringArray()
	lines.append("t = %s s" % _format_number(_hover_time, 0.001))
	for channel: int in range(_channel_values.size()):
		var value: float = _sample_channel(channel, _hover_time)
		var y: float = _to_local(Vector2(_hover_time, value)).y
		if y >= plot.position.y and y <= plot.end.y:
			draw_circle(Vector2(x, y), 3.0, CHANNEL_COLORS[channel])
		var suffix: String = "°" if _has_angle else ""
		lines.append("%s  %s%s" % [_channel_names[channel], _format_number(value, 0.0001), suffix])
	if font == null:
		return
	var width: float = 0.0
	for line: String in lines:
		width = maxf(width, font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x)
	var box: Rect2 = Rect2(
		plot.position.x + 5.0,
		plot.position.y + 5.0,
		width + 10.0,
		float(font_size + 2) * lines.size() + 6.0
	)
	draw_rect(box, COLOR_PANEL_BG, true)
	for i: int in range(lines.size()):
		draw_string(
			font,
			Vector2(box.position.x + 5.0, box.position.y + 4.0 + float(font_size) * (i + 1)),
			lines[i],
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			font_size,
			COLOR_TEXT
		)


# ---------------------------------------------------------------- 辅助

func _has_range() -> bool:
	return not is_nan(_range_from) and not is_nan(_range_to) and _range_to > _range_from


func _is_time_in_range(time: float) -> bool:
	if not _has_range():
		return true
	return time >= _range_from - MIN_SPAN and time <= _range_to + MIN_SPAN


## 网格步长取 1 / 2 / 5 × 10^n，让可见范围内大致保持 target 格。
static func _nice_step(span: float, target: float) -> float:
	if span <= MIN_SPAN or target <= 0.0:
		return 1.0
	var raw: float = span / target
	var magnitude: float = pow(10.0, floorf(log(raw) / log(10.0)))
	var normalized: float = raw / magnitude
	var step: float = 10.0
	if normalized <= 1.0:
		step = 1.0
	elif normalized <= 2.0:
		step = 2.0
	elif normalized <= 5.0:
		step = 5.0
	return step * magnitude


## 按步长决定小数位，避免坐标标签出现一长串尾数。
static func _format_number(value: float, step: float) -> String:
	var digits: int = 0
	if step < 1.0 and step > 0.0:
		digits = clampi(int(ceil(-log(step) / log(10.0))), 0, 4)
	var text: String = String.num(value, digits)
	# 把 "-0" / "-0.0" 统一成 "0"。
	if text.begins_with("-") and is_zero_approx(text.to_float()):
		text = text.substr(1)
	return text


# ---------------------------------------------------------------- 交互

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var motion: InputEventMouseMotion = event
		if _dragging_key:
			_drag_key_to(motion.position)
			accept_event()
			return
		if _panning:
			_pan_by(motion.relative)
			_user_view = true
		_update_hover(motion.position)
		accept_event()
		return
	if event is InputEventMouseButton:
		_handle_mouse_button(event)


func _handle_mouse_button(event: InputEventMouseButton) -> void:
	var plot: Rect2 = _plot_rect()
	match event.button_index:
		MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN:
			if _dragging_key or not event.pressed or not plot.has_point(event.position):
				return
			var factor: float = ZOOM_STEP if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / ZOOM_STEP
			var zoom_time: bool = not event.shift_pressed
			var zoom_value: bool = not event.ctrl_pressed
			if not zoom_time and not zoom_value:
				zoom_time = true
				zoom_value = true
			_zoom_at(event.position, factor, zoom_time, zoom_value)
			accept_event()
		MOUSE_BUTTON_LEFT:
			# 左键：单击选择；按住已选中的点才拖动（左键永远不平移视图）；双击适配视图。
			if event.pressed:
				if _panning:
					return
				if event.double_click:
					fit_view()
				elif _edit_enabled and plot.has_point(event.position):
					var pick: Dictionary = _pick_key(event.position)
					if pick.is_empty():
						_clear_selection()
					else:
						var channel: int = int(pick["channel"])
						var index: int = int(pick["index"])
						if channel == _selected_channel and index == _selected_index:
							_begin_key_drag(channel, index, event.position)
						else:
							_select_key(channel, index)
			elif _dragging_key:
				_finish_key_drag()
			accept_event()
		MOUSE_BUTTON_MIDDLE:
			# 中键：按住拖拽平移视图，单击无动作。
			if event.pressed:
				if not _dragging_key and plot.has_point(event.position):
					_panning = true
			else:
				_panning = false
			_update_cursor()
			accept_event()


func _update_hover(local: Vector2) -> void:
	var plot: Rect2 = _plot_rect()
	var inside: bool = plot.has_point(local)
	var time: float = _to_data(local).x if inside else NAN
	var previous_time: float = _hover_time
	var previous_channel: int = _hover_channel
	var previous_index: int = _hover_index
	_hover_time = time
	if _edit_enabled and inside:
		var pick: Dictionary = _pick_key(local)
		_hover_channel = int(pick.get("channel", -1))
		_hover_index = int(pick.get("index", -1))
	else:
		_hover_channel = -1
		_hover_index = -1
	_update_cursor()
	var same_time: bool = (
		is_nan(previous_time) == is_nan(_hover_time)
		and (is_nan(_hover_time) or is_equal_approx(previous_time, _hover_time))
	)
	if same_time and previous_channel == _hover_channel and previous_index == _hover_index:
		return
	queue_redraw()


## 找出光标附近的关键帧点；返回 {"channel": int, "index": int}，没有则空字典。
func _pick_key(local: Vector2) -> Dictionary:
	if not _edit_enabled or _channel_values.is_empty():
		return {}
	var plot: Rect2 = _plot_rect()
	if not plot.has_point(local):
		return {}
	var best: Dictionary = {}
	var best_distance: float = KEY_HIT_RADIUS
	for i: int in range(_times.size()):
		for channel: int in range(_channel_values.size()):
			var point: Vector2 = _to_local(Vector2(_times[i], _channel_values[channel][i]))
			var distance: float = point.distance_to(local)
			if distance <= best_distance:
				best_distance = distance
				best = {"channel": channel, "index": i}
	return best


func _update_cursor() -> void:
	if _dragging_key or _panning:
		mouse_default_cursor_shape = Control.CURSOR_DRAG
	elif _edit_enabled and _hover_index >= 0:
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	else:
		mouse_default_cursor_shape = Control.CURSOR_ARROW


## 单击选择一个关键帧点；只有选中的点才允许按住拖动。
func _select_key(channel: int, index: int) -> void:
	_selected_channel = channel
	_selected_index = index
	_hover_channel = channel
	_hover_index = index
	queue_redraw()


func _clear_selection() -> void:
	if _selected_channel == -1 and _selected_index == -1:
		return
	_selected_channel = -1
	_selected_index = -1
	queue_redraw()


# ---------------------------------------------------------------- 关键帧拖动

func _begin_key_drag(channel: int, index: int, local: Vector2) -> void:
	if _animation == null or not is_instance_valid(_animation):
		return
	if index < 0 or index >= _times.size() or channel < 0 or channel >= _channel_values.size():
		return
	var template: Variant = _animation.track_get_key_value(_track_index, index)
	var channels: PackedFloat64Array = Core.value_to_edit_channels(template)
	if channel >= channels.size():
		return
	_dragging_key = true
	_drag_changed = false
	_drag_channel = channel
	_drag_index = index
	_drag_start_value = _channel_values[channel][index]
	_drag_value = _drag_start_value
	_drag_start_y = _to_data(local).y
	_drag_start_local = local
	_drag_template = template
	_drag_start_channels = channels
	_drag_initial_keys = Core.capture_keys(_animation, _track_index)
	_hover_time = _times[index]
	_hover_channel = channel
	_hover_index = index
	_update_cursor()
	queue_redraw()


## 只按竖直方向拖动改数值；时间保持不变。
func _drag_key_to(local: Vector2) -> void:
	var data_y: float = _to_data(local).y
	var new_value: float = _drag_start_value + (data_y - _drag_start_y)
	var column: PackedFloat64Array = _channel_values[_drag_channel]
	column[_drag_index] = new_value
	_channel_values[_drag_channel] = column
	_drag_value = new_value
	if absf(local.y - _drag_start_local.y) > 0.5:
		if not _drag_changed:
			# 真的改动过数值后就不再自动适配视图，避免提交时视图跳动。
			_user_view = true
		_drag_changed = true
	_hover_time = _times[_drag_index]
	queue_redraw()


func _finish_key_drag() -> void:
	if not _dragging_key:
		return
	var channel: int = _drag_channel
	var index: int = _drag_index
	var value: float = _drag_value
	var changed: bool = _drag_changed and absf(value - _drag_start_value) > MIN_SPAN
	var channels: PackedFloat64Array = _drag_start_channels.duplicate()
	var template: Variant = _drag_template
	var before_keys: Array = _drag_initial_keys
	var track: int = _track_index
	_dragging_key = false
	_update_cursor()
	_clear_drag_data()

	if not changed or template == null or channels.is_empty() or channel < 0 or channel >= channels.size():
		_rebuild(false)
		return
	if _animation == null or not is_instance_valid(_animation) or track < 0 or track >= _animation.get_track_count():
		_rebuild(false)
		return
	if index < 0 or index >= before_keys.size() or index >= _animation.track_get_key_count(track):
		_rebuild(false)
		return
	# 期间若关键帧被外部改动（索引/时间对不上），放弃这次编辑。
	if not is_equal_approx(_animation.track_get_key_time(track, index), _times[index]):
		_rebuild(false)
		return
	channels[channel] = value
	var new_value: Variant = Core.edit_channels_to_value(template, channels)
	if new_value == null:
		_rebuild(false)
		return
	var after_keys: Array = before_keys.duplicate(true)
	var entry: Dictionary = after_keys[index]
	entry["value"] = new_value
	after_keys[index] = entry
	keys_edited.emit(track, index, before_keys, after_keys)
	_rebuild(false)


## 取消拖动（关闭编辑模式 / 数据源变化时）：丢弃预览值。
func _cancel_key_drag() -> void:
	if not _dragging_key:
		return
	_dragging_key = false
	_update_cursor()
	_clear_drag_data()
	_rebuild(false)


func _clear_drag_data() -> void:
	_drag_changed = false
	_drag_channel = -1
	_drag_index = -1
	_drag_start_channels = PackedFloat64Array()
	_drag_initial_keys = []
	_drag_template = null


func _pan_by(relative: Vector2) -> void:
	var plot: Rect2 = _plot_rect()
	if plot.size.x <= 0.0 or plot.size.y <= 0.0:
		return
	_view.position.x -= relative.x / plot.size.x * _view.size.x
	_view.position.y += relative.y / plot.size.y * _view.size.y
	queue_redraw()


func _zoom_at(local: Vector2, factor: float, zoom_time: bool, zoom_value: bool) -> void:
	if _times.is_empty():
		return
	var before: Vector2 = _to_data(local)
	if zoom_time:
		_view.size.x = maxf(_view.size.x / factor, MIN_SPAN)
	if zoom_value:
		_view.size.y = maxf(_view.size.y / factor, MIN_SPAN)
	var after: Vector2 = _to_data(local)
	# 让光标下的数值在缩放前后保持不动。
	_view.position += before - after
	queue_redraw()
