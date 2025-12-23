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
var _resume_after_break: Dictionary = {} # {"id":String, "seq":int}
var _last_line_info: Dictionary = {} # {"id":String, "seq":int, "row":Dictionary}
var _suppress_next_line_started: bool = false

# DEVコンテキスト（表示はしない、メモ用）
var ctx_place: String = ""

# break の前状態復帰（プロローグ以外でも安全に動くように）
var _break_prev_running_prologue: bool = false
var _break_prev_story_id: String = ""

# プロローグ進行状態
var prologue_done: bool = false
var prologue_step: int = 0   # 0: 未開始, 1..途中, 4以上: 完了
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
    if prologue_done:
        _notify_world("プロローグはすでに完了しています。")
        return
    if _running_prologue:
        return

    # チュートリアル状態（プロローグ）
    if world != null and world.has_method("set_tutorial_state"):
        world.set_tutorial_state(World.TUT_STATE_PROLOGUE, true, "start_prologue")

    _running_prologue = true
    prologue_step = 0
    _play_next_prologue()
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
    if not dialog_ui.advanced.is_connected(Callable(self, "_on_dialog_advanced")):
        dialog_ui.advanced.connect(_on_dialog_advanced)

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

func _on_dialog_line_started(id: String, seq: int, row: Dictionary) -> void:
    if _suppress_next_line_started:
        _suppress_next_line_started = false
        return

    _last_line_info = {"id": id, "seq": seq, "row": row}

    # DEV：画面に出さず、処理だけ
    var speaker: String = String(row.get("speaker", row.get("char", "")))
    if speaker == "DEV":
        _run_dev_command(id, seq, String(row.get("text", "")))
        return

    if _maybe_start_pending_overlay(id, seq):
        return


func _run_dev_command(id: String, seq: int, text: String) -> void:
    var t: String = text.strip_edges()
    if t == "":
        return

    var parts: Array[String] = t.split(" ", false)
    if parts.is_empty():
        return

    var cmd: String = parts[0].to_lower()

    match cmd:
        "break":
            _dev_break(id, seq)
        "keyitem_grant":
            if parts.size() < 2:
                _dev_log("[DEV] keyitem_grant: missing key_id")
                return
            var key_id: String = parts[1]
            var count: int = 1
            if parts.size() >= 3:
                count = int(parts[2])
            _dev_keyitem_grant(key_id, count)
        "keyitem_remove":
            if parts.size() < 2:
                _dev_log("[DEV] keyitem_remove: missing key_id")
                return
            var key_id2: String = parts[1]
            var count2: int = 1
            if parts.size() >= 3:
                count2 = int(parts[2])
            _dev_keyitem_remove(key_id2, count2)
        "ctx_place":
            if parts.size() < 2:
                ctx_place = ""
            else:
                ctx_place = parts[1]
            _dev_log("[DEV] ctx_place=%s" % ctx_place)
        "note":
            # メモ。ゲーム状態は変えない。
            _dev_log("[DEV note] %s" % t.substr(4).strip_edges())
        _:
            _dev_log("[DEV] unknown command: %s" % t)


func _dev_break(id: String, seq: int) -> void:
    var resume_seq: int = -1
    if dialog_player and dialog_player.has_method("get_next_non_dev_seq"):
        resume_seq = int(dialog_player.call("get_next_non_dev_seq", id, seq))
    if resume_seq <= 0:
        resume_seq = seq + 1
    _queue_break_and_resume(id, resume_seq)
    _last_line_info.clear()


func _dev_keyitem_grant(key_id: String, count: int) -> void:
    if world == null:
        _dev_log("[DEV] keyitem_grant: world is null")
        return
    if not world.has_method("give_key_item"):
        _dev_log("[DEV] keyitem_grant: World has no give_key_item")
        return

    var qty: int = max(1, count)
    # システムメッセージはCSV側（speaker=システム）で出す。ここでは実データだけ。
    var ok: bool = bool(world.give_key_item(key_id, qty, false))
    if not ok:
        _dev_log("[DEV] keyitem_grant failed: %s" % key_id)


func _dev_keyitem_remove(key_id: String, count: int) -> void:
    if world == null:
        _dev_log("[DEV] keyitem_remove: world is null")
        return
    if not world.has_method("remove_key_item"):
        _dev_log("[DEV] keyitem_remove: World has no remove_key_item")
        return
    var qty: int = max(1, count)
    world.remove_key_item(key_id, qty)


func _dev_log(msg: String) -> void:
    if world != null and world.has_method("_log"):
        world.call("_log", msg)
    else:
        print(msg)


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
    _notify_world("プロローグが終わりました。")

    # 次フェーズへ（現時点では tut1 へ。必要に応じて tut1開始演出側へ移してOK）
    if world != null and world.has_method("set_tutorial_state"):
        # プロローグ用ロックを解除（apply_profile=false で locks は維持されるので明示解除）
        if world.has_method("clear_tutorial_locks"):
            world.clear_tutorial_locks()
        world.set_tutorial_state(World.TUT_STATE_TUT1, false, "finish_prologue")

func _queue_break_and_resume(id: String, resume_seq: int) -> void:
    # break は「会話の一時停止」扱い。
    # stop_dialog による finished をプロローグ完了と誤認しないよう、一旦フラグを退避して落とす。
    _break_prev_running_prologue = _running_prologue
    _break_prev_story_id = _current_story_id
    _resume_after_break = {"id": id, "seq": resume_seq}
    _current_story_id = ""
    _running_prologue = false
    if dialog_ui:
        if dialog_ui.has_method("stop_dialog_keep_blocker"):
            dialog_ui.call("stop_dialog_keep_blocker")
        else:
            dialog_ui.stop_dialog()
    var timer := get_tree().create_timer(0.2)
    timer.timeout.connect(_resume_story_after_break)


func _resume_story_after_break() -> void:
    var rid := String(_resume_after_break.get("id", ""))
    var rseq := int(_resume_after_break.get("seq", 0))
    _resume_after_break.clear()
    if dialog_player and rid != "" and rseq > 0:
        # 退避していた状態を復元（プロローグ以外でも壊さない）
        if _break_prev_story_id != "":
            _current_story_id = _break_prev_story_id
        else:
            _current_story_id = rid
        _running_prologue = _break_prev_running_prologue
        _break_prev_story_id = ""
        _break_prev_running_prologue = false
        dialog_player.play_from_seq(rid, rseq)

func _show_system_message(text: String) -> void:
    # システムメッセージ表示は DialogPlayer に統一（トースト/AcceptDialog は使わない）
    if dialog_player and dialog_player.has_method("show_system_message"):
        dialog_player.call("show_system_message", text)
        return

    # フォールバック（dialog_player が未接続のシーンでも表示できるように）
    _resolve_dialog_ui()
    if dialog_ui:
        dialog_ui.show_lines([text], "システム")

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

func _on_dialog_advanced(next_index: int) -> void:
    if _overlay_active:
        return
    if _last_line_info.is_empty():
        return
    # 進行に応じたトリガーが必要ならここに置く。
    # ただし、会話CSVのDEV行（break/keyitem_.../ctx_placeなど）に寄せて
    # Story側のseqハードコードは極力避ける。


func _after_prologue_1() -> void:
    _notify_world("父親からギルド許可証と荷物、それに旅費を預かった。")

func _after_prologue_5() -> void:
    _notify_world("Pilton での配達を終えた。")

func _after_prologue_10() -> void:
    _notify_world("Pilton のギルドで配達の代金を受け取り、Durton への帰路についた。")

func _after_prologue_15() -> void:
    _notify_world("父親に代役を認められ、行商人としての一歩を踏み出した。")

func _connect_dialog_triggers() -> void:
    _resolve_dialog_player()
    if dialog_player == null:
        return
    var c := Callable(self, "_on_dialog_line_started")
    if not dialog_player.line_started.is_connected(c):
        dialog_player.line_started.connect(c)
