extends Node
class_name DialogPlayer

@export var csv_path: String = "res://data/dialogs.csv"
@export var dialog_ui_path: NodePath

var dialog_ui: Dialog
var rows_by_id: Dictionary = {}

# 現在再生中の行データ（ポートレート切替に使用）
var _active_rows: Array[Dictionary] = []

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

    # スピーカー名・台詞・初期ポートレート
    _active_rows.clear()
    for r in rows:
        _active_rows.append(r as Dictionary)
    var speaker := str((rows[0] as Dictionary).get("speaker", ""))
    var portrait_path := str((rows[0] as Dictionary).get("portraits", (rows[0] as Dictionary).get("portrait", "")))
    var lines: Array[String] = []
    for r_any in rows:
        var r: Dictionary = r_any
        lines.append(str(r.get("text", "")))
    # 初期ポートレート（UI側にAPIがある前提）
    if dialog_ui and dialog_ui.has_method("set_portrait_by_path"):
        (dialog_ui as Dialog).set_portrait_by_path(portrait_path)

    dialog_ui.show_lines(lines, speaker)
    return true

# ダイアログの進行に合わせて行ごとに画像を切替
func _on_dialog_advanced(next_index: int) -> void:
    # next_index は現在の行インデックス（0起点）
    if _active_rows.is_empty():
        return
    if next_index >= 0 and next_index < _active_rows.size():
        var r: Dictionary = _active_rows[next_index]
        var p := str(r.get("portraits", r.get("portrait", "")))
        if dialog_ui and dialog_ui.has_method("set_portrait_by_path"):
            (dialog_ui as Dialog).set_portrait_by_path(p)
