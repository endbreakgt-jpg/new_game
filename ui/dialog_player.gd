extends Node
class_name DialogPlayer

signal line_started(id: String, seq: int, row: Dictionary)

@export var csv_path: String = "res://data/dialogs.csv"
@export var dialog_ui_path: NodePath

var dialog_ui: Dialog
var rows_by_id: Dictionary = {}

# 現在再生中の行データ
# - _active_script_rows : CSV上の行（DEV含む）
# - _active_visible_rows: 表示対象の行（DEV除外 + 途中注入(system)含む）
var _active_script_rows: Array[Dictionary] = []
var _active_visible_rows: Array[Dictionary] = []
var _visible_to_script: Array[int] = [] # visible_index -> script_index（注入行は -1）
var _active_id: String = ""
var _current_script_index: int = -1
var _emit_guard_token: int = 0

func _ready() -> void:
    _resolve_dialog_ui()
    _load_csv()

func _resolve_dialog_ui() -> void:
    dialog_ui = null
    if dialog_ui_path != NodePath():
        dialog_ui = get_node_or_null(dialog_ui_path) as Dialog
    if dialog_ui:
        _prepare_dialog_ui()
        return

    # Try to locate a Dialog node nearby (e.g. under HUD)
    var owner_node: Node = self
    while owner_node and dialog_ui == null:
        var found := owner_node.find_child("Dialog", true, false)
        if found and found is Dialog:
            dialog_ui = found as Dialog
        owner_node = owner_node.get_parent()

    if dialog_ui == null and get_tree():
        var root := get_tree().root
        if root:
            var fallback := root.find_child("Dialog", true, false)
            if fallback and fallback is Dialog:
                dialog_ui = fallback as Dialog
                _prepare_dialog_ui()
                return

    if dialog_ui:
        _prepare_dialog_ui()

func _prepare_dialog_ui() -> void:
    if dialog_ui == null:
        return
    if not dialog_ui.is_inside_tree():
        return
    dialog_ui.process_mode = Node.PROCESS_MODE_ALWAYS
    if dialog_ui is Control:
        var ctrl := dialog_ui as Control
        if not ctrl.top_level:
            ctrl.top_level = true
        if ctrl.z_index < 1024:
            ctrl.z_index = 1024
        ctrl.call_deferred("raise")
    # 進行に合わせたポートレート切替
    if not dialog_ui.advanced.is_connected(Callable(self, "_on_dialog_advanced")):
        dialog_ui.advanced.connect(_on_dialog_advanced)
    if not dialog_ui.finished.is_connected(Callable(self, "_on_dialog_finished")):
        dialog_ui.finished.connect(_on_dialog_finished)

func _load_csv() -> void:
    var loader := CsvLoader.new()
    var rows: Array[Dictionary] = loader.load_csv_dicts(csv_path, true, ",")
    rows_by_id.clear()
    for r in rows:
        var id := str(r.get("id", ""))
        if id == "":
            continue
        if not rows_by_id.has(id):
            rows_by_id[id] = []
        rows_by_id[id].append(r)
    # seqで昇順ソート
    for id in rows_by_id.keys():
        rows_by_id[id].sort_custom(func(a, b): return int(a.get("seq", 0)) < int(b.get("seq", 0)))

func play(id: String) -> bool:
    return _play_from_index(id, 0)

func play_from_seq(id: String, start_seq: int) -> bool:
    # seq（CSVの値）を指定して、そこから再生する
    var rows: Array = rows_by_id.get(id, [])
    if rows.is_empty():
        return false
    var start_index: int = 0
    for i in range(rows.size()):
        var r: Dictionary = rows[i] as Dictionary
        var s: int = int(r.get("seq", 0))
        if s >= start_seq:
            start_index = i
            break
    return _play_from_index(id, start_index)



func show_system_message(text: String, speaker: String = "システム") -> void:
    # トーストを廃して「ダイアログ表示」に統一するための入口。
    # 既に DialogPlayer が再生中なら、次の行として差し込んで同じ流れで見せる。
    if dialog_ui == null:
        _resolve_dialog_ui()
    if dialog_ui == null:
        push_warning("DialogPlayer: dialog_ui is not assigned.")
        return

    _prepare_dialog_ui()

    var t := text.strip_edges()
    if t == "":
        return

    # 再生中（Story再生中）の場合：次の行として差し込んで、ストーリーの進行を壊さない
    if dialog_ui.is_dialog_mode and not _active_visible_rows.is_empty():
        var insert_at: int = int((dialog_ui as Dialog).current_index) + 1
        insert_at = clamp(insert_at, 0, _active_visible_rows.size())

        # 同フレームに複数の system が来ても順序が崩れないよう、既に差し込まれた system の後ろに積む
        while insert_at < _active_visible_rows.size() and String(_active_visible_rows[insert_at].get("type", "")) == "system":
            insert_at += 1

        var row: Dictionary = {
            "seq": -1,
            "speaker": speaker,
            "text": t,
            "portrait": "",
            "type": "system",
        }

        _active_visible_rows.insert(insert_at, row)
        _visible_to_script.insert(insert_at, -1)

        if dialog_ui.has_method("insert_lines"):
            (dialog_ui as Dialog).insert_lines(insert_at, [t])
        else:
            # 古い Dialog.gd の場合の保険：末尾に追加（すぐには出ないが、完全に消えるよりマシ）
            dialog_ui.show_lines([t], speaker)

        return


    # それ以外：単発のシステムダイアログとして表示
    dialog_ui.show_lines([t], speaker)

func _play_from_index(id: String, start_index: int) -> bool:
    if dialog_ui == null:
        _resolve_dialog_ui()
    if dialog_ui == null:
        push_error("DialogPlayer: dialog_ui is not assigned.")
        return false
    _prepare_dialog_ui()

    var rows: Array = rows_by_id.get(id, [])
    if rows.is_empty():
        push_warning("DialogPlayer: id '%s' not found in %s" % [id, csv_path])
        return false

    if start_index < 0:
        start_index = 0
    if start_index >= rows.size():
        start_index = max(0, rows.size() - 1)

    # 行データを保持
    _active_script_rows.clear()
    _active_visible_rows.clear()
    _visible_to_script.clear()
    _current_script_index = -1

    # script rows（DEV含む）
    for i in range(start_index, rows.size()):
        _active_script_rows.append(rows[i] as Dictionary)

    # visible rows（DEV除外）
    for si in range(_active_script_rows.size()):
        var r: Dictionary = _active_script_rows[si]
        var sp: String = String(r.get("speaker", r.get("char", "")))
        if sp == "DEV":
            continue
        _active_visible_rows.append(r)
        _visible_to_script.append(si)

    _active_id = id
    _emit_guard_token += 1
    var token: int = _emit_guard_token

    if _active_visible_rows.is_empty():
        # DEV行だけのIDなど
        push_warning("DialogPlayer: id '%s' has no visible lines." % id)
        return false

    # テキストだけまとめて Dialog に渡す（DEV行は表示しない）
    var lines: Array[String] = []
    for r in _active_visible_rows:
        lines.append(str(r.get("text", "")))

    # speaker はここでは空で渡しておき、後から _apply_visible_row(0) で設定する
    dialog_ui.show_lines(lines, "")

    # 先頭行の speaker / portrait を反映
    _apply_visible_row(0)

    # 先頭表示行より前にある DEV コマンドを実行（例：ctx_place など）
    var first_script_index: int = int(_visible_to_script[0])
    if first_script_index > 0:
        _emit_pending_dev(0, first_script_index - 1)
        # break などで止められた場合
        if dialog_ui != null and not dialog_ui.is_dialog_mode:
            return true

    _current_script_index = first_script_index

    # Story 側が advanced を見てから処理できるよう、line_started は遅延で流す
    call_deferred("_emit_line_started", token, 0)

    return true

func _emit_line_started(token: int, visible_index: int) -> void:
    if token != _emit_guard_token:
        return
    if _active_visible_rows.is_empty():
        return
    if visible_index < 0 or visible_index >= _active_visible_rows.size():
        return

    # 注入(system)行はトリガーに使わない
    var row: Dictionary = _active_visible_rows[visible_index]
    if String(row.get("type", "")) == "system":
        return

    var si: int = int(_visible_to_script[visible_index])
    if si < 0:
        return

    var seq: int = int(row.get("seq", 0))
    line_started.emit(_active_id, seq, row)

func _apply_visible_row(visible_index: int) -> void:
    if dialog_ui == null:
        return
    if visible_index < 0 or visible_index >= _active_visible_rows.size():
        return

    var r: Dictionary = _active_visible_rows[visible_index]

    # スピーカー名
    var speaker := str(r.get("speaker", r.get("char", "")))
    if dialog_ui.has_method("set_speaker"):
        dialog_ui.call("set_speaker", speaker)

    # ポートレート
    var p := str(r.get("portraits", r.get("portrait", "")))
    if dialog_ui.has_method("set_portrait_by_path"):
        (dialog_ui as Dialog).set_portrait_by_path(p)


# ダイアログの進行に合わせて行ごとに画像を切替
# ダイアログの進行に合わせて行ごとに speaker / 画像を切替
func _on_dialog_advanced(next_index: int) -> void:
    if _active_visible_rows.is_empty():
        return
    if next_index < 0:
        return

    # 最終行の次（Dialog.gd が stop_dialog する直前）でも advanced が飛ぶので、
    # その場合は「残っているDEV行」だけ実行して終える。
    if next_index >= _active_visible_rows.size():
        _emit_pending_dev(_current_script_index + 1, _active_script_rows.size() - 1)
        return

    # 次の表示行が、元スクリプトのどの行か
    var next_script_index: int = int(_visible_to_script[next_index])

    # 注入(system)行：スクリプト上の位置を持たないので DEV は処理しない
    if next_script_index < 0:
        _apply_visible_row(next_index)
        return

    # 次の表示行までの間にある DEV 行を先に実行する
    if _current_script_index >= 0 and next_script_index > _current_script_index + 1:
        _emit_pending_dev(_current_script_index + 1, next_script_index - 1)
        # break などで会話が止められた場合、次の行へは進めない
        if dialog_ui != null and not dialog_ui.is_dialog_mode:
            return

    _current_script_index = next_script_index
    _apply_visible_row(next_index)
    var token: int = _emit_guard_token
    call_deferred("_emit_line_started", token, next_index)

func _on_dialog_finished() -> void:
    # 途中で stop_dialog された場合も含めて、状態だけ掃除
    _emit_guard_token += 1
    _active_id = ""
    _active_script_rows.clear()
    _active_visible_rows.clear()
    _visible_to_script.clear()
    _current_script_index = -1

func _emit_pending_dev(from_script_index: int, to_script_index: int) -> void:
    if _active_script_rows.is_empty():
        return
    if from_script_index < 0:
        from_script_index = 0
    if to_script_index >= _active_script_rows.size():
        to_script_index = _active_script_rows.size() - 1
    if to_script_index < from_script_index:
        return

    for si in range(from_script_index, to_script_index + 1):
        var r: Dictionary = _active_script_rows[si]
        var sp: String = String(r.get("speaker", r.get("char", "")))
        if sp != "DEV":
            continue
        var seq: int = int(r.get("seq", 0))
        line_started.emit(_active_id, seq, r)

func get_next_non_dev_seq(id: String, after_seq: int) -> int:
    # DEV行の次に来る「表示される行」の seq を返す。
    # 見つからない場合は -1。
    var rows: Array = rows_by_id.get(id, [])
    if rows.is_empty():
        return -1
    for r_any in rows:
        var r: Dictionary = r_any as Dictionary
        var s: int = int(r.get("seq", 0))
        if s <= after_seq:
            continue
        var sp: String = String(r.get("speaker", r.get("char", "")))
        if sp == "DEV":
            continue
        return s
    return -1
