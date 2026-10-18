@tool
extends VBoxContainer
## 动画轨道插值器停靠面板。
##
## 选择「当前编辑场景」里的 AnimationPlayer → 动画 → 数值轨道，
## 然后按指定的过渡方式，把该轨道的关键帧从「起始值」平滑过渡到「终点值」。

const Core: GDScript = preload("res://addons/animation_track_interpolator/track_interpolator_core.gd")
const CurveCanvas: GDScript = preload("res://addons/animation_track_interpolator/curve_editor.gd")

const COLOR_OK: Color = Color(0.62, 0.87, 0.62)
const COLOR_ERROR: Color = Color(1.0, 0.55, 0.45)

const SPIN_COUNT: int = 4
const POLL_INTERVAL: float = 0.5

var _players: Array[AnimationPlayer] = []
var _animations: Array[Animation] = []
var _animation_names: PackedStringArray = PackedStringArray()

var _player: AnimationPlayer = null
var _animation: Animation = null
var _animation_name: String = ""
var _track_index: int = -1
var _spin_from: Array[SpinBox] = []
var _spin_to: Array[SpinBox] = []
var _checks: Array[CheckBox] = []
var _poll_accumulator: float = 0.0
var _known_scene_id: int = 0
## 工具条「复制 / 粘贴」用的曲线剪贴板。
var _curve_clipboard: Dictionary = {}
## 「插值方式」里最后一次选中的预设（不含「自定义曲线」）。
## 「多控制点」重置时用它回退，避免下拉停在「自定义曲线」时无从下手。
var _last_preset: int = Core.CURVE_LINEAR

@onready var _player_option: OptionButton = %PlayerOption
@onready var _refresh_button: Button = %RefreshButton
@onready var _anim_option: OptionButton = %AnimOption
@onready var _track_option: OptionButton = %TrackOption
@onready var _position_track_check: CheckBox = %PositionTrackCheck
@onready var _rotation_track_check: CheckBox = %RotationTrackCheck
@onready var _scale_track_check: CheckBox = %ScaleTrackCheck
@onready var _info_label: Label = %InfoLabel
@onready var _curve_option: OptionButton = %CurveOption
@onready var _curve_canvas: CurveCanvas = %CurveCanvas
@onready var _mode_points_button: Button = %ModePointsButton
@onready var _mode_bezier_button: Button = %ModeBezierButton
@onready var _mode_elastic_button: Button = %ModeElasticButton
@onready var _curve_mirror_button: Button = %CurveMirrorButton
@onready var _mirror_mode_option: OptionButton = %MirrorModeOption
@onready var _curve_copy_button: Button = %CurveCopyButton
@onready var _curve_paste_button: Button = %CurvePasteButton
@onready var _curve_ease_button: Button = %CurveEaseButton
@onready var _curve_auto_button: Button = %CurveAutoButton
@onready var _curve_view_button: Button = %CurveViewButton
@onready var _curve_drag_check: CheckBox = %CurveDragCheck
@onready var _curve_graph_reset_button: Button = %CurveGraphResetButton
@onready var _range_from_spin: SpinBox = %RangeFromSpin
@onready var _range_to_spin: SpinBox = %RangeToSpin
@onready var _reset_range_animation_button: Button = %ResetRangeToAnimationButton
@onready var _reset_range_track_button: Button = %ResetRangeToTrackButton
@onready var _from_x: SpinBox = %FromX
@onready var _from_y: SpinBox = %FromY
@onready var _from_z: SpinBox = %FromZ
@onready var _from_w: SpinBox = %FromW
@onready var _to_x: SpinBox = %ToX
@onready var _to_y: SpinBox = %ToY
@onready var _to_z: SpinBox = %ToZ
@onready var _to_w: SpinBox = %ToW
@onready var _value_grid: GridContainer = %ValueGrid
@onready var _check_x: CheckBox = %CheckX
@onready var _check_y: CheckBox = %CheckY
@onready var _check_z: CheckBox = %CheckZ
@onready var _check_w: CheckBox = %CheckW
@onready var _reload_button: Button = %ReloadValuesButton
@onready var _keep_ends_check: CheckButton = %KeepOnlyEndsCheck
@onready var _apply_button: Button = %ApplyButton
@onready var _apply_all_button: Button = %ApplyAllButton
@onready var _status_label: Label = %StatusLabel


func _ready() -> void:
	_spin_from.append(_from_x)
	_spin_from.append(_from_y)
	_spin_from.append(_from_z)
	_spin_from.append(_from_w)
	_spin_to.append(_to_x)
	_spin_to.append(_to_y)
	_spin_to.append(_to_z)
	_spin_to.append(_to_w)
	_checks.append(_check_x)
	_checks.append(_check_y)
	_checks.append(_check_z)
	_checks.append(_check_w)
	_setup_spins(_spin_from)
	_setup_spins(_spin_to)
	_setup_range_spins()
	for range_spin: SpinBox in [_range_from_spin, _range_to_spin]:
		range_spin.value_changed.connect(_on_range_changed)
	_reset_range_animation_button.pressed.connect(_on_reset_range_to_animation)
	_reset_range_track_button.pressed.connect(_on_reset_range_to_track)
	for check: CheckBox in _checks:
		check.toggled.connect(_on_channel_toggled)
	_sync_channel_editability()

	_curve_option.clear()
	var labels: PackedStringArray = Core.curve_labels()
	for i: int in range(labels.size()):
		if i == Core.CURVE_CUSTOM:
			_curve_option.add_separator()
		_curve_option.add_item(labels[i], i)
	_curve_option.select(Core.CURVE_LINEAR)
	_curve_option.item_selected.connect(_on_curve_selected)
	_setup_curve_tools()
	_curve_canvas.edit_started.connect(_on_curve_edit_started)
	_curve_canvas.shape_changed.connect(_on_curve_shape_changed)
	_curve_canvas.set_preset_points(Core.preset_points(Core.CURVE_LINEAR))

	_refresh_button.pressed.connect(_on_refresh_pressed)
	_player_option.item_selected.connect(_on_player_selected)
	_anim_option.item_selected.connect(_on_animation_selected)
	_track_option.item_selected.connect(_on_track_selected)
	for filter_check: CheckBox in [_position_track_check, _rotation_track_check, _scale_track_check]:
		filter_check.toggled.connect(_on_track_filter_toggled)
	_reload_button.pressed.connect(_on_reload_values_pressed)
	_apply_button.pressed.connect(_on_apply_pressed)
	_apply_all_button.pressed.connect(_on_apply_all_pressed)
	_keep_ends_check.toggled.connect(_on_keep_ends_toggled)

	var selection: EditorSelection = EditorInterface.get_selection()
	if selection != null and not selection.selection_changed.is_connected(_on_editor_selection_changed):
		selection.selection_changed.connect(_on_editor_selection_changed)

	_set_status("选择 AnimationPlayer、动画与轨道后即可应用。", true)
	_refresh_players()
	var root: Node = EditorInterface.get_edited_scene_root()
	if root != null:
		_known_scene_id = int(root.get_instance_id())
	set_process(true)


func _exit_tree() -> void:
	set_process(false)
	var selection: EditorSelection = EditorInterface.get_selection()
	if selection != null and selection.selection_changed.is_connected(_on_editor_selection_changed):
		selection.selection_changed.disconnect(_on_editor_selection_changed)


## EditorInterface 没有场景切换信号，靠轮询 instance id 检测「当前编辑场景」变化。
func _process(delta: float) -> void:
	_poll_accumulator += delta
	if _poll_accumulator < POLL_INTERVAL:
		return
	_poll_accumulator = 0.0
	var root: Node = EditorInterface.get_edited_scene_root()
	var scene_id: int = 0
	if root != null:
		scene_id = int(root.get_instance_id())
	if scene_id != _known_scene_id:
		_known_scene_id = scene_id
		_refresh_players()


func _setup_spins(spins: Array[SpinBox]) -> void:
	for spin: SpinBox in spins:
		spin.allow_greater = true
		spin.allow_lesser = true
		spin.select_all_on_focus = true
		_configure_spin(spin, false)


## 生效范围两个输入框：以秒为单位。
func _setup_range_spins() -> void:
	for spin: SpinBox in [_range_from_spin, _range_to_spin]:
		spin.min_value = -100000.0
		spin.max_value = 100000.0
		spin.allow_greater = true
		spin.allow_lesser = true
		spin.step = 0.01
		spin.custom_arrow_step = 0.1
		spin.select_all_on_focus = true
		spin.suffix = " s"


## 旋转轨道用欧拉角（度）编辑：步长、后缀、取值范围都换成角度制。
func _configure_spin(spin: SpinBox, angle: bool) -> void:
	if angle:
		spin.min_value = -3600.0
		spin.max_value = 3600.0
		spin.step = 0.1
		spin.custom_arrow_step = 1.0
		spin.suffix = "°"
		spin.set_tooltip_text("该通道的欧拉角（度）")
	else:
		spin.min_value = -1000000.0
		spin.max_value = 1000000.0
		spin.step = 0.001
		spin.custom_arrow_step = 0.01
		spin.suffix = ""
		spin.set_tooltip_text("该通道的数值（勾选左侧复选框后才能修改）")


## 每个通道只有一组勾选框，同时决定起始值与终点值能否修改。
func _sync_channel_editability() -> void:
	for i: int in range(SPIN_COUNT):
		_spin_from[i].editable = _checks[i].button_pressed
		_spin_to[i].editable = _checks[i].button_pressed


## 通道掩码：1 = 该通道参与修改。
func _channel_mask(channels: int) -> PackedByteArray:
	var mask: PackedByteArray = PackedByteArray()
	for i: int in range(mini(channels, SPIN_COUNT)):
		mask.append(1 if _checks[i].button_pressed else 0)
	return mask


# ---------------------------------------------------------------- 列表刷新

func _refresh_players() -> void:
	var previous_player: AnimationPlayer = _player
	var previous_animation: String = _animation_name
	_players.clear()
	_player_option.clear()
	_player = null
	_animation = null

	var root: Node = EditorInterface.get_edited_scene_root()
	if root != null:
		var root_player: AnimationPlayer = root as AnimationPlayer
		if root_player != null:
			_players.append(root_player)
		for node: Node in root.find_children("*", "AnimationPlayer", true, false):
			var player: AnimationPlayer = node as AnimationPlayer
			if player != null and not _players.has(player):
				_players.append(player)
	_players.sort_custom(_compare_players)

	for player: AnimationPlayer in _players:
		var label: String = player.name
		if root != null:
			label = String(root.get_path_to(player))
		_player_option.add_item(label)
	_player_option.disabled = _players.is_empty()

	var wanted: int = -1
	if previous_player != null:
		wanted = _players.find(previous_player)
	if wanted == -1:
		wanted = _pick_player_from_selection()
	if wanted == -1 and not _players.is_empty():
		wanted = 0
	if wanted == -1:
		_clear_tracks()
		#_info_label.text = "当前编辑场景里没有 AnimationPlayer。"
		_set_status("没有可用的 AnimationPlayer。", false)
		return
	_player_option.select(wanted)
	_player = _players[wanted]
	_refresh_animations(previous_animation)


func _compare_players(a: AnimationPlayer, b: AnimationPlayer) -> bool:
	return String(a.get_path()) < String(b.get_path())


func _pick_player_from_selection() -> int:
	var selection: EditorSelection = EditorInterface.get_selection()
	if selection == null:
		return -1
	for node: Node in selection.get_selected_nodes():
		var player: AnimationPlayer = node as AnimationPlayer
		if player == null:
			continue
		var index: int = _players.find(player)
		if index != -1:
			return index
	return -1


func _refresh_animations(preferred_animation: String) -> void:
	_animations.clear()
	_animation_names = PackedStringArray()
	_anim_option.clear()
	_animation = null
	_animation_name = ""
	if _player == null:
		_clear_tracks()
		return
	for full_name: String in _player.get_animation_list():
		var animation: Animation = _resolve_animation(full_name)
		if animation == null:
			continue
		_animation_names.append(full_name)
		_animations.append(animation)
		_anim_option.add_item(full_name)
	_anim_option.disabled = _animation_names.is_empty()
	if _animation_names.is_empty():
		_clear_tracks()
		#_info_label.text = "该 AnimationPlayer 没有任何动画。"
		_set_status("没有可用的动画。", false)
		return
	var wanted: int = _animation_names.find(preferred_animation)
	if wanted == -1:
		wanted = 0
	_anim_option.select(wanted)
	_select_animation(wanted)


## get_animation_list() 返回 "库名/动画名"（默认库不带前缀），逐个解析出 Animation。
func _resolve_animation(full_name: String) -> Animation:
	if _player == null:
		return null
	var parts: PackedStringArray = full_name.split("/", true, 1)
	if parts.size() == 2:
		var library: AnimationLibrary = _player.get_animation_library(StringName(parts[0]))
		if library != null:
			var animation: Animation = library.get_animation(StringName(parts[1]))
			if animation != null:
				return animation
	return _player.get_animation(StringName(full_name))


## preferred_track 仍然可选就保持选中，否则退到第一个可选轨道。
func _refresh_tracks(preferred_track: int = -1) -> void:
	_track_option.clear()
	_track_index = -1
	_apply_button.disabled = true
	_apply_all_button.disabled = true
	if _animation == null:
		_clear_tracks()
		return
	var supported: int = 0
	for i: int in range(_animation.get_track_count()):
		var track_type: int = _animation.track_get_type(i)
		if _is_track_supported(i):
			supported += 1
		# 类型被取消勾选的轨道直接不列出来（列表项的 id 存的就是轨道索引）。
		if not _is_track_type_checked(track_type):
			continue
		_track_option.add_item(
			"%d · %s · %s" % [i, Core.track_type_label(track_type), String(_animation.track_get_path(i))],
			i
		)
		if not _is_track_supported(i):
			_track_option.set_item_disabled(_track_option.item_count - 1, true)
	_track_option.disabled = _track_option.item_count == 0
	_apply_all_button.disabled = supported == 0

	var wanted: int = preferred_track if _is_track_selectable(preferred_track) else _first_selectable_track()
	if wanted == -1:
		_clear_spins()
		_update_info()
		_set_status("该动画里没有可插值的数值轨道（需要 ≥2 个关键帧，且类型已勾选）。", false)
		return
	_select_option_track(wanted)
	_select_track(wanted)


## 在下拉里按「轨道索引」选中（列表项 id 存的就是轨道索引）。
func _select_option_track(track_index: int) -> void:
	for i: int in range(_track_option.item_count):
		if _track_option.get_item_id(i) == track_index:
			_track_option.select(i)
			return


## 轨道本身能否插值：类型受支持，且关键帧 ≥2。
func _is_track_supported(index: int) -> bool:
	if _animation == null or index < 0 or index >= _animation.get_track_count():
		return false
	return Core.is_supported_track_type(_animation.track_get_type(index)) \
		and _animation.track_get_key_count(index) >= 2


## 「位置 / 旋转 / 缩放」三个勾选框决定该类轨道是否参与；值轨道没有勾选框，始终参与。
func _is_track_type_checked(track_type: int) -> bool:
	match track_type:
		Animation.TYPE_POSITION_3D:
			return _position_track_check.button_pressed
		Animation.TYPE_ROTATION_3D:
			return _rotation_track_check.button_pressed
		Animation.TYPE_SCALE_3D:
			return _scale_track_check.button_pressed
	return true


## 该轨道能否在「轨道」下拉里被选中：可插值，且类型没有被跳过。
func _is_track_selectable(index: int) -> bool:
	if not _is_track_supported(index):
		return false
	return _is_track_type_checked(_animation.track_get_type(index))


## 下拉里第一个可选轨道；没有则 -1。
func _first_selectable_track() -> int:
	if _animation == null:
		return -1
	for i: int in range(_animation.get_track_count()):
		if _is_track_selectable(i):
			return i
	return -1


func _clear_tracks() -> void:
	_track_option.clear()
	_track_option.disabled = true
	_anim_option.disabled = _animation_names.is_empty()
	_track_index = -1
	_apply_button.disabled = true
	_apply_all_button.disabled = true
	_clear_spins()
	_update_info()


func _clear_spins() -> void:
	for spin: SpinBox in _spin_from:
		spin.visible = false
		spin.value = 0.0
	for spin: SpinBox in _spin_to:
		spin.visible = false
		spin.value = 0.0
	for check: CheckBox in _checks:
		check.visible = false
	_sync_range()


## 生效范围默认取整条动画（0 ~ 动画长度）。
## 切换 AnimationPlayer / 动画 / 轨道时都会立刻刷新，避免沿用上一条动画的范围。
func _sync_range() -> void:
	if _animation == null:
		_set_range(Vector2.ZERO)
		return
	_set_range(Core.full_range(_animation, _track_index))


## 把生效范围的两个输入框设成给定的起止时刻。
func _set_range(span: Vector2) -> void:
	_range_from_spin.set_value_no_signal(span.x)
	_range_to_spin.set_value_no_signal(span.y)


func _select_animation(index: int) -> void:
	if index < 0 or index >= _animations.size():
		return
	_animation = _animations[index]
	_animation_name = _animation_names[index]
	_refresh_tracks()


func _select_track(index: int) -> void:
	_track_index = index
	if _animation == null or index < 0:
		_apply_button.disabled = true
		_clear_spins()
		_update_info()
		return
	# 换了轨道/动画就立刻把生效范围刷成这条动画的整条长度。
	_sync_range()
	var supported: bool = Core.is_supported_track_type(_animation.track_get_type(index))
	_apply_button.disabled = not supported or _animation.track_get_key_count(index) < 2
	if supported:
		_reload_values_from_keys()
	_update_info()


# ---------------------------------------------------------------- 值填充

func _reload_values_from_keys() -> void:
	if _animation == null or _track_index < 0:
		_clear_spins()
		return
	var ends: Dictionary = Core.read_track_ends(_animation, _track_index)
	if not bool(ends["ok"]):
		_clear_spins()
		return
	var from_value: Variant = ends["from"]
	# 旋转轨道存的是四元数：界面改用欧拉角（度）呈现，三个轴可单独勾选修改。
	var angle: bool = Core.is_angle_edit(from_value)
	var channels: int = Core.edit_channel_count(from_value)
	_fill_channels(Core.value_to_edit_channels(from_value), Core.value_to_edit_channels(ends["to"]), channels, angle)


## 起始值 / 终点值 / 勾选框三行一起按通道刷新，保证列对齐。
func _fill_channels(from_values: PackedFloat64Array, to_values: PackedFloat64Array, channels: int, angle: bool) -> void:
	# 每行是「行标签 + 各通道」，列数必须跟着通道数走，否则会提前换行错位。
	var rows: int = maxi(channels, 1)
	_value_grid.columns = rows + 1
	for i: int in range(SPIN_COUNT):
		var shown: bool = i < channels
		_checks[i].visible = shown
		_spin_from[i].visible = shown
		_spin_to[i].visible = shown
		if not shown:
			continue
		_checks[i].disabled = false
		_configure_spin(_spin_from[i], angle)
		_configure_spin(_spin_to[i], angle)
		if i < from_values.size():
			_spin_from[i].set_value_no_signal(from_values[i])
		if i < to_values.size():
			_spin_to[i].set_value_no_signal(to_values[i])
	_sync_channel_editability()


## 未勾选的通道沿用关键帧原值，不采用输入框里的数值。
func _collect_spin_value(spins: Array[SpinBox], template: Variant, mask: PackedByteArray) -> Variant:
	var template_values: PackedFloat64Array = Core.value_to_edit_channels(template)
	if template_values.is_empty():
		return template
	var values: PackedFloat64Array = template_values.duplicate()
	for i: int in range(mini(template_values.size(), SPIN_COUNT)):
		if i < mask.size() and mask[i] != 0:
			values[i] = spins[i].value
	var value: Variant = Core.edit_channels_to_value(template, values)
	if value == null:
		return template
	return value


func _update_info() -> void:
	if _player == null:
		#_info_label.text = "未找到 AnimationPlayer。"
		return
	if _animation == null:
		#_info_label.text = "请选择动画。"
		return
	var lines: PackedStringArray = PackedStringArray()
	var root: Node = EditorInterface.get_edited_scene_root()
	#if root != null:
	#	lines.append("AnimationPlayer：%s" % String(root.get_path_to(_player)))
	#else:
	#	lines.append("AnimationPlayer：%s" % String(_player.name))
	#lines.append("动画：%s" % _animation_name)
	#lines.append("插值曲线：%s" % _describe_curve())
	if _track_index < 0:
		#lines.append("轨道：未选择")
		#_info_label.text = "\n".join(lines)
		return
	var track_type: int = _animation.track_get_type(_track_index)
	#lines.append("轨道 %d：%s" % [_track_index, Core.track_type_label(track_type)])
	#lines.append("路径：%s" % String(_animation.track_get_path(_track_index)))
	var ends: Dictionary = Core.read_track_ends(_animation, _track_index)
	if bool(ends["ok"]):
		#lines.append("关键帧 %d 个，时间 %.3f ~ %.3f" % [int(ends["count"]), float(ends["time_from"]), float(ends["time_to"])])
		#lines.append("当前首帧：%s" % Core.describe_edit_value(ends["from"]))
		#lines.append("当前尾帧：%s" % Core.describe_edit_value(ends["to"]))
		#lines.append("参与修改的通道：%s" % _describe_active_channels(Core.edit_channel_count(ends["from"])))
		#lines.append("生效范围：%s" % _describe_range())
		if Core.is_angle_edit(ends["from"]):
			lines.append("* 旋转轨道按欧拉角处理；可勾选 X/Y/Z 轴修改；全选时按最短路径 slerp 过渡")
	else:
		lines.append("（%s）" % String(ends["error"]))
	#lines.append("动画来源：%s" % _animation_source())
	#_info_label.text = "\n".join(lines)


func _describe_active_channels(channels: int) -> String:
	var names: PackedStringArray = PackedStringArray(["X", "Y", "Z", "W"])
	var active: PackedStringArray = PackedStringArray()
	for i: int in range(mini(channels, SPIN_COUNT)):
		if _checks[i].button_pressed:
			active.append(names[i])
	if active.is_empty():
		return "无（不会做任何修改）"
	return ", ".join(active)


## 生效范围的可读描述。
func _describe_range() -> String:
	return "%.3fs → %.3fs（此范围外的关键帧保持原值）" % [_range_from_spin.value, _range_to_spin.value]


## 收集生效范围。use_spin_times 为 false 时用轨道自身的首尾时间（即整条轨道）。
func _collect_range(use_spin_times: bool) -> Dictionary:
	return {
		"from": _range_from_spin.value if use_spin_times else NAN,
		"to": _range_to_spin.value if use_spin_times else NAN,
	}


func _animation_source() -> String:
	if _animation == null:
		return "未知"
	if _animation.resource_path != "":
		return String(_animation.resource_path)
	return "场景内嵌资源（随场景一起保存）"


func _set_status(message: String, success: bool) -> void:
	_status_label.text = message
	_status_label.add_theme_color_override("font_color", COLOR_OK if success else COLOR_ERROR)


# ---------------------------------------------------------------- 交互

func _on_refresh_pressed() -> void:
	_refresh_players()
	_set_status("已重新扫描当前编辑场景。", true)


func _on_player_selected(index: int) -> void:
	if index < 0 or index >= _players.size():
		return
	_player = _players[index]
	_refresh_animations("")


func _on_animation_selected(index: int) -> void:
	_select_animation(index)


func _on_track_selected(index: int) -> void:
	if index < 0 or index >= _track_option.item_count:
		return
	_select_track(_track_option.get_item_id(index))


## 「位置 / 旋转 / 缩放」勾选框变化：重建下拉（被跳过的类型不再列出）；
## 当前轨道仍然可选就保持，否则自动跳到第一个可选轨道。
func _on_track_filter_toggled(_pressed: bool) -> void:
	if _animation == null:
		return
	var previous: int = _track_index
	_refresh_tracks(previous)
	if previous >= 0 and _track_index >= 0 and _track_index != previous:
		_set_status("轨道 %d 已被跳过，自动切到轨道 %d。" % [previous, _track_index], true)


func _on_keep_ends_toggled(_pressed: bool) -> void:
	_update_info()


func _on_range_changed(_value: float) -> void:
	_update_info()


## 读取当前动画的长度，把生效范围重置为 0 ~ 动画长度。
func _on_reset_range_to_animation() -> void:
	if _animation == null:
		_set_status("请先选择动画。", false)
		return
	var span: Vector2 = Core.full_range(_animation, _track_index)
	_set_range(span)
	_update_info()
	_set_status("生效范围已重置为整条动画：0 ~ %.3fs。" % span.y, true)


## 读取选中轨道自身的时间跨度，把生效范围重置为 首帧时间 ~ 尾帧时间。
func _on_reset_range_to_track() -> void:
	if _animation == null or _track_index < 0:
		_set_status("请先选择轨道。", false)
		return
	var ends: Dictionary = Core.read_track_ends(_animation, _track_index)
	if not bool(ends["ok"]):
		_set_status(String(ends["error"]), false)
		return
	var span: Vector2 = Vector2(float(ends["time_from"]), float(ends["time_to"]))
	_set_range(span)
	_update_info()
	_set_status("生效范围已重置为选中轨道的跨度：%.3fs ~ %.3fs。" % [span.x, span.y], true)


func _on_channel_toggled(_pressed: bool) -> void:
	_sync_channel_editability()
	_update_info()


## 选中预设方式时，用它的采样点刷新曲线，作为继续手调的起点。
func _on_curve_selected(index: int) -> void:
	var id: int = _curve_option.get_item_id(index)
	if id == Core.CURVE_CUSTOM:
		return
	# 记住最后一次预设，「重置图表」在下拉停在「自定义曲线」时用它回退。
	_last_preset = id
	_apply_preset_to_canvas(id)
	_update_info()


## 一旦手动改过图形，就切到「自定义曲线」。
func _on_curve_edit_started() -> void:
	_select_custom_curve()
	_update_info()


func _on_curve_shape_changed(_shape: Dictionary) -> void:
	_sync_mode_dependents()
	_update_info()
	_auto_apply_if_enabled()


func _select_custom_curve() -> void:
	var custom_index: int = _custom_curve_index()
	if custom_index >= 0 and _curve_option.selected != custom_index:
		_curve_option.select(custom_index)


## 在「插值方式」下拉里按预设 id 定位并选中（不会触发 item_selected）。
func _select_preset_in_option(preset_id: int) -> void:
	for i: int in range(_curve_option.item_count):
		if _curve_option.get_item_id(i) == preset_id:
			_curve_option.select(i)
			return


func _custom_curve_index() -> int:
	for i: int in range(_curve_option.item_count):
		if _curve_option.get_item_id(i) == Core.CURVE_CUSTOM:
			return i
	return -1


func _apply_preset_to_canvas(preset_id: int) -> void:
	_curve_canvas.set_preset_points(Core.preset_points(preset_id))
	_sync_curve_mode_buttons()
	_sync_mode_dependents()


# ---------------------------------------------------------------- 图表操作方式 / 工具条

## 三种图形模型做成单选按钮，并接上工具条。
func _setup_curve_tools() -> void:
	var group: ButtonGroup = ButtonGroup.new()
	for button: Button in [_mode_points_button, _mode_bezier_button, _mode_elastic_button]:
		button.button_group = group
	# 把模型常量绑定到各自的按钮上：同组按钮的按下状态在信号回调里可能还是旧的，
	# 直接用绑定值更可靠。
	_mode_points_button.toggled.connect(_on_curve_mode_toggled.bind(Core.SHAPE_POINTS))
	_mode_bezier_button.toggled.connect(_on_curve_mode_toggled.bind(Core.SHAPE_BEZIER))
	_mode_elastic_button.toggled.connect(_on_curve_mode_toggled.bind(Core.SHAPE_ELASTIC))
	_mirror_mode_option.clear()
	var mirror_labels: PackedStringArray = Core.mirror_mode_labels()
	for i: int in range(mirror_labels.size()):
		_mirror_mode_option.add_item(mirror_labels[i], i)
	_mirror_mode_option.select(Core.MIRROR_CENTER)
	_curve_mirror_button.pressed.connect(_on_curve_mirror)
	_curve_copy_button.pressed.connect(_on_curve_copy)
	_curve_paste_button.pressed.connect(_on_curve_paste)
	_curve_ease_button.pressed.connect(_on_curve_cycle_ease)
	_curve_auto_button.toggled.connect(_on_auto_apply_toggled)
	_curve_view_button.pressed.connect(_on_curve_reset_view)
	_curve_drag_check.toggled.connect(_on_curve_drag_toggled)
	_curve_graph_reset_button.pressed.connect(_on_curve_reset_graph)
	_curve_paste_button.disabled = true
	_sync_curve_mode_buttons()
	_sync_mode_dependents()
	_sync_drag_enabled()


## 把画布当前的图形模型同步到三个单选按钮上。
func _sync_curve_mode_buttons() -> void:
	var mode: int = _curve_canvas.get_mode()
	_mode_points_button.set_pressed_no_signal(mode == Core.SHAPE_POINTS)
	_mode_bezier_button.set_pressed_no_signal(mode == Core.SHAPE_BEZIER)
	_mode_elastic_button.set_pressed_no_signal(mode == Core.SHAPE_ELASTIC)


## 图形模型相关的联动：只有「多控制点」模型能用「插值方式」下拉，
## 只有「弹性」模型能用「缓动方向」按钮。
func _sync_mode_dependents() -> void:
	_curve_option.disabled = _curve_canvas.get_mode() != Core.SHAPE_POINTS
	_sync_ease_button()


## 缓动方向按钮：文案跟随当前方向，且只在「弹性」模型下可操作。
func _sync_ease_button() -> void:
	var labels: PackedStringArray = Core.ease_labels()
	var ease: int = clampi(int(_curve_canvas.get_shape().get("ease", Core.EASE_OUT)), 0, labels.size() - 1)
	_curve_ease_button.text = "弹性·%s" % labels[ease]
	_curve_ease_button.disabled = _curve_canvas.get_mode() != Core.SHAPE_ELASTIC


## 「允许拖动」选框：勾选才能平移视图；未勾选时「复位视图」一并置灰。
func _sync_drag_enabled() -> void:
	var enabled: bool = _curve_drag_check.button_pressed
	_curve_canvas.set_pan_enabled(enabled)
	_curve_view_button.disabled = not enabled


func _on_curve_mode_toggled(pressed: bool, mode: int) -> void:
	if not pressed:
		return
	_curve_canvas.set_mode(mode)
	# 换图形模型即意味着要按自定义曲线插值。
	_select_custom_curve()
	_sync_mode_dependents()
	_update_info()
	_auto_apply_if_enabled()


## 用给定的图形替换画布内容，并切到「自定义曲线」。
func _set_curve_shape(shape: Dictionary) -> void:
	_curve_canvas.set_shape(shape)
	_sync_curve_mode_buttons()
	_sync_mode_dependents()
	_select_custom_curve()
	_update_info()
	_auto_apply_if_enabled()


## 按「镜像方式」下拉里选中的方式镜像当前图形。
func _on_curve_mirror() -> void:
	var labels: PackedStringArray = Core.mirror_mode_labels()
	var mirror: int = clampi(_mirror_mode_option.get_selected_id(), 0, labels.size() - 1)
	if not Core.mirror_supported(_curve_canvas.get_mode(), mirror):
		_set_status("「%s」只能用在「多控制点」图形上：请先点「多控制点」再镜像。" % labels[mirror], false)
		return
	_set_curve_shape(Core.mirror_shape(_curve_canvas.get_shape(), mirror))
	if mirror == Core.MIRROR_CENTER:
		_set_status("曲线已%s（反向缓动：缓出 ↔ 缓入）。" % labels[mirror], true)
	else:
		_set_status("曲线已%s：端点互换，过渡变成 1 → 0（终点值 → 起始值）。" % labels[mirror], true)


func _on_curve_copy() -> void:
	_curve_clipboard = _curve_canvas.get_shape()
	_curve_paste_button.disabled = false
	_set_status("已复制当前曲线。", true)


func _on_curve_paste() -> void:
	if _curve_clipboard.is_empty():
		_set_status("剪贴板里还没有曲线。", false)
		return
	_set_curve_shape(_curve_clipboard)
	_set_status("已粘贴曲线。", true)


func _on_curve_cycle_ease() -> void:
	var shape: Dictionary = _curve_canvas.get_shape()
	shape["ease"] = (int(shape.get("ease", Core.EASE_OUT)) + 1) % Core.ease_labels().size()
	_set_curve_shape(shape)
	_set_status("弹性缓动方向：%s。" % Core.ease_labels()[int(shape["ease"])], true)


func _on_curve_reset_view() -> void:
	_curve_canvas.reset_view()
	_set_status("曲线视图已复位。", true)


## 「重置图表」：把「当前」图形模型自己恢复成初始形状，模型本身不变，
## 也不会动其他模型调好的参数。
## - 多控制点 → 重置为「插值方式」当前选中的预设
## - 贝塞尔   → 默认的两个手柄
## - 弹性     → 默认的振幅 / 周期 / 缓动方向
func _on_curve_reset_graph() -> void:
	var mode: int = _curve_canvas.get_mode()
	var shape: Dictionary = _curve_canvas.get_shape()
	var defaults: Dictionary = Core.default_shape()
	# 「多控制点」要重置成的预设；下拉停在「自定义曲线」时，回退到最后一次选中的预设。
	var preset: int = _curve_option.get_selected_id()
	if preset < 0 or preset == Core.CURVE_CUSTOM:
		preset = _last_preset
	match mode:
		Core.SHAPE_BEZIER:
			shape["h1"] = defaults["h1"]
			shape["h2"] = defaults["h2"]
		Core.SHAPE_ELASTIC:
			shape["amplitude"] = defaults["amplitude"]
			shape["period"] = defaults["period"]
			shape["ease"] = defaults["ease"]
		_:
			shape["points"] = Core.preset_points(preset)
			# 图形回到了这个预设，下拉也同步过去，免得显示成「自定义曲线」。
			_select_preset_in_option(preset)
	_curve_canvas.set_shape(shape)
	_sync_curve_mode_buttons()
	_sync_mode_dependents()
	_update_info()
	_auto_apply_if_enabled()
	var labels: PackedStringArray = Core.shape_mode_labels()
	var mode_label: String = labels[clampi(mode, 0, labels.size() - 1)]
	if mode == Core.SHAPE_POINTS:
		_set_status("「%s」图表已重置为「%s」。" % [mode_label, Core.curve_labels()[preset]], true)
	else:
		_set_status("「%s」图表已重置为初始形状。" % mode_label, true)


func _on_curve_drag_toggled(pressed: bool) -> void:
	_sync_drag_enabled()
	if pressed:
		_set_status("已允许拖动：可以平移曲线视图。", true)
	else:
		_set_status("已锁定视图：不能平移，「复位视图」不可用。", true)


func _on_auto_apply_toggled(pressed: bool) -> void:
	if not pressed:
		_set_status("已关闭自动应用。", true)
		return
	_set_status("已开启自动应用：改动曲线会立刻写入选中轨道。", true)
	_auto_apply_if_enabled()


## 自动应用：开启且有可写轨道时，直接把当前曲线应用到该轨道。
## 走的是和「应用到选中轨道」相同的撤销记录，所以撤销栈依然干净。
func _auto_apply_if_enabled() -> void:
	if not _curve_auto_button.button_pressed:
		return
	if _animation == null or _track_index < 0 or _apply_button.disabled:
		return
	_apply_tracks(PackedInt32Array([_track_index]), true)


## 信息栏里对当前曲线的描述。
func _describe_curve() -> String:
	var index: int = _curve_option.selected
	if index < 0:
		return "未选择"
	if _curve_option.get_item_id(index) != Core.CURVE_CUSTOM:
		return String(_curve_option.get_item_text(index))
	var shape: Dictionary = _curve_canvas.get_shape()
	var labels: PackedStringArray = Core.shape_mode_labels()
	var mode: int = clampi(int(shape.get("mode", Core.SHAPE_POINTS)), 0, labels.size() - 1)
	match mode:
		Core.SHAPE_BEZIER:
			var h1: Vector2 = shape.get("h1", Vector2.ZERO)
			var h2: Vector2 = shape.get("h2", Vector2.ZERO)
			return "自定义·贝塞尔(%.2f, %.2f)(%.2f, %.2f)" % [h1.x, h1.y, h2.x, h2.y]
		Core.SHAPE_ELASTIC:
			var ease_labels: PackedStringArray = Core.ease_labels()
			var ease: int = clampi(int(shape.get("ease", Core.EASE_OUT)), 0, ease_labels.size() - 1)
			return "自定义·弹性 %s 振幅 %.2f 周期 %.2f" % [ease_labels[ease], float(shape.get("amplitude", 1.0)), float(shape.get("period", 0.3))]
	var points: PackedVector2Array = shape.get("points", PackedVector2Array())
	return "自定义·多控制点（%d 点）" % points.size()


func _on_reload_values_pressed() -> void:
	if _animation == null or _track_index < 0:
		_set_status("请先选择动画与轨道。", false)
		return
	_reload_values_from_keys()
	_set_status("已从首尾关键帧重新读取起始值/终点值。", true)


func _on_editor_selection_changed() -> void:
	var index: int = _pick_player_from_selection()
	if index == -1:
		return
	if _player != null and _players.size() > index and _players[index] == _player:
		return
	_player_option.select(index)
	_on_player_selected(index)


# ---------------------------------------------------------------- 应用

func _on_apply_pressed() -> void:
	if _animation == null or _track_index < 0:
		_set_status("请先选择 AnimationPlayer、动画与轨道。", false)
		return
	_apply_tracks(PackedInt32Array([_track_index]), true)


func _on_apply_all_pressed() -> void:
	if _animation == null:
		_set_status("请先选择动画。", false)
		return
	var targets: PackedInt32Array = PackedInt32Array()
	for i: int in range(_animation.get_track_count()):
		if Core.is_supported_track_type(_animation.track_get_type(i)):
			targets.append(i)
	if targets.is_empty():
		_set_status("该动画里没有数值轨道。", false)
		return
	_apply_tracks(targets, false)


## use_spin_values = true 时使用界面上的起始值/终点值；否则每条轨道都用自身的首尾关键帧值。
func _apply_tracks(track_indices: PackedInt32Array, use_spin_values: bool) -> void:
	if _animation == null or _player == null:
		return
	var curve: int = _curve_option.get_selected_id()
	if curve < 0:
		curve = Core.CURVE_LINEAR
	var curve_shape: Dictionary = _curve_canvas.get_shape()
	var keep_only_ends: bool = _keep_ends_check.button_pressed
	if use_spin_values and _range_to_spin.value - _range_from_spin.value <= 0.000001:
		_set_status("生效范围的结束时刻必须大于起始时刻。", false)
		return
	var active_range: Dictionary = _collect_range(use_spin_values)

	var plans: Array[Dictionary] = []
	var skipped: int = 0
	for track_index: int in track_indices:
		var track_type: int = _animation.track_get_type(track_index)
		if not Core.is_supported_track_type(track_type):
			skipped += 1
			continue
		var ends: Dictionary = Core.read_track_ends(_animation, track_index)
		if not bool(ends["ok"]) or int(ends.get("count", 0)) < 2:
			skipped += 1
			continue
		var from_value: Variant = ends["from"]
		var to_value: Variant = ends["to"]
		var spin_mask: PackedByteArray = _channel_mask(Core.edit_channel_count(from_value))
		if use_spin_values and track_index == _track_index:
			from_value = _collect_spin_value(_spin_from, from_value, spin_mask)
			to_value = _collect_spin_value(_spin_to, to_value, spin_mask)
		# 旋转轨道按欧拉角的三个轴勾选；全选时走 slerp，部分勾选时按欧拉角逐分量过渡。
		var active: PackedByteArray = _channel_mask(Core.edit_channel_count(from_value))
		var built: Dictionary = Core.build_keys(_animation, track_index, from_value, to_value, curve, keep_only_ends, active, curve_shape, active_range)
		if not bool(built["ok"]):
			skipped += 1
			if track_indices.size() == 1:
				_set_status(String(built["error"]), false)
				return
			continue
		plans.append({
			"index": track_index,
			"keys": built["keys"],
			"before": Core.capture_keys(_animation, track_index),
		})

	if plans.is_empty():
		_set_status("没有可处理的轨道（跳过 %d 条）。" % skipped, false)
		return

	var action_name: String = "轨道插值：%s" % _animation_name
	if plans.size() == 1:
		action_name = "轨道插值：%s · 轨道 %d" % [_animation_name, int(plans[0]["index"])]
	var undo_redo: EditorUndoRedoManager = EditorInterface.get_editor_undo_redo()
	undo_redo.create_action(action_name, UndoRedo.MERGE_DISABLE, EditorInterface.get_edited_scene_root())
	undo_redo.add_do_reference(_animation)
	for plan: Dictionary in plans:
		var track_index: int = int(plan["index"])
		undo_redo.add_do_method(self, &"_rebuild_track", _animation, track_index, plan["keys"])
		undo_redo.add_undo_method(self, &"_rebuild_track", _animation, track_index, plan["before"])
	undo_redo.commit_action()
	EditorInterface.mark_scene_as_unsaved()

	_refresh_player_cache()
	_reload_values_from_keys()
	_update_info()
	var applied: int = plans.size()
	if skipped > 0:
		_set_status("已应用 %d 条轨道（跳过 %d 条）。" % [applied, skipped], true)
	else:
		_set_status("已应用 %d 条轨道，可用 Ctrl+Z 撤销。" % applied, true)


## 供撤销/重做回调：整条轨道用给定的关键帧序列重建。
func _rebuild_track(animation: Animation, track_index: int, keys: Array) -> void:
	Core.apply_keys(animation, track_index, keys)
	_refresh_player_cache()


func _refresh_player_cache() -> void:
	if _player == null:
		return
	_player.clear_caches()
