extends Node2D
class_name MapLayer

signal city_picked(cid: String)
signal background_clicked

@export var world_path: NodePath
var world: World = null

@export var base_map: Texture2D
@export var base_map_path: String = "res://ui/back/WorldMap.png"

var _last_vp_size: Vector2i = Vector2i.ZERO

# ---- Zoom / Pan ----
@export var initial_zoom: float = 1.0
@export var zoom_min: float = 1.0
@export var zoom_max: float = 1.6
var _zoom: float = 1.0
var _pan: Vector2 = Vector2.ZERO
var _panning: bool = false
var _pan_start_screen: Vector2 = Vector2.ZERO
var _pan_start: Vector2 = Vector2.ZERO

# ---- Probe（座標取り）----
@export var probe_enabled: bool = true
@export var probe_copy_to_clipboard: bool = true
var _has_probe: bool = false
var _probe_tex: Vector2 = Vector2.ZERO
var _probe_screen: Vector2 = Vector2.ZERO

# ---- Pick policy / Hint ----
@export_enum("AdjacentOnly","AnyConnected","AnyCity") var pick_policy: int = 1
@export var show_pickable_hint: bool = true
@export var pickable_hint_color: Color = Color(1.0, 1.0, 1.0, 0.14)

# ---- Hover 強調 / 経路プレビュー ----
@export var hover_highlight: bool = true
@export var hover_color: Color = Color(1.0, 1.0, 0.2, 0.55)
@export var hover_ring_width: float = 3.0
@export var preview_path_on_hover: bool = true
@export var path_preview_color: Color = Color(0.2, 1.0, 0.6, 0.60)
@export var path_preview_width: float = 3.0

# ---- Label 表示モード ----
@export_enum("Always","HoverOrPick","None") var labels_mode: int = 1
@export var label_color: Color = Color.WHITE
@export var label_size: int = 14
@export var label_font: Font
@export var label_bg: Color = Color(0,0,0,0.55)

var _hover_cid: String = ""
var _hover_path: Array[String] = []
var _last_clicked_cid: String = ""
var _external_preview: bool = false

# ---- Data ----
@export var city_positions: Dictionary = {
    "RE0001": Vector2(478, 1585),
    "RE0002": Vector2(586, 2333),
    "RE0003": Vector2(714, 1787),
    "RE0004": Vector2(251, 2223),
    "RE0005": Vector2(304, 2559),
    "RE0006": Vector2(874, 2333),
    "RE0007": Vector2(1095, 1783),
    "RE0008": Vector2(1515, 2189),
   # "RE0009": Vector2(1188, 2369),    
}

@export var city_radius: float = 12.0
@export var route_width: float = 2.0
@export var city_color: Color = Color(0.2, 0.8, 1.0, 1.0)
@export var route_color: Color = Color(0.86, 0.86, 0.86, 1.0)
@export var route_waypoints_by_id: Dictionary = {
    # RT08: RE0006 → RE0008 を曲げる。テクスチャ座標での中継点
    "RT08": [Vector2(1158, 2369),
             Vector2(1347, 2323),],
    
}

@export var player_color: Color = Color(0.2, 1.0, 0.4, 1.0)
@export var trader_colors: Array[Color] = [
    Color(1.0, 0.8, 0.2, 1.0),
    Color(0.2, 1.0, 0.6, 1.0),
    Color(1.0, 0.4, 0.4, 1.0),
    Color(0.6, 0.6, 1.0, 1.0),
]
@export var trader_radius: float = 4.0

# ---- pick mode ----
var _pick_mode: bool = false
var _pick_origin: String = ""

func _ready() -> void:
    if world == null and world_path != NodePath("") and has_node(world_path):
        world = get_node_or_null(world_path)
    if base_map == null and base_map_path != "":
        var tex = load(base_map_path)
        if tex is Texture2D:
            base_map = tex
    _zoom = clamp(initial_zoom, zoom_min, zoom_max)
    set_process_input(true)
    set_process(true) # ← 追加：毎フレーム処理を有効化
    queue_redraw()


func _process(_delta: float) -> void:
    # 安全策：マウス左ボタンが離されていたらパン状態を強制解除
    if _panning and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
        _panning = false


func begin_pick_for_player() -> void:
    if world == null:
        return
    _pick_mode = true
    _pick_origin = String(world.player.get("city", ""))
    _hover_cid = ""
    _hover_path.clear()
    _last_clicked_cid = ""
    _external_preview = false
    queue_redraw()


func end_pick() -> void:
    _pick_mode = false
    _pick_origin = ""
    _hover_cid = ""
    _hover_path.clear()
    _last_clicked_cid = ""
    _external_preview = false
    queue_redraw()


func clear_pick_highlight() -> void:
    _hover_cid = ""
    _hover_path.clear()
    _last_clicked_cid = ""
    _external_preview = false
    queue_redraw()


func preview_move_target(cid: String) -> void:
    # MapWindow の都市一覧などからのホバー/クリック用に、
    # 都市ノードと同様のハイライト/経路プレビューを行う
    if world == null:
        return

    # pick_mode が立っていない場合はここで有効化してしまう
    if not _pick_mode:
        _pick_mode = true
        if _pick_origin == "":
            _pick_origin = String(world.player.get("city", ""))

    # 空文字や出発都市の場合はプレビューをクリア
    if cid == "" or cid == _pick_origin:
        _external_preview = false
        _hover_cid = ""
        _hover_path.clear()
        queue_redraw()
        return

    # 一覧など「外部 UI からのプレビュー」が有効
    _external_preview = true
    _hover_cid = cid
    _hover_path.clear()

    if preview_path_on_hover and world.has_method("compute_path"):
        var res: Dictionary = world.compute_path(_pick_origin, cid, "fastest")
        var path: Array = res.get("path", [])
        if path.size() >= 2:
            _hover_path = path

    queue_redraw()


# ---- helpers ----
func set_zoom(z: float) -> void:
    var v: float = clamp(z, zoom_min, zoom_max)
    _zoom = v
    queue_redraw()

func get_zoom() -> float: return _zoom
func zoom_in(step: float = 0.1) -> void: set_zoom(_zoom + step)
func zoom_out(step: float = 0.1) -> void: set_zoom(_zoom - step)

func _calc_draw_params() -> Dictionary:
    var vp: Vector2i = get_viewport_rect().size
    var ts: Vector2i = (base_map.get_size() if base_map else Vector2i(1,1))
    var fit: float = min(float(vp.x) / float(ts.x), float(vp.y) / float(ts.y))
    var scale: float = fit * _zoom
    var draw_size: Vector2 = Vector2(ts) * scale
    var offset0: Vector2 = (Vector2(vp) - draw_size) * 0.5
    var pan: Vector2 = _pan
    if draw_size.x <= float(vp.x):
        pan.x = 0.0
    else:
        var min_off_x: float = float(vp.x) - draw_size.x
        var max_off_x: float = 0.0
        var off_x: float = clamp(offset0.x + pan.x, min_off_x, max_off_x)
        pan.x = off_x - offset0.x
    if draw_size.y <= float(vp.y):
        pan.y = 0.0
    else:
        var min_off_y: float = float(vp.y) - draw_size.y
        var max_off_y: float = 0.0
        var off_y: float = clamp(offset0.y + pan.y, min_off_y, max_off_y)
        pan.y = off_y - offset0.y
    _pan = pan
    var offset: Vector2 = offset0 + pan
    return {"scale": scale, "draw_size": draw_size, "offset": offset}

func _tex_to_screen(p: Vector2) -> Vector2:
    var d := _calc_draw_params()
    return (d["offset"] as Vector2) + p * float(d["scale"])

func _screen_to_tex(p: Vector2) -> Vector2:
    var d := _calc_draw_params()
    var s: float = float(d["scale"])
    if s <= 0.0: return Vector2.ZERO
    return (p - (d["offset"] as Vector2)) / s

func _is_pickable(origin: String, target: String) -> bool:
    if origin == "" or target == "" or origin == target: return false
    match pick_policy:
        0: # 隣接のみ
            return (world != null and world.adj.has(origin) and (target in world.adj[origin]))
        1: # 連結ならOK
            return (world != null and world.has_method("path_exists") and world.path_exists(origin, target))
        2: # どこでも
            return true
        _:
            return true

func _input(event: InputEvent) -> void:
    var mb: InputEventMouseButton = event as InputEventMouseButton
    if mb and mb.pressed:
        if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
            zoom_in(0.08)
        elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
            if _zoom > zoom_min:
                zoom_out(0.08)
        elif mb.button_index == MOUSE_BUTTON_RIGHT and probe_enabled:
            var local: Vector2 = to_local(mb.position)
            var tex: Vector2 = _screen_to_tex(local)
            var t := Vector2(round(tex.x), round(tex.y))
            var s := Vector2(round(local.x), round(local.y))
            _has_probe = true
            _probe_tex = t
            _probe_screen = s
            var msg := "MapLayer probe: tex=(%d,%d)  screen=(%d, %d)" % [int(t.x), int(t.y), int(s.x), int(s.y)]
            print(msg)
            if probe_copy_to_clipboard:
                DisplayServer.clipboard_set(msg)
            queue_redraw()
            get_viewport().set_input_as_handled()

    if mb and mb.button_index == MOUSE_BUTTON_LEFT:
        if mb.pressed:
            # 背景クリック通知（確認ダイアログ前面化用）
            var _local_hit: Vector2 = to_local(mb.position)
            var _hit_cid2 := _city_at_point_screen(_local_hit)
            if _hit_cid2 == "":
                emit_signal("background_clicked")
            # パン開始判定
            if _zoom > 1.0:
                var local2: Vector2 = _local_hit
                var hit_cid := _hit_cid2
                if not (_pick_mode and hit_cid != ""):
                    _panning = true
                    _pan_start_screen = mb.position
                    _pan_start = _pan
                    _hover_cid = ""
                    _hover_path.clear()
                    _external_preview = false
                    get_viewport().set_input_as_handled()
        else:
            _panning = false

    var mm: InputEventMouseMotion = event as InputEventMouseMotion
    if mm:
        if _pick_mode and not _panning:
            var local3: Vector2 = to_local(mm.position)
            var cid_hover := _city_at_point_screen(local3)

            # ★ 外部プレビュー中かつ、マウス位置に都市が無い場合は何もしない
            #    → 一覧からのプレビューをマウス移動で消さないため
            if _external_preview and cid_hover == "":
                pass
            else:
                if cid_hover != _hover_cid:
                    # マップ上のホバーに切り替わったので外部プレビューは終了
                    _external_preview = false
                    _hover_cid = ("" if cid_hover == _pick_origin else cid_hover)
                    _hover_path.clear()
                    if preview_path_on_hover and _hover_cid != "" and world and world.has_method("compute_path"):
                        var res2: Dictionary = world.compute_path(_pick_origin, _hover_cid, "fastest")
                        _hover_path = res2.get("path", [])
                    queue_redraw()

        if _panning:
            var delta: Vector2 = mm.position - _pan_start_screen
            _pan = _pan_start + delta
            queue_redraw()
            get_viewport().set_input_as_handled()

    if not _pick_mode:
        return

    if mb and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT and not _panning:
        var local4: Vector2 = to_local(mb.position)
        var cid_click := _city_at_point_screen(local4)
        if cid_click != "" and _is_pickable(_pick_origin, cid_click):
            _last_clicked_cid = cid_click
            emit_signal("city_picked", cid_click)
            get_viewport().set_input_as_handled()


func _city_at_point_screen(p_screen: Vector2) -> String:
    var r: float = city_radius + 8.0
    for cid in city_positions.keys():
        var sp: Vector2 = _tex_to_screen(city_positions[cid])
        if sp.distance_to(p_screen) <= r:
            return String(cid)
    return ""

# ---- drawing ----
func _draw() -> void:
    if base_map != null:
        var d := _calc_draw_params()
        var draw_size: Vector2 = d["draw_size"]
        var offset: Vector2 = d["offset"]
        draw_texture_rect(base_map, Rect2(offset, draw_size), false)
    if world == null:
        return

    # ルート（危険度で赤み補間）
    for r in world.routes:
        var a := String(r["from"])
        var b := String(r["to"])
        if not (city_positions.has(a) and city_positions.has(b)):
            continue

        var haz: float = 0.0
        if world and world.has_method("_route_hazard"):
            haz = float(world._route_hazard(a, b))
        var col := route_color.lerp(
            Color(1.0, 0.3, 0.3, route_color.a),
            clamp(haz, 0.0, 1.0)
        )

        var pa_tex: Vector2 = city_positions[a]
        var pb_tex: Vector2 = city_positions[b]

        var rid := String(r.get("route_id", ""))
        if rid != "" and route_waypoints_by_id.has(rid):
            # 折れ線：出発→中継点群→到着 を順に描画
            var pts: Array[Vector2] = []
            pts.append(pa_tex)

            var wps: Variant = route_waypoints_by_id[rid]
            if wps is Array:
                for wp in wps:
                    if wp is Vector2:
                        pts.append(wp)

            pts.append(pb_tex)

            for i in range(pts.size() - 1):
                var p1: Vector2 = _tex_to_screen(pts[i])
                var p2: Vector2 = _tex_to_screen(pts[i + 1])
                draw_line(p1, p2, col, route_width)
        else:
            # デフォルト：直線
            var pa: Vector2 = _tex_to_screen(pa_tex)
            var pb: Vector2 = _tex_to_screen(pb_tex)
            draw_line(pa, pb, col, route_width)

    # 経路プレビュー（ホバー）
    if _pick_mode and preview_path_on_hover and _hover_path.size() >= 2:
        for i in range(_hover_path.size() - 1):
            var u := String(_hover_path[i])
            var v := String(_hover_path[i + 1])
            if not (city_positions.has(u) and city_positions.has(v)):
                continue

            var segment_pts: Array[Vector2] = []
            var used_waypoints: bool = false

            # ルート定義から、u-v を結ぶ route_id を探して中継点を適用
            if world and not route_waypoints_by_id.is_empty():
                for any_r2 in world.routes:
                    var r2: Dictionary = any_r2
                    var a2 := String(r2.get("from", ""))
                    var b2 := String(r2.get("to", ""))
                    # u-v または v-u のどちらかに一致するものだけを見る
                    if not ((a2 == u and b2 == v) or (a2 == v and b2 == u)):
                        continue

                    var rid2 := String(r2.get("route_id", ""))
                    if rid2 == "" or not route_waypoints_by_id.has(rid2):
                        continue

                    segment_pts.append(city_positions[u])

                    var wps2: Variant = route_waypoints_by_id[rid2]
                    if wps2 is Array:
                        var warr: Array = (wps2 as Array)
                        if a2 == u and b2 == v:
                            # ルート定義と同じ向き
                            for wp_any in warr:
                                var wp: Variant = wp_any
                                if wp is Vector2:
                                    segment_pts.append(wp)
                        else:
                            # 逆方向に辿る場合は中継点を反転
                            var rev: Array = warr.duplicate()
                            rev.reverse()
                            for wp_any2 in rev:
                                var wp2: Variant = wp_any2
                                if wp2 is Vector2:
                                    segment_pts.append(wp2)

                    segment_pts.append(city_positions[v])
                    used_waypoints = true
                    break

            # 中継点が無い／見つからない場合は直線
            if not used_waypoints:
                segment_pts.append(city_positions[u])
                segment_pts.append(city_positions[v])

            # セグメント列を画面座標に変換して描画
            for j in range(segment_pts.size() - 1):
                var p1_seg: Vector2 = _tex_to_screen(segment_pts[j])
                var p2_seg: Vector2 = _tex_to_screen(segment_pts[j + 1])
                draw_line(p1_seg, p2_seg, path_preview_color, path_preview_width)

    # Pickable hint（出発都市の隣接/連結）
    if _pick_mode and show_pickable_hint and world:
        for cid in city_positions.keys():
            if cid == _pick_origin:
                continue
            if _is_pickable(_pick_origin, cid):
                var sp := _tex_to_screen(city_positions[cid])
                draw_circle(sp, city_radius + 6.0, pickable_hint_color)

    # 都市ノード
    for cid in city_positions.keys():
        var p: Vector2 = _tex_to_screen(city_positions[cid])
        var col := city_color
        draw_circle(p, city_radius, col)
        # ホバー強調
        if _pick_mode and hover_highlight and cid == _hover_cid:
            draw_circle(p, city_radius + 6.0, hover_color)
        # プレイヤー位置
        if world and String(world.player.get("city", "")) == cid \
        and not bool(world.player.get("enroute", false)):
            draw_circle(p, city_radius * 0.65, player_color)

    # 都市ラベル
    if labels_mode == 0: # Always
        for cid in city_positions.keys():
            _draw_city_label(cid, _tex_to_screen(city_positions[cid]))
    elif labels_mode == 1: # HoverOrPick
        var show_ids: Array[String] = []
        if _pick_mode:
            if _pick_origin != "":
                show_ids.append(_pick_origin)
            if _hover_cid != "":
                show_ids.append(_hover_cid)
            if _last_clicked_cid != "":
                show_ids.append(_last_clicked_cid)
        else:
            if world and world.player.has("city"):
                show_ids.append(String(world.player["city"]))
        for cid in show_ids:
            if city_positions.has(cid):
                _draw_city_label(cid, _tex_to_screen(city_positions[cid]))

    # 右クリックの座標プローブ
    if _has_probe:
        draw_circle(_probe_screen, 4.0, Color(1, 1, 1, 0.9))
        draw_string(
            ThemeDB.fallback_font,
            _probe_screen + Vector2(8, -8),
            "tex:(%d,%d)" % [int(_probe_tex.x), int(_probe_tex.y)],
            HORIZONTAL_ALIGNMENT_LEFT,
            -1.0,
            12,
            Color(1, 1, 1, 0.9)
        )


func _draw_city_label(cid: String, sp: Vector2) -> void:
    var name: String = cid
    if world and world.cities.has(cid):
        name = String(world.cities[cid].get("name", cid))
    var font: Font = (label_font if label_font != null else ThemeDB.fallback_font)
    var size: int = label_size
    var bb := font.get_string_size(name, HORIZONTAL_ALIGNMENT_LEFT, -1, size)
    var pad := Vector2(8, 4)
    var rect := Rect2(sp + Vector2(10, -bb.y - 12) - pad * 0.5, bb + pad)
    draw_rect(rect, label_bg)
    draw_string(font, sp + Vector2(10, -12), name, HORIZONTAL_ALIGNMENT_LEFT, -1.0, size, label_color)
