# rank_table.gd
extends RefCounted
class_name RankTable

var ratios: Dictionary = {}
var has_data: bool = false

func from_rows(rows: Array) -> void:
    has_data = false
    ratios.clear()
    for r in rows:
        var rank := int(r.get("RANK", 0))
        if rank < 1:
            continue
        var rec := {}
        rec["cons_mult"] = _parse_float(r.get("cons_mult", 1.0))
        rec["prod_bonus"] = _parse_percent(r.get("prod_bonus", "0%"))
        rec["safety_days"] = _parse_float(r.get("safety_days", 10.0))
        ratios[rank] = rec
    has_data = ratios.size() > 0

func get_cons_mult(rank: int, fallback: float = 1.0) -> float:
    var r : int = clamp(rank, 1, 10)
    if ratios.has(r):
        return float(ratios[r].get("cons_mult", fallback))
    return fallback

func get_prod_bonus(rank: int, fallback: float = 0.0) -> float:
    var r : int = clamp(rank, 1, 10)
    if ratios.has(r):
        return float(ratios[r].get("prod_bonus", fallback))
    return fallback

func get_safety_days(rank: int, fallback: float = 10.0) -> float:
    var r : int = clamp(rank, 1, 10)
    if ratios.has(r):
        return float(ratios[r].get("safety_days", fallback))
    return fallback

func _parse_percent(v) -> float:
    var s := str(v).strip_edges()
    s = s.replace("%","").replace("+","")
    s = s.replace(",","")
    if s == "" or s == ".":
        return 0.0
    return float(s) / 100.0

func _parse_float(v) -> float:
    return float(str(v).strip_edges())
