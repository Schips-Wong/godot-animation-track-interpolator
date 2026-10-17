@tool
extends RefCounted
## 动画轨道插值核心逻辑（纯逻辑，不依赖编辑器界面，可单独测试）。
##
## 作用：把一条数值类轨道（值 / 位置 3D / 旋转 3D / 缩放 3D）的所有关键帧，
## 按照指定的曲线方式从「起始值」过渡到「终点值」。
## 关键帧的时间点默认保持不变，只重写每一帧的值；也可以选择只保留首尾两帧。

## 插值（过渡）方式。0..6，顺序与 curve_labels() 一致。
const CURVE_LINEAR: int = 0 ## 线性匀速
const CURVE_SMOOTH: int = 1 ## 平滑（缓入缓出）
const CURVE_EASE_IN: int = 2 ## 缓入（加速）
const CURVE_EASE_OUT: int = 3 ## 缓出（减速）
const CURVE_SINE: int = 4 ## 正弦过渡
const CURVE_STEP: int = 5 ## 阶跃：保持起始值直到最后一帧
const CURVE_CUSTOM: int = 6 ## 自定义曲线：权重由可编辑的图形决定（见 SHAPE_*）

const EPSILON: float = 0.000001

## 旋转轨道在界面上按欧拉角的三个轴（X/Y/Z）编辑。
const ANGLE_CHANNEL_COUNT: int = 3

## 「自定义曲线」的图形模型（图表操作方式）。
const SHAPE_POINTS: int = 0 ## 多控制点：任意个控制点，用 Hermite 平滑连接
const SHAPE_BEZIER: int = 1 ## 两点三次贝塞尔：用 h1 / h2 两个手柄（同 CSS cubic-bezier）
const SHAPE_ELASTIC: int = 2 ## 弹性：用「振幅 / 周期」两个手柄做带回弹的缓动

## 镜像方式（作用于 1x1 的图形方框）。
const MIRROR_CENTER: int = 0 ## 绕中心点对称（旋转 180°）：M(t) = 1 - B(1-t)
const MIRROR_HORIZONTAL: int = 1 ## 左右翻转：M(t) = B(1-t)
const MIRROR_VERTICAL: int = 2 ## 上下翻转：M(t) = 1 - B(t)

## 弹性缓动的方向。
const EASE_IN: int = 0
const EASE_OUT: int = 1
const EASE_IN_OUT: int = 2


## 支持的插值方式显示名（顺序与 Curve 枚举一致）。
static func curve_labels() -> PackedStringArray:
	return PackedStringArray([
		"线性（匀速）",
		"平滑（缓入缓出）",
		"缓入（加速）",
		"缓出（减速）",
		"正弦过渡",
		"阶跃（保持起始值到最后一帧）",
		"自定义曲线（可拖拽控制点）",
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


## 三种图形模型的显示名（顺序与 SHAPE_* 一致）。
static func shape_mode_labels() -> PackedStringArray:
	return PackedStringArray(["多控制点", "贝塞尔", "弹性"])


## 三种镜像方式的显示名（顺序与 MIRROR_* 一致）。
static func mirror_mode_labels() -> PackedStringArray:
	return PackedStringArray(["中心镜像", "水平镜像", "垂直镜像"])


## 弹性缓动方向的显示名（顺序与 EASE_* 一致）。
static func ease_labels() -> PackedStringArray:
	return PackedStringArray(["缓入", "缓出", "缓入缓出"])


## 自定义曲线的默认图形。所有模型都保证权重 0->0、1->1，且允许中途越界（回弹 / 预动作）。
static func default_shape() -> Dictionary:
	return {
		"mode": SHAPE_POINTS,
		"points": PackedVector2Array([Vector2(0.0, 0.0), Vector2(1.0, 1.0)]),
		"h1": Vector2(0.25, 0.0),
		"h2": Vector2(0.75, 1.0),
		"amplitude": 1.0,
		"period": 0.3,
		"ease": EASE_OUT,
	}


## 按图形模型求权重。
static func shape_weight(shape: Dictionary, t: float) -> float:
	var x: float = clampf(t, 0.0, 1.0)
	match int(shape.get("mode", SHAPE_POINTS)):
		SHAPE_BEZIER:
			var h1: Vector2 = shape.get("h1", Vector2(0.25, 0.0))
			var h2: Vector2 = shape.get("h2", Vector2(0.75, 1.0))
			return bezier_weight(h1, h2, x)
		SHAPE_ELASTIC:
			return elastic_weight(
				float(shape.get("amplitude", 1.0)),
				float(shape.get("period", 0.3)),
				int(shape.get("ease", EASE_OUT)),
				x
			)
	var points: PackedVector2Array = shape.get("points", PackedVector2Array([Vector2(0.0, 0.0), Vector2(1.0, 1.0)]))
	return sample_curve(points, x)


## 归一化时间 t(0~1) 在指定方式下的插值权重。
## curve 为 CURVE_CUSTOM 时改用 shape（图形）求值，否则走内置公式。
static func weight_for(curve: int, t: float, shape: Dictionary = {}) -> float:
	if curve == CURVE_CUSTOM and not shape.is_empty():
		return shape_weight(shape, t)
	return curve_weight(curve, t)


## 把一个点按指定的镜像方式变换（基准是 1x1 的方框）。
## 中心镜像：1 - B(1-t)，仍是 0->0 / 1->1 的有效缓动（反向缓动）；
## 水平镜像：B(1-t)，端点互换，变成 1->0；
## 垂直镜像：1 - B(t)，端点互换，变成 1->0。
static func mirror_point(point: Vector2, mirror: int = MIRROR_CENTER) -> Vector2:
	var x: float = clampf(point.x, 0.0, 1.0)
	match mirror:
		MIRROR_HORIZONTAL:
			return Vector2(1.0 - x, point.y)
		MIRROR_VERTICAL:
			return Vector2(x, 1.0 - point.y)
	return Vector2(1.0 - x, 1.0 - point.y)


## 该图形模型能否用自身参数精确表达这种镜像。
## 中心镜像对所有模型都成立（M(t) = 1 - B(1-t)，端点仍是 0->0 / 1->1）。
## 水平 / 垂直镜像会交换端点（得到 1->0 的递减曲线），只有「多控制点」能表达；
## 贝塞尔端点锁死在 (0,0)/(1,1)、弹性只有三种回弹形态，都做不到。
static func mirror_supported(mode: int, mirror: int) -> bool:
	return mirror == MIRROR_CENTER or mode == SHAPE_POINTS


## 把一组控制点按镜像方式变换，并整理成可采样形式（x 升序、首点 x=0、末点 x=1）。
static func mirror_points(points: PackedVector2Array, mirror: int) -> PackedVector2Array:
	var out: PackedVector2Array = PackedVector2Array()
	if mirror == MIRROR_VERTICAL:
		for point: Vector2 in points:
			out.append(mirror_point(point, mirror))
		return normalize_points(out)
	# 中心 / 水平镜像都会把 x 反过来，倒序遍历以保持 x 升序。
	for i: int in range(points.size() - 1, -1, -1):
		out.append(mirror_point(points[i], mirror))
	return normalize_points(out)


## 把图形按指定方式镜像。
## 调用前请先查 mirror_supported()：不支持的组合会原样返回（避免产出畸形曲线）。
static func mirror_shape(shape: Dictionary, mirror: int = MIRROR_CENTER) -> Dictionary:
	var out: Dictionary = shape.duplicate(true)
	var mode: int = int(out.get("mode", SHAPE_POINTS))
	if not mirror_supported(mode, mirror):
		return out
	match mode:
		SHAPE_BEZIER:
			var h1: Vector2 = out.get("h1", Vector2(0.25, 0.0))
			var h2: Vector2 = out.get("h2", Vector2(0.75, 1.0))
			out["h1"] = mirror_point(h2, mirror)
			out["h2"] = mirror_point(h1, mirror)
		SHAPE_ELASTIC:
			var ease: int = int(out.get("ease", EASE_OUT))
			out["ease"] = EASE_IN if ease == EASE_OUT else (EASE_OUT if ease == EASE_IN else EASE_IN_OUT)
		_:
			var points: PackedVector2Array = out.get("points", PackedVector2Array())
			out["points"] = mirror_points(points, mirror)
	return out


# ---------------------------------------------------------------- 贝塞尔模型

## 两点三次贝塞尔：P0=(0,0)、P1=h1、P2=h2、P3=(1,1)。
## h 的 x 分量被限制在 0~1（保证曲线是 x 的单调函数、可以反解）；y 分量不受限，因此可以越界回弹。
static func bezier_weight(h1: Vector2, h2: Vector2, x: float) -> float:
	var x1: float = clampf(h1.x, 0.0, 1.0)
	var x2: float = clampf(h2.x, 0.0, 1.0)
	var u: float = bezier_solve_u(x1, x2, clampf(x, 0.0, 1.0))
	return _bezier_axis(u, h1.y, h2.y)


## 三次贝塞尔在参数 u 处的某一轴取值（两个控制点坐标 + 固定的 0 / 1 端点）。
static func _bezier_axis(u: float, a: float, b: float) -> float:
	var v: float = 1.0 - u
	return 3.0 * v * v * u * a + 3.0 * v * u * u * b + u * u * u


## 已知横坐标 x 反解参数 u：先牛顿迭代，失败则退回二分。
static func bezier_solve_u(x1: float, x2: float, x: float) -> float:
	var u: float = clampf(x, 0.0, 1.0)
	for i: int in range(8):
		var error: float = _bezier_axis(u, x1, x2) - x
		if absf(error) < 0.0000001:
			return u
		var v: float = 1.0 - u
		var slope: float = 3.0 * v * v * x1 + 6.0 * v * u * (x2 - x1) + 3.0 * u * u * (1.0 - x2)
		if absf(slope) < EPSILON:
			break
		u = clampf(u - error / slope, 0.0, 1.0)
	var low: float = 0.0
	var high: float = 1.0
	for i: int in range(24):
		u = 0.5 * (low + high)
		if _bezier_axis(u, x1, x2) < x:
			low = u
		else:
			high = u
	return u


# ---------------------------------------------------------------- 弹性模型

## 弹性缓动（Penner 经典公式）。amplitude 是回弹幅度，period 是振荡周期，ease 选缓入 / 缓出 / 缓入缓出。
static func elastic_weight(amplitude: float, period: float, ease: int, x: float) -> float:
	var t: float = clampf(x, 0.0, 1.0)
	match ease:
		EASE_IN:
			return 1.0 - _elastic_out(1.0 - t, amplitude, period)
		EASE_IN_OUT:
			if t < 0.5:
				return 0.5 * (1.0 - _elastic_out(1.0 - 2.0 * t, amplitude, period))
			return 0.5 + 0.5 * _elastic_out(2.0 * t - 1.0, amplitude, period)
	return _elastic_out(t, amplitude, period)


## 弹性缓出的基函数：w(0)=0、w(1)=1，中间围绕终点来回振荡并衰减。
static func _elastic_out(t: float, amplitude: float, period: float) -> float:
	if t <= 0.0:
		return 0.0
	if t >= 1.0:
		return 1.0
	var a: float = maxf(amplitude, 0.05)
	var p: float = clampf(period, 0.02, 2.0)
	var phase: float = p / 4.0
	if a > 1.0:
		phase = p / TAU * asin(clampf(1.0 / a, -1.0, 1.0))
	return a * pow(2.0, -10.0 * t) * sin((t - phase) * TAU / p) + 1.0


## 把控制点整理成可采样形式：按 x 升序、x 限制在 0~1、去掉重复 x，并保证首点 x=0、末点 x=1。
static func normalize_points(points: PackedVector2Array) -> PackedVector2Array:
	var sorted: Array[Vector2] = []
	for point: Vector2 in points:
		sorted.append(Vector2(clampf(point.x, 0.0, 1.0), point.y))
	sorted.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.x < b.x)
	var out: PackedVector2Array = PackedVector2Array()
	for point: Vector2 in sorted:
		var last_x: float = out[out.size() - 1].x if not out.is_empty() else -1.0
		if point.x - last_x > EPSILON:
			out.append(point)
	if out.size() < 2:
		return PackedVector2Array([Vector2(0.0, 0.0), Vector2(1.0, 1.0)])
	out[0] = Vector2(0.0, out[0].y)
	out[out.size() - 1] = Vector2(1.0, out[out.size() - 1].y)
	return out


## 采样自定义曲线：x 是归一化时间，返回值即插值权重。
## 权重允许小于 0 / 大于 1（用于预动作、回弹）；x=0 与 x=1 处的权重固定为控制点首尾的 y。
static func sample_curve(points: PackedVector2Array, t: float) -> float:
	var pts: PackedVector2Array = normalize_points(points)
	var x: float = clampf(t, 0.0, 1.0)
	for i: int in range(pts.size() - 1):
		if x <= pts[i + 1].x:
			return _hermite_at(pts, i, x)
	return pts[pts.size() - 1].y


## 在控制点 i 与 i+1 之间用 Hermite 基函数求值（切线取相邻点的有限差分）。
static func _hermite_at(pts: PackedVector2Array, i: int, x: float) -> float:
	var p1: Vector2 = pts[i]
	var p2: Vector2 = pts[i + 1]
	var span: float = p2.x - p1.x
	if span <= EPSILON:
		return p2.y
	var u: float = (x - p1.x) / span
	var m1: float = _point_slope(pts, i) * span
	var m2: float = _point_slope(pts, i + 1) * span
	var u2: float = u * u
	var u3: float = u2 * u
	var h00: float = 2.0 * u3 - 3.0 * u2 + 1.0
	var h10: float = u3 - 2.0 * u2 + u
	var h01: float = -2.0 * u3 + 3.0 * u2
	var h11: float = u3 - u2
	return h00 * p1.y + h10 * m1 + h01 * p2.y + h11 * m2


## 控制点处的切线斜率：中间点用前后相邻点求差分，端点用相邻线段的斜率。
static func _point_slope(pts: PackedVector2Array, i: int) -> float:
	if i <= 0:
		return _secant_slope(pts[0], pts[1])
	if i >= pts.size() - 1:
		return _secant_slope(pts[pts.size() - 2], pts[pts.size() - 1])
	return _secant_slope(pts[i - 1], pts[i + 1])


static func _secant_slope(a: Vector2, b: Vector2) -> float:
	var dx: float = b.x - a.x
	if absf(dx) <= EPSILON:
		return 0.0
	return (b.y - a.y) / dx


## 预设方式采样出的控制点：作为「自定义曲线」继续手调的起点。
static func preset_points(curve: int, segments: int = 4) -> PackedVector2Array:
	var out: PackedVector2Array = PackedVector2Array()
	if curve == CURVE_CUSTOM:
		return out
	if curve == CURVE_STEP:
		out.append(Vector2(0.0, 0.0))
		out.append(Vector2(0.85, 0.0))
		out.append(Vector2(1.0, 1.0))
		return out
	var steps: int = maxi(segments, 1)
	for i: int in range(steps + 1):
		var x: float = float(i) / float(steps)
		out.append(Vector2(x, curve_weight(curve, x)))
	return out


## 在 from_value 与 to_value 之间按指定的方式过渡。四元数走 slerp 保证旋转正确。
static func interpolate_value(curve: int, t: float, from_value: Variant, to_value: Variant, shape: Dictionary = {}) -> Variant:
	var weight: float = weight_for(curve, t, shape)
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


## 生效时间范围（秒）：只有落在这个范围内的关键帧会被改写。
## from / to 为 NaN 表示沿用默认范围（见 full_range()）。
static func default_range() -> Dictionary:
	return {"from": NAN, "to": NAN}


## 默认生效范围：整条动画（0 ~ animation.length）。
## 动画长度可能没覆盖到轨道末尾（比如长度没同步更新，或 Godot 把长度钳成 0.001），
## 此时取动画长度与轨道尾帧时间的较大值，保证默认范围不会把关键帧排除在外。
static func full_range(animation: Animation, track_index: int = -1) -> Vector2:
	var range_to: float = 0.0
	if animation != null:
		range_to = animation.length
	var ends: Dictionary = read_track_ends(animation, track_index)
	if bool(ends["ok"]):
		range_to = maxf(range_to, float(ends["time_to"]))
	if range_to <= EPSILON:
		return Vector2(0.0, 1.0)
	return Vector2(0.0, range_to)


## 校验生效范围；返回空串表示合法。
static func range_error(active_range: Dictionary) -> String:
	var has_from: bool = not is_nan(float(active_range.get("from", NAN)))
	var has_to: bool = not is_nan(float(active_range.get("to", NAN)))
	if has_from != has_to:
		return "生效范围的起始时刻与结束时刻需要同时设置"
	if has_from and float(active_range["to"]) - float(active_range["from"]) <= EPSILON:
		return "生效范围的结束时刻必须大于起始时刻"
	return ""


## 关键帧时间是否落在生效范围内（含边界）。
static func in_range(time: float, range_from: float, range_to: float) -> bool:
	return time >= range_from - EPSILON and time <= range_to + EPSILON


## 关键帧时间在生效范围里的位置（0~1，超出部分夹紧）。
static func range_position(time: float, range_from: float, range_to: float) -> float:
	var span: float = range_to - range_from
	if absf(span) <= EPSILON:
		return 0.0
	return clampf((time - range_from) / span, 0.0, 1.0)


## 计算重写后的关键帧序列。
## active_channels 是每个通道是否参与修改的掩码（1=参与，0=保持该关键帧原值）；
## 掩码比通道数短时，缺省视为参与。两侧都不参与的通道完全不动。
## curve_shape 仅在 curve 为 CURVE_CUSTOM 时生效，用来决定每一帧的过渡权重。
## active_range 见 default_range()：范围外的关键帧原值不动，范围内的按曲线过渡。
## 返回 {"ok": bool, "error": String, "keys": Array}
static func build_keys(animation: Animation, track_index: int, from_value: Variant, to_value: Variant, curve: int, keep_only_ends: bool, active_channels: PackedByteArray, curve_shape: Dictionary = {}, active_range: Dictionary = {}) -> Dictionary:
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
	var range_error_text: String = range_error(active_range)
	if range_error_text != "":
		return _fail(range_error_text)

	# 默认范围：整条动画（0 ~ 动画长度）。
	var fallback_range: Vector2 = full_range(animation, track_index)
	var range_from: float = fallback_range.x
	var range_to: float = fallback_range.y
	if not is_nan(float(active_range.get("from", NAN))):
		range_from = float(active_range["from"])
		range_to = float(active_range["to"])

	# 范围内的关键帧：第一帧用来承载「起始值」，最后一帧承载「终点值」。
	var first_inside: int = -1
	var last_inside: int = -1
	for i: int in range(count):
		if in_range(animation.track_get_key_time(track_index, i), range_from, range_to):
			if first_inside == -1:
				first_inside = i
			last_inside = i
	if first_inside == -1:
		return _fail("生效范围内没有关键帧，未做处理")

	var keys: Array = []
	if keep_only_ends:
		# 范围内只留两帧（范围起点、范围终点），范围外的关键帧原样保留。
		keys.append({
			"time": range_from,
			"value": _key_value(curve, 0.0, from_value, to_value, animation.track_get_key_value(track_index, first_inside), active_channels, curve_shape),
			"transition": 1.0,
		})
		keys.append({
			"time": range_to,
			"value": _key_value(curve, 1.0, from_value, to_value, animation.track_get_key_value(track_index, last_inside), active_channels, curve_shape),
			"transition": 1.0,
		})
		for i: int in range(count):
			if i >= first_inside and i <= last_inside:
				continue
			keys.append({
				"time": animation.track_get_key_time(track_index, i),
				"value": animation.track_get_key_value(track_index, i),
				"transition": animation.track_get_key_transition(track_index, i),
			})
		return {"ok": true, "error": "", "keys": keys}

	for i: int in range(count):
		var time: float = animation.track_get_key_time(track_index, i)
		var original: Variant = animation.track_get_key_value(track_index, i)
		var transition: float = animation.track_get_key_transition(track_index, i)
		if not in_range(time, range_from, range_to):
			keys.append({"time": time, "value": original, "transition": transition})
			continue
		var position: float = range_position(time, range_from, range_to)
		keys.append({
			"time": time,
			"value": _key_value(curve, position, from_value, to_value, original, active_channels, curve_shape),
			"transition": transition,
		})
	return {"ok": true, "error": "", "keys": keys}


## 计算某一个关键帧重写后的值。t 是它在生效范围里的位置（0~1）。
## 旋转轨道：三个欧拉分量都参与时用 slerp（最短路径的旋转过渡）；
## 只勾选部分分量时在欧拉角空间按分量过渡，未勾选的分量保持该关键帧原值。
## 其余类型：逐分量插值，未勾选的分量换回该关键帧原值。
static func _key_value(curve: int, t: float, from_value: Variant, to_value: Variant, original: Variant, active_channels: PackedByteArray, curve_shape: Dictionary = {}) -> Variant:
	var position: float = clampf(t, 0.0, 1.0)
	if typeof(from_value) == TYPE_QUATERNION:
		if count_active_channels(active_channels, ANGLE_CHANNEL_COUNT) >= ANGLE_CHANNEL_COUNT:
			return interpolate_value(curve, position, from_value, to_value, curve_shape)
		return _blend_euler(curve, position, from_value, to_value, original, active_channels, curve_shape)
	var blended: Variant = _cast_like(original, interpolate_value(curve, position, from_value, to_value, curve_shape))
	return _merge_channels(original, blended, active_channels)


## 欧拉角空间的逐分量过渡：勾选的分量从起始角过渡到终点角，其余分量取该关键帧原角度。
static func _blend_euler(curve: int, t: float, from_value: Variant, to_value: Variant, original: Variant, active_channels: PackedByteArray, curve_shape: Dictionary = {}) -> Variant:
	var from_euler: PackedFloat64Array = value_to_edit_channels(from_value)
	var to_euler: PackedFloat64Array = value_to_edit_channels(to_value)
	var original_euler: PackedFloat64Array = value_to_edit_channels(original)
	if from_euler.size() < ANGLE_CHANNEL_COUNT or original_euler.size() < ANGLE_CHANNEL_COUNT:
		return original
	var weight: float = weight_for(curve, t, curve_shape)
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
