extends Node2D

@warning_ignore("UNUSED_SIGNAL")
signal city_picked(cid: String)        # ← 追加：選択された都市ID
# === Official Map Layer ===

@export var world_path: NodePath
var world: World

@export var city_positions: Dictionary = {
    "RE0001": Vector2(180, 250),
    "RE0002": Vector2(360, 230),
    "RE0003": Vector2(580, 210),
    "RE0004": Vector2(720, 140),  # Highmoor（北東）
    "RE0005": Vector2(640, 340),  # Southwatch（南東）
    "RE0006": Vector2(280, 360),  # Alderdale（南西）
}

@export var city_radius: float = 10.0
@export var route_width: float = 2.0
@export var city_color: Color = Color(0.2, 0.6, 1.0)
@export var route_color: Color = Color(0.8, 0.8, 0.8)
@export var label_color: Color = Color.WHITE
@export var label_size: int = 14
@export var label_font: Font

@export var player_color: Color = Color(0.2, 1.0, 0.4)
@export var trader_colors: Array[Color] = [
    Color(1.0, 0.8, 0.2),
    Color(0.2, 1.0, 0.6),
    Color(1.0, 0.4, 0.4),
    Color(0.6, 0.6, 1.0),
]
@export var trader_radius: float = 4.0

# ---- 追加：移動先選択モード（HUDから開始/終了させる） ----
var _pick_mode: bool = false
var _pick_origin: String = ""   # 出発都市（プレイヤーの現在地）

func begin_pick_for_player() -> void:
    if world == null:
        return
    _pick_mode = true
    _pick_origin = String(world.player.get("city", ""))
    queue_redraw()

func end_pick() -> void:
    _pick_mode = false
    _pick_origin = ""
    queue_redraw()

func _ready() -> void:
    if world == null:
        if world_path != NodePath(""):
            var n := get_node_or_null(world_path)
            world = n as World
        else:
            world = get_parent() as World
    if world:
        world.day_advanced.connect(func(_d): queue_redraw())
        world.world_updated.connect(func(): queue_redraw())
    set_process(true)
    set_process_unhandled_input(true)

func _process(_dt: float) -> void:
    queue_redraw()

func _unhandled_input(e: InputEvent) -> void:
    if _pick_mode and e.is_action_pressed("ui_cancel"):
        end_pick()
        get_viewport().set_input_as_handled()

func _input(event: InputEvent) -> void:
    if not _pick_mode:
        return
    var mb := event as InputEventMouseButton
    if mb and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
        var local := to_local(mb.position)
        var cid := _city_at_point(local)
        if cid != "":
            # 隣接のみOK
            if world and world.adj.has(_pick_origin) and (cid in world.adj[_pick_origin]) and cid != _pick_origin:
                emit_signal("city_picked", cid)
            else:
                OS.alert("That city isn't adjacent.")

func _city_at_point(p: Vector2) -> String:
    var r := city_radius + 8.0
    for cid in city_positions.keys():
        if city_positions[cid].distance_to(p) <= r:
            return String(cid)
    return ""

func _draw() -> void:
    if world == null:
        return
    # ルート
    for r in world.routes:
        var a := String(r["from"])
        var b := String(r["to"])
        if not (city_positions.has(a) and city_positions.has(b)):
            continue
        draw_line(city_positions[a], city_positions[b], route_color, route_width)

    # ラベル用フォント
    var f: Font = (label_font if label_font != null else ThemeDB.fallback_font)

    # 都市
    for cid in world.cities.keys():
        if not city_positions.has(cid):
            continue
        var p: Vector2 = city_positions[cid]
        draw_circle(p, city_radius, city_color)
        if f:
            draw_string(f, p + Vector2(-city_radius, -city_radius - 4),
                String(world.cities[cid]["name"]), HORIZONTAL_ALIGNMENT_LEFT, -1.0, label_size, label_color)

    # プレイヤー
    if world.player.size() > 0:
        var pp: Vector2 = _entity_pos(world.player)
        draw_circle(pp, trader_radius + 2.0, player_color)

    # NPCs
    var i := 0
    for t in world.traders:
        var pos: Vector2 = _entity_pos(t)
        var col: Color = trader_colors[i % trader_colors.size()]
        draw_circle(pos, trader_radius, col)
        i += 1

    # 追加：選択モードのハイライト
    if _pick_mode and _pick_origin != "" and city_positions.has(_pick_origin):
        var org: Vector2 = city_positions.get(_pick_origin, Vector2.ZERO)
        draw_circle(org, city_radius + 6.0, Color(1,1,0,0.35)) # 出発都市
        if world.adj.has(_pick_origin):
            for nb in (world.adj[_pick_origin] as Array):
                if city_positions.has(nb):
                    draw_circle(city_positions[nb], city_radius + 6.0, Color(0,1,0,0.28)) # 隣接OK
        if f:
            draw_string(f, Vector2(12, 24), "Select a destination (Esc to cancel)", HORIZONTAL_ALIGNMENT_LEFT, -1.0, 16, Color(1,1,1,0.8))

# 都市間補間（既存）
func _entity_pos(t: Dictionary) -> Vector2:
    var cid: String = String(t.get("city", ""))
    var dest: String = String(t.get("dest", ""))
    var enroute: bool = bool(t.get("enroute", false))
    if not enroute:
        return city_positions.get(cid, Vector2.ZERO)
    if not (city_positions.has(cid) and city_positions.has(dest)):
        return Vector2.ZERO
    var a: Vector2 = city_positions[cid]
    var b: Vector2 = city_positions[dest]
    var days: float = float(world._route_days(cid, dest))
    if days <= 0.0:
        return a
    var arr_day: float = float(t.get("arrival_day", world.day))
    var remaining: float = maxf(0.0, arr_day - float(world.day) - world.get_day_progress())
    var frac: float = 1.0 - clampf(remaining / days, 0.0, 1.0)
    return a.lerp(b, frac)
