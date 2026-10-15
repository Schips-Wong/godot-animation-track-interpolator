@tool
extends RefCounted
## 动画轨道插值核心逻辑（纯逻辑，不依赖编辑器界面，可单独测试）。
##
## 作用：把一条数值类轨道（值 / 位置 3D / 旋转 3D / 缩放 3D）的所有关键帧，
## 按照指定的曲线方式从「起始值」过渡到「终点值」。
## 关键帧的时间点默认保持不变，只重写每一帧的值；也可以选择只保留首尾两帧。

## 插值（过渡）方式。0..5，顺序与 curve_labels() 一致。
const CURVE_LINEAR: int = 0 ## 线性匀速
const CURVE_SMOOTH: int = 1 ## 平滑（缓入缓出）
const CURVE_EASE_IN: int = 2 ## 缓入（加速）
const CURVE_EASE_OUT: int = 3 ## 缓出（减速）
const CURVE_SINE: int = 4 ## 正弦过渡
const CURVE_STEP: int = 5 ## 阶跃：保持起始值直到最后一帧

const EPSILON: float = 0.000001

## 旋转轨道在界面上按欧拉角的三个轴（X/Y/Z）编辑。
const ANGLE_CHANNEL_COUNT: int = 3


## 支持的插值方式显示名（顺序与 Curve 枚举一致）。
static func curve_labels() -> PackedStringArray:
	return PackedStringArray([
		"线性（匀速）",
		"平滑（缓入缓出）",
		"缓入（加速）",
		"缓出（减速）",
		"正弦过渡",
		"阶跃（保持起始值到最后一帧）",
	])


## 支持的数值类轨道类型。
static func supported_track_types() -> PackedInt32Array:
	return PackedInt32Array([
		Animation.TYPE_VALUE,
		Animation.TYPE_POSITION_3D,
		Animation.TYPE_ROTATION_3D,
		Animation.TYPE_SCALE_3D,
	])


static func is_supported_track_type(track_type: int) -> bool:
	return supported_track_types().find(track_type) != -1


static func track_type_label(track_type: int) -> String:
	match track_type:
		Animation.TYPE_VALUE:
			return "值"
		Animation.TYPE_POSITION_3D:
			return "位置 3D"
		Animation.TYPE_ROTATION_3D:
			return "旋转 3D"
		Animation.TYPE_SCALE_3D:
			return "缩放 3D"
		Animation.TYPE_BLEND_SHAPE:
			return "混合形状"
		Animation.TYPE_METHOD:
			return "方法"
		Animation.TYPE_BEZIER:
			return "贝塞尔"
		Animation.TYPE_AUDIO:
			return "音频"
		Animation.TYPE_ANIMATION:
			return "动画"
	return "未知(%d)" % track_type


## 该值的通道数；0 表示不是受支持的数值类型。
static func channel_count(value: Variant) -> int:
	match typeof(value):
		TYPE_BOOL, TYPE_INT, TYPE_FLOAT:
			return 1
		TYPE_VECTOR2, TYPE_VECTOR2I:
			return 2
		TYPE_VECTOR3, TYPE_VECTOR3I:
			return 3
		TYPE_VECTOR4, TYPE_VECTOR4I, TYPE_QUATERNION, TYPE_COLOR:
			return 4
	return 0


static func value_to_channels(value: Variant) -> PackedFloat64Array:
	var out: PackedFloat64Array = PackedFloat64Array()
	match typeof(value):
		TYPE_BOOL:
			out.append(1.0 if bool(value) else 0.0)
		TYPE_INT:
			out.append(float(int(value)))
		TYPE_FLOAT:
			out.append(float(value))
		TYPE_VECTOR2:
			var v2: Vector2 = value
			out.append(v2.x)
			out.append(v2.y)
		TYPE_VECTOR2I:
			var v2i: Vector2i = value
			out.append(float(v2i.x))
			out.append(float(v2i.y))
		TYPE_VECTOR3:
			var v3: Vector3 = value
			out.append(v3.x)
			out.append(v3.y)
			out.append(v3.z)
		TYPE_VECTOR3I:
			var v3i: Vector3i = value
			out.append(float(v3i.x))
			out.append(float(v3i.y))
			out.append(float(v3i.z))
		TYPE_VECTOR4:
			var v4: Vector4 = value
			out.append(v4.x)
			out.append(v4.y)
			out.append(v4.z)
			out.append(v4.w)
		TYPE_VECTOR4I:
			var v4i: Vector4i = value
			out.append(float(v4i.x))
			out.append(float(v4i.y))
			out.append(float(v4i.z))
			out.append(float(v4i.w))
		TYPE_QUATERNION:
			var q: Quaternion = value
			out.append(q.x)
			out.append(q.y)
			out.append(q.z)
			out.append(q.w)
		TYPE_COLOR:
			var c: Color = value
			out.append(c.r)
			out.append(c.g)
			out.append(c.b)
			out.append(c.a)
	return out


## 用 template 的类型把通道数值还原成一个值。
static func channels_to_value(template: Variant, channels: PackedFloat64Array) -> Variant:
	var n: int = channels.size()
	match typeof(template):
		TYPE_BOOL:
			if n == 1:
				return channels[0] >= 0.5
		TYPE_INT:
			if n == 1:
				return int(round(channels[0]))
		TYPE_FLOAT:
			if n == 1:
				return channels[0]
		TYPE_VECTOR2:
			if n == 2:
				return Vector2(channels[0], channels[1])
		TYPE_VECTOR2I:
			if n == 2:
				return Vector2i(roundi(channels[0]), roundi(channels[1]))
		TYPE_VECTOR3:
			if n == 3:
				return Vector3(channels[0], channels[1], channels[2])
		TYPE_VECTOR3I:
			if n == 3:
				return Vector3i(roundi(channels[0]), roundi(channels[1]), roundi(channels[2]))
		TYPE_VECTOR4:
			if n == 4:
				return Vector4(channels[0], channels[1], channels[2], channels[3])
		TYPE_VECTOR4I:
			if n == 4:
				return Vector4i(roundi(channels[0]), roundi(channels[1]), roundi(channels[2]), roundi(channels[3]))
		TYPE_QUATERNION:
			if n == 4:
				return Quaternion(channels[0], channels[1], channels[2], channels[3]).normalized()
		TYPE_COLOR:
			if n == 4:
				return Color(channels[0], channels[1], channels[2], channels[3])
	return null


## 界面上是否以欧拉角（度）的形式编辑这个值：四元数（旋转轨道）走欧拉角。
static func is_angle_edit(value: Variant) -> bool:
	return typeof(value) == TYPE_QUATERNION


## 界面上的编辑通道数：四元数是 3 个欧拉角，其余按分量数。
static func edit_channel_count(value: Variant) -> int:
	if is_angle_edit(value):
		return 3
	return channel_count(value)


## 值 -> 界面上的通道数值（四元数 -> 欧拉角，单位：度）。
static func value_to_edit_channels(value: Variant) -> PackedFloat64Array:
	var out: PackedFloat64Array = PackedFloat64Array()
	if is_angle_edit(value):
		var euler: Vector3 = (value as Quaternion).get_euler()
		out.append(rad_to_deg(euler.x))
		out.append(rad_to_deg(euler.y))
		out.append(rad_to_deg(euler.z))
		return out
	return value_to_channels(value)


## 界面上的通道数值 -> 值（欧拉角（度） -> 四元数）。
static func edit_channels_to_value(template: Variant, channels: PackedFloat64Array) -> Variant:
	if is_angle_edit(template):
		if channels.size() < 3:
			return template
		return Quaternion.from_euler(Vector3(deg_to_rad(channels[0]), deg_to_rad(channels[1]), deg_to_rad(channels[2]))).normalized()
	return channels_to_value(template, channels)


## 归一化时间 t(0~1) 在指定方式下的插值权重。
static func curve_weight(curve: int, t: float) -> float:
	var x: float = clampf(t, 0.0, 1.0)
	match curve:
		CURVE_LINEAR:
			return x
		CURVE_SMOOTH:
			return x * x * (3.0 - 2.0 * x)
		CURVE_EASE_IN:
			return x * x
		CURVE_EASE_OUT:
			return 1.0 - (1.0 - x) * (1.0 - x)
		CURVE_SINE:
			return 0.5 - 0.5 * cos(PI * x)
		CURVE_STEP:
			return 0.0 if x < 1.0 else 1.0
	return x


## 在 from_value 与 to_value 之间按指定的方式过渡。四元数走 slerp 保证旋转正确。
static func interpolate_value(curve: int, t: float, from_value: Variant, to_value: Variant) -> Variant:
	var weight: float = curve_weight(curve, t)
	if typeof(from_value) == TYPE_QUATERNION and typeof(to_value) == TYPE_QUATERNION:
		var qa: Quaternion = from_value
		var qb: Quaternion = to_value
		return qa.slerp(qb, weight)
	var channels_from: PackedFloat64Array = value_to_channels(from_value)
	var channels_to: PackedFloat64Array = value_to_channels(to_value)
	if channels_from.is_empty() or channels_from.size() != channels_to.size():
		return from_value
	var mixed: PackedFloat64Array = PackedFloat64Array()
	for i: int in range(channels_from.size()):
		mixed.append(lerpf(channels_from[i], channels_to[i], weight))
	var result: Variant = channels_to_value(from_value, mixed)
	if result == null:
		return from_value
	return result


## 读取一条轨道的首尾关键帧信息。
## 返回 {"ok": bool, "error": String, "count": int, "time_from": float, "time_to": float,
##       "from": Variant, "to": Variant}
static func read_track_ends(animation: Animation, track_index: int) -> Dictionary:
	if animation == null:
		return _fail("没有选中动画")
	if track_index < 0 or track_index >= animation.get_track_count():
		return _fail("轨道索引越界")
	var count: int = animation.track_get_key_count(track_index)
	if count <= 0:
		return _fail("该轨道没有关键帧")
	var value_from: Variant = animation.track_get_key_value(track_index, 0)
	if channel_count(value_from) == 0:
		return _fail("该轨道的关键帧值不是受支持的数值类型")
	return {
		"ok": true,
		"error": "",
		"count": count,
		"time_from": animation.track_get_key_time(track_index, 0),
		"time_to": animation.track_get_key_time(track_index, count - 1),
		"from": value_from,
		"to": animation.track_get_key_value(track_index, count - 1),
	}


## 记录一条轨道当前的全部关键帧（用于撤销）。
static func capture_keys(animation: Animation, track_index: int) -> Array:
	var keys: Array = []
	if animation == null or track_index < 0 or track_index >= animation.get_track_count():
		return keys
	var count: int = animation.track_get_key_count(track_index)
	for i: int in range(count):
		keys.append({
			"time": animation.track_get_key_time(track_index, i),
			"value": animation.track_get_key_value(track_index, i),
			"transition": animation.track_get_key_transition(track_index, i),
		})
	return keys


## 计算重写后的关键帧序列。
## active_channels 是每个通道是否参与修改的掩码（1=参与，0=保持该关键帧原值）；
## 掩码比通道数短时，缺省视为参与。两侧都不参与的通道完全不动。
## 返回 {"ok": bool, "error": String, "keys": Array}
static func build_keys(animation: Animation, track_index: int, from_value: Variant, to_value: Variant, curve: int, keep_only_ends: bool, active_channels: PackedByteArray) -> Dictionary:
	var ends: Dictionary = read_track_ends(animation, track_index)
	if not bool(ends["ok"]):
		return _fail(String(ends["error"]))
	var count: int = int(ends["count"])
	if count < 2:
		return _fail("轨道只有 1 个关键帧，无法做起始值到终点值的过渡")
	if channel_count(from_value) == 0 or channel_count(from_value) != channel_count(to_value):
		return _fail("起始值/终点值与轨道的数值类型不匹配")
	var channels: int = edit_channel_count(from_value)
	if count_active_channels(active_channels, channels) == 0:
		return _fail("没有勾选任何要修改的通道，未做处理")
	var time_from: float = float(ends["time_from"])
	var time_to: float = float(ends["time_to"])

	var keys: Array = []
	if keep_only_ends:
		keys.append({
			"time": time_from,
			"value": _key_value(curve, 0.0, from_value, to_value, animation.track_get_key_value(track_index, 0), active_channels),
			"transition": 1.0,
		})
		keys.append({
			"time": time_to,
			"value": _key_value(curve, 1.0, from_value, to_value, animation.track_get_key_value(track_index, count - 1), active_channels),
			"transition": 1.0,
		})
		return {"ok": true, "error": "", "keys": keys}

	var span: float = time_to - time_from
	for i: int in range(count):
		var time: float = animation.track_get_key_time(track_index, i)
		var t: float = 0.0
		if absf(span) > EPSILON:
			t = (time - time_from) / span
		keys.append({
			"time": time,
			"value": _key_value(curve, t, from_value, to_value, animation.track_get_key_value(track_index, i), active_channels),
			"transition": animation.track_get_key_transition(track_index, i),
		})
	return {"ok": true, "error": "", "keys": keys}


## 计算某一个关键帧重写后的值。
## 旋转轨道：三个欧拉分量都参与时用 slerp（最短路径的旋转过渡）；
## 只勾选部分分量时在欧拉角空间按分量过渡，未勾选的分量保持该关键帧原值。
## 其余类型：逐分量插值，未勾选的分量换回该关键帧原值。
static func _key_value(curve: int, t: float, from_value: Variant, to_value: Variant, original: Variant, active_channels: PackedByteArray) -> Variant:
	if typeof(from_value) == TYPE_QUATERNION:
		if count_active_channels(active_channels, ANGLE_CHANNEL_COUNT) >= ANGLE_CHANNEL_COUNT:
			return interpolate_value(curve, t, from_value, to_value)
		return _blend_euler(curve, t, from_value, to_value, original, active_channels)
	var blended: Variant = _cast_like(original, interpolate_value(curve, t, from_value, to_value))
	return _merge_channels(original, blended, active_channels)


## 欧拉角空间的逐分量过渡：勾选的分量从起始角过渡到终点角，其余分量取该关键帧原角度。
static func _blend_euler(curve: int, t: float, from_value: Variant, to_value: Variant, original: Variant, active_channels: PackedByteArray) -> Variant:
	var from_euler: PackedFloat64Array = value_to_edit_channels(from_value)
	var to_euler: PackedFloat64Array = value_to_edit_channels(to_value)
	var original_euler: PackedFloat64Array = value_to_edit_channels(original)
	if from_euler.size() < ANGLE_CHANNEL_COUNT or original_euler.size() < ANGLE_CHANNEL_COUNT:
		return original
	var weight: float = curve_weight(curve, t)
	var mixed: PackedFloat64Array = PackedFloat64Array()
	for i: int in range(ANGLE_CHANNEL_COUNT):
		var active: bool = i >= active_channels.size() or active_channels[i] != 0
		if active:
			mixed.append(from_euler[i] + shortest_delta(from_euler[i], to_euler[i]) * weight)
		else:
			mixed.append(original_euler[i])
	var result: Variant = edit_channels_to_value(from_value, mixed)
	if result == null:
		return original
	return result


## 角度差取最短路径（结果落在 (-180, 180]），避免 170° -> -170° 绕远路转 340°。
static func shortest_delta(from_deg: float, to_deg: float) -> float:
	return wrapf(to_deg - from_deg + 180.0, 0.0, 360.0) - 180.0


## 统计参与修改的通道数。
static func count_active_channels(active_channels: PackedByteArray, channels: int) -> int:
	var total: int = 0
	for i: int in range(channels):
		if i >= active_channels.size() or active_channels[i] != 0:
			total += 1
	return total


## 把 target 中「未参与修改」的通道换回该关键帧的原值。
static func _merge_channels(original: Variant, target: Variant, active_channels: PackedByteArray) -> Variant:
	var target_values: PackedFloat64Array = value_to_channels(target)
	var original_values: PackedFloat64Array = value_to_channels(original)
	if target_values.is_empty() or target_values.size() != original_values.size():
		return target
	var merged: PackedFloat64Array = target_values.duplicate()
	for i: int in range(merged.size()):
		if i < active_channels.size() and active_channels[i] == 0:
			merged[i] = original_values[i]
	var result: Variant = channels_to_value(original, merged)
	if result == null:
		return target
	return result


## 用给定的关键帧序列重建一条轨道（撤销/重做也走这里）。
static func apply_keys(animation: Animation, track_index: int, keys: Array) -> void:
	if animation == null or track_index < 0 or track_index >= animation.get_track_count():
		return
	var existing: int = animation.track_get_key_count(track_index)
	var i: int = existing - 1
	while i >= 0:
		animation.track_remove_key(track_index, i)
		i -= 1
	for entry: Variant in keys:
		var key: Dictionary = entry
		animation.track_insert_key(
			track_index,
			float(key.get("time", 0.0)),
			key.get("value"),
			float(key.get("transition", 1.0))
		)
	animation.emit_changed()


## 把 value 按 template 的类型重新构造，避免把 float 写进 Vector3 轨道之类的问题。
static func _cast_like(template: Variant, value: Variant) -> Variant:
	if channel_count(value) == 0:
		return template
	var rebuilt: Variant = channels_to_value(template, value_to_channels(value))
	if rebuilt == null:
		return value
	return rebuilt


static func _fail(message: String) -> Dictionary:
	return {"ok": false, "error": message}


## 四元数按欧拉角显示，其余与 describe_value 一致。
static func describe_edit_value(value: Variant) -> String:
	if not is_angle_edit(value):
		return describe_value(value)
	var channels: PackedFloat64Array = value_to_edit_channels(value)
	var axes: PackedStringArray = PackedStringArray(["X", "Y", "Z"])
	var parts: PackedStringArray = PackedStringArray()
	for i: int in range(channels.size()):
		parts.append("%s %.1f°" % [axes[i], channels[i]])
	return "(" + ", ".join(parts) + ")"


## 便于界面显示: "(1.0000, 2.0000, 3.0000)"
static func describe_value(value: Variant) -> String:
	var channels: PackedFloat64Array = value_to_channels(value)
	if channels.is_empty():
		return str(value)
	var parts: PackedStringArray = PackedStringArray()
	for c: float in channels:
		parts.append("%.4f" % c)
	return "(" + ", ".join(parts) + ")"
