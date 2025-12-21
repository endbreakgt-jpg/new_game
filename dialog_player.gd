extends Node
class_name DialogPlayer

signal line_started(id: String, seq: int, row: Dictionary)

@export var csv_path: String = "res://data/dialogs.csv"
@export var dialog_ui_path: NodePath

var dialog_ui: Dialog
var rows_by_id: Dictionary = {}

# 現在再生中の行データ（ポートレート切替に使用）
var _active_rows: Array[Dictionary] = []
var _active_id: String = ""
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

    # 行データを保持（speaker / portrait / Storyトリガー用）
    _active_rows.clear()
    for i in range(start_index, rows.size()):
        _active_rows.append(rows[i] as Dictionary)
    _active_id = id
    _emit_guard_token += 1
    var token: int = _emit_guard_token

    # テキストだけまとめて Dialog に渡す
    var lines: Array[String] = []
    for r in _active_rows:
        lines.append(str(r.get("text", "")))

    # speaker はここでは空で渡しておき、後から _apply_row(0) で設定する
    dialog_ui.show_lines(lines, "")

    # 先頭行の speaker / portrait を反映
    _apply_row(0)

    # Story 側が advanced を見てから処理できるよう、line_started は遅延で流す
    call_deferred("_emit_line_started", token, 0)

    return true

func _emit_line_started(token: int, index: int) -> void:
    if token != _emit_guard_token:
        return
    if _active_rows.is_empty():
        return
    if index < 0 or index >= _active_rows.size():
        return
    var row: Dictionary = _active_rows[index]
    var seq: int = int(row.get("seq", 0))
    line_started.emit(_active_id, seq, row)

func _apply_row(index: int) -> void:
    if dialog_ui == null:
        return
    if index < 0 or index >= _active_rows.size():
        return

    var r: Dictionary = _active_rows[index]

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
    if _active_rows.is_empty():
        return
    if next_index < 0 or next_index >= _active_rows.size():
        return
    _apply_row(next_index)
    var token: int = _emit_guard_token
    call_deferred("_emit_line_started", token, next_index)

func _on_dialog_finished() -> void:
    # 途中で stop_dialog された場合も含めて、状態だけ掃除
    _emit_guard_token += 1
    _active_id = ""
    _active_rows.clear()
