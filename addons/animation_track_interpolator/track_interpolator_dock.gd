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

@onready var _player_option: OptionButton = %PlayerOption
@onready var _refresh_button: Button = %RefreshButton
@onready var _anim_option: OptionButton = %AnimOption
@onready var _track_option: OptionButton = %TrackOption
@onready var _info_label: Label = %InfoLabel
@onready var _curve_option: OptionButton = %CurveOption
@onready var _curve_canvas: CurveCanvas = %CurveCanvas
@onready var _range_from_spin: SpinBox = %RangeFromSpin
@onready var _range_to_spin: SpinBox = %RangeToSpin
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
	_curve_canvas.edit_started.connect(_on_curve_edit_started)
	_curve_canvas.points_changed.connect(_on_curve_points_changed)
	_curve_canvas.set_points(Core.preset_points(Core.CURVE_LINEAR))

	_refresh_button.pressed.connect(_on_refresh_pressed)
	_player_option.item_selected.connect(_on_player_selected)
	_anim_option.item_selected.connect(_on_animation_selected)
	_track_option.item_selected.connect(_on_track_selected)
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
		_info_label.text = "当前编辑场景里没有 AnimationPlayer。"
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
		_info_label.text = "该 AnimationPlayer 没有任何动画。"
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


func _refresh_tracks() -> void:
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
		_track_option.add_item("%d · %s · %s" % [i, Core.track_type_label(track_type), String(_animation.track_get_path(i))])
		if Core.is_supported_track_type(track_type) and _animation.track_get_key_count(i) >= 2:
			supported += 1
		else:
			_track_option.set_item_disabled(i, true)
	_track_option.disabled = _animation.get_track_count() == 0
	_apply_all_button.disabled = supported == 0

	var wanted: int = -1
	for i: int in range(_animation.get_track_count()):
		if Core.is_supported_track_type(_animation.track_get_type(i)) and _animation.track_get_key_count(i) >= 2:
			wanted = i
			break
	if wanted == -1:
		_clear_spins()
		_update_info()
		_set_status("该动画里没有可插值的数值轨道（需要 ≥2 个关键帧）。", false)
		return
	_track_option.select(wanted)
	_select_track(wanted)


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
	_range_from_spin.set_value_no_signal(0.0)
	_range_to_spin.set_value_no_signal(0.0)


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
	# 生效范围默认覆盖整条轨道；改小它就只改写范围内的关键帧。
	_range_from_spin.set_value_no_signal(float(ends["time_from"]))
	_range_to_spin.set_value_no_signal(float(ends["time_to"]))
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
		_info_label.text = "未找到 AnimationPlayer。"
		return
	if _animation == null:
		_info_label.text = "请选择动画。"
		return
	var lines: PackedStringArray = PackedStringArray()
	var root: Node = EditorInterface.get_edited_scene_root()
	if root != null:
		lines.append("AnimationPlayer：%s" % String(root.get_path_to(_player)))
	else:
		lines.append("AnimationPlayer：%s" % String(_player.name))
	lines.append("动画：%s" % _animation_name)
	lines.append("插值曲线：%s" % _describe_curve())
	if _track_index < 0:
		lines.append("轨道：未选择")
		_info_label.text = "\n".join(lines)
		return
	var track_type: int = _animation.track_get_type(_track_index)
	lines.append("轨道 %d：%s" % [_track_index, Core.track_type_label(track_type)])
	lines.append("路径：%s" % String(_animation.track_get_path(_track_index)))
	var ends: Dictionary = Core.read_track_ends(_animation, _track_index)
	if bool(ends["ok"]):
		lines.append("关键帧 %d 个，时间 %.3f ~ %.3f" % [int(ends["count"]), float(ends["time_from"]), float(ends["time_to"])])
		lines.append("当前首帧：%s" % Core.describe_edit_value(ends["from"]))
		lines.append("当前尾帧：%s" % Core.describe_edit_value(ends["to"]))
		lines.append("参与修改的通道：%s" % _describe_active_channels(Core.edit_channel_count(ends["from"])))
		lines.append("生效范围：%s" % _describe_range())
		if Core.is_angle_edit(ends["from"]):
			lines.append("（旋转轨道按欧拉角(度)编辑；可单独勾选 X/Y/Z 轴修改；全选时按最短路径 slerp 过渡）")
	else:
		lines.append("（%s）" % String(ends["error"]))
	lines.append("动画来源：%s" % _animation_source())
	_info_label.text = "\n".join(lines)


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
	_select_track(index)


func _on_keep_ends_toggled(_pressed: bool) -> void:
	_update_info()


func _on_range_changed(_value: float) -> void:
	_update_info()


func _on_channel_toggled(_pressed: bool) -> void:
	_sync_channel_editability()
	_update_info()


## 选中预设方式时，用它的采样点刷新曲线，作为继续手调的起点。
func _on_curve_selected(index: int) -> void:
	var id: int = _curve_option.get_item_id(index)
	if id == Core.CURVE_CUSTOM:
		return
	_curve_canvas.set_points(Core.preset_points(id))
	_update_info()


## 一旦手动动过控制点，就切到「自定义曲线」。
func _on_curve_edit_started() -> void:
	var custom_index: int = _custom_curve_index()
	if custom_index >= 0 and _curve_option.selected != custom_index:
		_curve_option.select(custom_index)
	_update_info()


func _on_curve_points_changed(_points: PackedVector2Array) -> void:
	_update_info()


func _custom_curve_index() -> int:
	for i: int in range(_curve_option.item_count):
		if _curve_option.get_item_id(i) == Core.CURVE_CUSTOM:
			return i
	return -1


## 信息栏里对当前曲线的描述。
func _describe_curve() -> String:
	var index: int = _curve_option.selected
	if index < 0:
		return "未选择"
	if _curve_option.get_item_id(index) == Core.CURVE_CUSTOM:
		return "自定义曲线（%d 个控制点）" % _curve_canvas.get_points().size()
	return String(_curve_option.get_item_text(index))


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
	var curve_points: PackedVector2Array = _curve_canvas.get_points()
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
		var built: Dictionary = Core.build_keys(_animation, track_index, from_value, to_value, curve, keep_only_ends, active, curve_points, active_range)
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
