@tool
extends EditorPlugin
## 动画轨道插值器：把停靠面板挂到编辑器右侧。

const DOCK_SCENE: PackedScene = preload("res://addons/animation_track_interpolator/track_interpolator_dock.tscn")
const DOCK_TITLE: String = "轨道插值器"

var _dock: Control = null


func _enter_tree() -> void:
	_dock = DOCK_SCENE.instantiate() as Control
	if _dock == null:
		push_error("轨道插值器：无法实例化停靠面板场景。")
		return
	add_control_to_dock(EditorPlugin.DOCK_SLOT_RIGHT_UL, _dock)
	_apply_dock_title()
	# 面板被包进 EditorDock 的时机不确定，下一帧再设一次标题。
	call_deferred("_apply_dock_title")


func _exit_tree() -> void:
	if _dock == null:
		return
	remove_control_from_docks(_dock)
	_dock.queue_free()
	_dock = null


## add_control_to_dock 会把普通 Control 包进一个 EditorDock；这里把标题改成中文。
func _apply_dock_title() -> void:
	if _dock == null or not is_instance_valid(_dock):
		return
	var host: Node = _dock.get_parent()
	if host is EditorDock:
		var editor_dock: EditorDock = host as EditorDock
		editor_dock.title = DOCK_TITLE
