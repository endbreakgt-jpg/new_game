extends Node
class_name CsvLoader

func load_csv_dicts(path: String, has_header: bool = true, delimiter: String = ",") -> Array[Dictionary]:
    var file := FileAccess.open(path, FileAccess.READ)
    if file == null:
        push_error("CSV open failed: %s" % path)
        return []

    var rows: Array[String] = []
    while not file.eof_reached():
        var line: String = file.get_line().strip_edges()
        if line == "" or line.begins_with("#"):
            pass # skip
        else:
            rows.append(line)
    file.close()

    if rows.is_empty():
        return []

    var headers: PackedStringArray = []
    var start_index: int = 0
    if has_header:
        var header_line: String = String(rows[0])
        header_line = header_line.replace("﻿", "") # BOM除去
        headers = header_line.split(delimiter)
        start_index = 1

    var out: Array[Dictionary] = []
    for i in range(start_index, rows.size()):
        var cols: PackedStringArray = String(rows[i]).split(delimiter)
        var d: Dictionary = {}
        if has_header:
            var limit: int = int(min(headers.size(), cols.size()))
            for j in range(limit):
                d[headers[j]] = _auto_type(String(cols[j]))
        else:
            for j in range(cols.size()):
                d["c%d" % j] = _auto_type(String(cols[j]))
        out.append(d)
    return out

func _auto_type(s: String):
    if s.is_valid_float():
        var fval: float = s.to_float()
        var ival: int = int(fval)
        if abs(fval - float(ival)) < 0.000001:
            return ival
        else:
            return fval
    elif s.to_lower() == "true":
        return true
    elif s.to_lower() == "false":
        return false
    else:
        return s

func load_key_items(path: String) -> Dictionary:
    # key_items.csv を {key_id: row} の辞書に変換して返す
    # row は load_csv() の型推論済み Dictionary（int/float/bool など）になる
    var rows: Array[Dictionary] = load_csv(path, true, ",", true)
    var out: Dictionary = {}
    for r in rows:
        var key_id: String = String(r.get("key_id", r.get("id", ""))).strip_edges()
        if key_id == "":
            continue
        out[key_id] = r
    return out
