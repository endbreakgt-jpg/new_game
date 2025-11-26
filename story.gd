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
            _after_prologue_1()
            prologue_step = 1
        "prologue_5":
            _after_prologue_5()
            prologue_step = 2
        "prologue_10":
            _after_prologue_10()
            prologue_step = 3
        "prologue_15":
            _after_prologue_15()
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

func _on_dialog_line_started(id: String, seq: int, row: Dictionary) -> void:
    # ここで「どの id / seq にどう反応するか」を振り分ける

    # ★今回のテスト：prologue_1 の 60 行目
    if id == "prologue_1" and seq == 60:
        _on_prologue_1_seq_60(row)

    # 将来的には:
    # if id == "prologue_2" and seq == 10:
    #     _on_prologue_2_seq_10(row)
    # ...と増やしていけるようにしておく

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



func _after_prologue_1() -> void:
    # Durton 自宅での会話を終え、父親から
    # ・ギルド許可証を借りる
    # ・荷物を預かる
    # ・旅費を受け取る
    # ……という流れをログにだけ反映（数値は後で詰める想定）
    _notify_world("父親からギルド許可証と荷物、それに旅費を預かった。")

    # 将来的にはここで player.cash や cargo を調整しても良い
    # if world:
    #     var p := world.player
    #     p["cash"] = float(p.get("cash", 0.0)) + 100.0
    #     world.player = p

func _after_prologue_5() -> void:
    # Pilton の屋敷で荷物を渡し終えたあとの一息
    _notify_world("Pilton での配達を終えた。")

func _after_prologue_10() -> void:
    # ギルドで配達完了報告と代金受け取り
    _notify_world("Pilton 商人ギルドで配達の代金を受け取り、Durton への帰路についた。")

func _after_prologue_15() -> void:
    # Durton 帰宅後、父親と対話して「行商人になる」決意が固まる場面
    _notify_world("父親に代役を認められ、行商人としての一歩を踏み出した。")

func _on_dialog_line_started_v2(id: String, seq: int, row: Dictionary) -> void:
    if _maybe_start_pending_overlay(id, seq):
        return
    if id == "prologue_1" and seq == 60:
        _on_prologue_1_seq_60_v2(row)

func _on_prologue_1_seq_60_v2(row: Dictionary) -> void:
    if world and world.has_method("give_key_item"):
        world.give_key_item("guild_permit_father", 1)
    if _pending_system_msg == "":
        _pending_system_msg = "父親のギルド許可証を手に入れた"
        _pending_resume_id = _current_story_id
        _pending_resume_seq = 65

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
    # dialog_player を解決
    _resolve_dialog_player()
    if dialog_player == null:
        return

    # 二重接続防止
    var c := Callable(self, "_on_dialog_line_started_v2")
    if not dialog_player.line_started.is_connected(c):
        dialog_player.line_started.connect(c)
