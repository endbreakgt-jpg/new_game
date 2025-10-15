extends Node
class_name DialogPlayer

@export var csv_path: String = "res://data/dialogs.csv"
@export var dialog_ui_path: NodePath

var dialog_ui: Dialog
var rows_by_id: Dictionary = {}

func _ready() -> void:
    if dialog_ui_path != NodePath():
        dialog_ui = get_node(dialog_ui_path) as Dialog
    _load_csv()

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

func play(id: String) -> void:
    if dialog_ui == null:
        push_error("DialogPlayer: dialog_ui is not assigned.")
        return
    var rows: Array = rows_by_id.get(id, [])
    if rows.is_empty():
        push_warning("DialogPlayer: id '%s' not found in %s" % [id, csv_path])
        return
    var speaker := str(rows[0].get("speaker", ""))
    var lines: Array[String] = []
    for r in rows:
        lines.append(str(r.get("text", "")))
    dialog_ui.show_lines(lines, speaker)
