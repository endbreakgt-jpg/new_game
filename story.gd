extends Node
class_name Story

@export var world_path: NodePath
@export var dialog_player_path: NodePath
@export var dialog_ui_path: NodePath

var world: World = null
var dialog_player: DialogPlayer = null
var dialog_ui: Dialog = null
var _overlay_active: bool = false
var _resume_info: Dictionary = {} # {"id":String, "seq":int}
var _pending_system_msg: String = ""
var _pending_resume_id: String = ""
var _pending_resume_seq: int = -1


# プロローグ進行状態
var prologue_done: bool = false
var prologue_step: int = 0   # 0: 未開始, 1〜: 途中, 4以降: 完了
var _current_story_id: String = ""
var _running_prologue: bool = false

var _prologue_ids: Array[String] = [
    "prologue_1",
    "prologue_5",
    "prologue_10",
    "prologue_15"
]

func _ready() -> void:
    _resolve_world()
    _resolve_dialog_player()
    _resolve_dialog_ui()
    _connect_dialog_signals()
    _connect_dialog_triggers()


# === 外部インターフェース ================================================

func start_prologue() -> void:
    # すでに終わっているなら軽く通知だけ
    if prologue_done:
        _notify_world("プロローグはすでに完了しています。")
        return

    # 進行中なら何もしない（連打防止）
    if _running_prologue:
        return

    _running_prologue = true
    prologue_step = 0
    _play_next_prologue()


# === 解決系ユーティリティ ================================================

func _resolve_world() -> void:
    if world != null and is_instance_valid(world):
        return

    if world_path != NodePath("") and has_node(world_path):
        world = get_node_or_null(world_path) as World
    elif get_parent() is World:
        world = get_parent() as World
    elif get_tree() != null:
        var root := get_tree().root
        if root != null:
            var found := root.find_child("World", true, false)
            if found is World:
                world = found as World

func _resolve_dialog_player() -> void:
    if dialog_player != null and is_instance_valid(dialog_player):
        return

    if dialog_player_path != NodePath("") and has_node(dialog_player_path):
        dialog_player = get_node_or_null(dialog_player_path) as DialogPlayer
    elif get_tree() != null:
        var root := get_tree().root
        if root != null:
            var found := root.find_child("DialogPlayer", true, false)
            if found is DialogPlayer:
                dialog_player = found as DialogPlayer

func _resolve_dialog_ui() -> void:
    if dialog_ui != null and is_instance_valid(dialog_ui):
        return

    if dialog_ui_path != NodePath("") and has_node(dialog_ui_path):
        dialog_ui = get_node_or_null(dialog_ui_path) as Dialog
    elif dialog_player != null:
        var candidate = dialog_player.get("dialog_ui")
        if candidate is Dialog:
            dialog_ui = candidate as Dialog
    elif get_tree() != null:
        var root := get_tree().root
        if root != null:
            var found := root.find_child("Dialog", true, false)
            if found is Dialog:
                dialog_ui = found as Dialog

func _connect_dialog_signals() -> void:
    if dialog_ui == null:
        return
    if not dialog_ui.finished.is_connected(Callable(self, "_on_dialog_finished")):
        dialog_ui.finished.connect(_on_dialog_finished)


func _notify_world(msg: String) -> void:
    if world == null:
        return
    if world.has_method("_world_message"):
        world.call("_world_message", msg)


# === プロローグ進行ロジック ==============================================

func _play_next_prologue() -> void:
    if prologue_step < 0:
        prologue_step = 0

    if prologue_step >= _prologue_ids.size():
        _finish_prologue()
        return

    _resolve_dialog_player()
    _resolve_dialog_ui()
    _connect_dialog_signals()

    if dialog_player == null:
        push_error("Story: DialogPlayer が見つかりません。")
        _running_prologue = false
        return
    if not dialog_player.has_method("play"):
        push_error("Story: DialogPlayer に play() がありません。")
        _running_prologue = false
        return

    var id := _prologue_ids[prologue_step]
    _current_story_id = id

    var result = dialog_player.call("play", id)
    if result is bool and not result:
        push_warning("Story: ダイアログID '%s' の再生に失敗しました。" % id)


func _on_dialog_finished() -> void:
    if _overlay_active:
        _overlay_active = false
        var resume_id: String = String(_resume_info.get("id", ""))
        var resume_seq: int = int(_resume_info.get("seq", 0))
        _resume_info.clear()
        if resume_id != "" and dialog_player:
            _current_story_id = resume_id
            _running_prologue = true
            dialog_player.play_from_seq(resume_id, resume_seq)
        return
    if not _running_prologue:
        return
    if _current_story_id == "":
        return

    var just_id := _current_story_id
    _current_story_id = ""

    match just_id:
        "prologue_1":
            prologue_step = 1
        "prologue_5":
            prologue_step = 2
        "prologue_10":
            prologue_step = 3
        "prologue_15":
            prologue_step = 4
            _finish_prologue()
            return
        _:
            pass

    _play_next_prologue()

func _finish_prologue() -> void:
    prologue_done = true
    _running_prologue = false
    _notify_world("プロローグが終了しました。")




# === 各パート終了時の“間に挟まる処理” ====================================

# Story.gd へ追加
func _show_system_message(text: String) -> void:
    _resolve_dialog_ui()
    if dialog_ui:
        dialog_ui.show_lines([text], "System")

func _on_prologue_1_seq_60(row: Dictionary) -> void:
    if world and world.has_method("give_key_item"):
        world.give_key_item("guild_permit_father", 1)
    _resume_info = {"id": _current_story_id, "seq": 65}
    _overlay_active = true
    _current_story_id = "" # システムメッセージ完了時に Story を進めない
    call_deferred("_show_system_message", "父親のギルド許可証を手に入れた")

func _maybe_start_pending_overlay(id: String, seq: int) -> bool:
    if _pending_system_msg == "":
        return false
    if id != _pending_resume_id:
        return false
    if seq < _pending_resume_seq:
        return false

    _overlay_active = true
    _resume_info = {"id": _pending_resume_id, "seq": _pending_resume_seq}
    _pending_resume_id = ""
    _pending_resume_seq = -1
    var msg := _pending_system_msg
    _pending_system_msg = ""
    _current_story_id = ""
    call_deferred("_show_system_message", msg)
    return true

func _connect_dialog_triggers() -> void:
    _resolve_dialog_player()
    if dialog_player == null:
        return
    var c := Callable(self, "_on_dialog_line_started")
    if not dialog_player.line_started.is_connected(c):
        dialog_player.line_started.connect(c)

# 追加: 再開予約
var _resume_after_break: Dictionary = {} # {"id":String, "seq":int}

func _on_dialog_line_started(id: String, seq: int, row: Dictionary) -> void:
    # 既存の pending オーバーレイがあれば先に処理
    if _maybe_start_pending_overlay(id, seq):
        return
    if id == "prologue_1" and seq == 55:
        _queue_break_and_resume(id, 60)
        return
    # 既存の seq==60 トリガーなどはそのまま

func _queue_break_and_resume(id: String, resume_seq: int) -> void:
    _resume_after_break = {"id": id, "seq": resume_seq}
    _current_story_id = ""  # 以降の _on_dialog_finished で誤進行しないようにクリア
    _running_prologue = false
    # ダイアログを一旦閉じる
    if dialog_ui:
        dialog_ui.stop_dialog()
    # 少し後で再開（演出用に 0.2〜0.5秒を好みで）
    call_deferred("_resume_story_after_break")

func _resume_story_after_break() -> void:
    var rid := String(_resume_after_break.get("id", ""))
    var rseq := int(_resume_after_break.get("seq", 0))
    _resume_after_break.clear()
    if dialog_player and rid != "" and rseq > 0:
        _current_story_id = rid
        _running_prologue = true
        dialog_player.play_from_seq(rid, rseq)
