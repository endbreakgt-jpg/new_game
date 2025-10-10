extends Control
class_name MenuPanel
## ドラッグ移動できる「×付きサブウィンドウ」風メニュー（ツリー事前配置なしでも動く）

@export var world_path: NodePath
var world: World
var hud: Node  ## GameHUD から注入

# --- UI refs（動的生成/取得） ---
var panel: PanelContainer
var title_bar: HBoxContainer
var close_btn: Button
var trade_btn: Button
var map_btn: Button
var step_btn: Button
var move_btn: Button
var inv_btn: Button
var info_day: Label
var info_city: Label
var info_cash: Label
var info_cargo: Label

# ドラッグ用
var _dragging := false
var _drag_start := Vector2.ZERO
var _panel_start := Vector2.ZERO

func _ready() -> void:
    # World 取得
    if world_path != NodePath(""):
        world = get_node_or_null(world_path) as World
    if world == null:
        world = get_tree().root.find_child("World", true, false) as World

    _ensure_ui()
    _connect_signals()
    call_deferred("_late_wire")

func _late_wire() -> void:
    if world and not world.world_updated.is_connected(Callable(self, "_rebuild")):
        world.world_updated.connect(_rebuild)
    _rebuild()

# --- UI 構築 ---
func _ensure_ui() -> void:
    panel = get_node_or_null("Back") as PanelContainer
    if panel == null:
        panel = PanelContainer.new()
        panel.name = "Back"
        # サブウィンドウ風: 左上基準＋初期位置は中央付近
        panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
        panel.size = Vector2i(440, 240)
        add_child(panel)

        var vp := get_viewport_rect().size
        # 初期位置を画面の左寄り(25%)・やや上(22%)に
        var px := int(vp.x * 0.25 - panel.size.x * 0.5)
        var py := int(vp.y * 0.22 - panel.size.y * 0.8)
        panel.position = Vector2i(max(12, px), max(12, py))

        # 枠見た目
        var sb := StyleBoxFlat.new()
        sb.bg_color = Color(0.18, 0.18, 0.18, 1.0)
        sb.border_color = Color(0.35, 0.35, 0.35, 1.0)
        sb.border_width_left = 2
        sb.border_width_top = 2
        sb.border_width_right = 2
        sb.border_width_bottom = 2
        panel.add_theme_stylebox_override("panel", sb)

    # ルート VBox（タイトルバー + コンテンツ）
    var frame := panel.get_node_or_null("Frame") as VBoxContainer
    if frame == null:
        frame = VBoxContainer.new()
        frame.name = "Frame"
        panel.add_child(frame)

    # タイトルバー
    title_bar = frame.get_node_or_null("TitleBar") as HBoxContainer
    if title_bar == null:
        title_bar = HBoxContainer.new()
        title_bar.name = "TitleBar"
        title_bar.mouse_filter = Control.MOUSE_FILTER_PASS
        frame.add_child(title_bar)

        var title := Label.new()
        title.text = "Menu"
        title.add_theme_font_size_override("font_size", 16)
        title_bar.add_child(title)

        var spacer := Control.new(); spacer.name = "Spacer"; spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        title_bar.add_child(spacer)

        close_btn = Button.new(); close_btn.name = "CloseX"; close_btn.text = "X"; close_btn.focus_mode = Control.FOCUS_NONE
        title_bar.add_child(close_btn)
        # タイトルバーでドラッグ
        title_bar.gui_input.connect(_on_title_gui_input)
    else:
        close_btn = title_bar.get_node_or_null("CloseX") as Button

    # コンテンツ部分（余白つき）
    var margin := frame.get_node_or_null("Margin") as MarginContainer
    if margin == null:
        margin = MarginContainer.new(); margin.name = "Margin"
        margin.add_theme_constant_override("margin_left", 12)
        margin.add_theme_constant_override("margin_right", 12)
        margin.add_theme_constant_override("margin_top", 8)
        margin.add_theme_constant_override("margin_bottom", 12)
        frame.add_child(margin)

    var vb := margin.get_node_or_null("VBox") as VBoxContainer
    if vb == null:
        vb = VBoxContainer.new(); vb.name = "VBox"; margin.add_child(vb)

    var row := vb.get_node_or_null("Row") as HBoxContainer
    if row == null:
        row = HBoxContainer.new(); row.name = "Row"; vb.add_child(row)

    # --- Buttons ---
    trade_btn = row.get_node_or_null("TradeBtn") as Button
    if trade_btn == null:
        trade_btn = Button.new(); trade_btn.name = "TradeBtn"; trade_btn.text = "Trade"; row.add_child(trade_btn)
    map_btn = row.get_node_or_null("MapBtn") as Button
    if map_btn == null:
        map_btn = Button.new(); map_btn.name = "MapBtn"; map_btn.text = "Map"; row.add_child(map_btn)
    step_btn = row.get_node_or_null("StepBtn") as Button
    if step_btn == null:
        step_btn = Button.new(); step_btn.name = "StepBtn"; step_btn.text = "+1 Day"; row.add_child(step_btn)
    move_btn = row.get_node_or_null("MoveBtn") as Button
    if move_btn == null:
        move_btn = Button.new(); move_btn.name = "MoveBtn"; move_btn.text = "Move"; row.add_child(move_btn)
    inv_btn = row.get_node_or_null("InvBtn") as Button
    if inv_btn == null:
        inv_btn = Button.new(); inv_btn.name = "InvBtn"; inv_btn.text = "Inv"; row.add_child(inv_btn)

    # --- Info Area ---
    var sep := vb.get_node_or_null("HSeparator") as HSeparator
    if sep == null:
        sep = HSeparator.new(); sep.name = "HSeparator"; vb.add_child(sep)

    var info := vb.get_node_or_null("Info") as VBoxContainer
    if info == null:
        info = VBoxContainer.new(); info.name = "Info"; vb.add_child(info)

    info_day = info.get_node_or_null("Day") as Label
    if info_day == null:
        info_day = _add_info_line(info, "日付", "Day")
    info_city = info.get_node_or_null("City") as Label
    if info_city == null:
        info_city = _add_info_line(info, "現在地", "City")
    info_cash = info.get_node_or_null("Cash") as Label
    if info_cash == null:
        info_cash = _add_info_line(info, "所持金", "Cash")
    info_cargo = info.get_node_or_null("Cargo") as Label
    if info_cargo == null:
        info_cargo = _add_info_line(info, "積載", "Cargo")

func _add_info_line(parent: VBoxContainer, title: String, name: String) -> Label:
    var row := HBoxContainer.new()
    var l := Label.new(); l.text = title; l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    var v := Label.new(); v.name = name
    row.add_child(l); row.add_child(v); parent.add_child(row)
    return v

func _connect_signals() -> void:
    if close_btn and not close_btn.pressed.is_connected(Callable(self, "_on_close")):
        close_btn.pressed.connect(_on_close)
    if trade_btn and not trade_btn.pressed.is_connected(Callable(self, "_on_trade")):
        trade_btn.pressed.connect(_on_trade)
    if map_btn and not map_btn.pressed.is_connected(Callable(self, "_on_map")):
        map_btn.pressed.connect(_on_map)
    if step_btn and not step_btn.pressed.is_connected(Callable(self, "_on_step")):
        step_btn.pressed.connect(_on_step)
    if move_btn and not move_btn.pressed.is_connected(Callable(self, "_on_move")):
        move_btn.pressed.connect(_on_move)
    if inv_btn and not inv_btn.pressed.is_connected(Callable(self, "_on_inv")):
        inv_btn.pressed.connect(_on_inv)

# --- Info 更新 ---
func _rebuild() -> void:
    if world == null:
        return
    info_day.text = _format_date()
    var cid := String(world.player.get("city", ""))
    var moving := bool(world.player.get("enroute", false))
    if moving:
        var dest := String(world.player.get("dest", ""))
        info_city.text = "%s → %s" % [_city_name(cid), _city_name(dest)]
    else:
        info_city.text = _city_name(cid)
    info_cash.text = "%.1f" % float(world.player.get("cash", 0.0))
    var used := 0
    if world.has_method("_cargo_used"):
        used = int(world.call("_cargo_used", world.player))
    var cap := int(world.player.get("cap", 0))
    info_cargo.text = "%d / %d" % [used, cap]

func _city_name(cid: String) -> String:
    return String(world.cities[cid]["name"]) if world and world.cities.has(cid) else cid

# --- 日付フォーマット（Y/M/D） ---
func _format_date() -> String:
    if world == null:
        return ""
    if world.has_method("format_date"):
        return String(world.call("format_date"))
    var d: int = int(world.day)
    var days_per_month := 30
    var months_per_year := 12
    var days_per_year := days_per_month * months_per_year
    var y := (d / days_per_year) + 1
    var m := ((d % days_per_year) / days_per_month) + 1
    var dm := (d % days_per_month) + 1
    return "%d年%02d月%02d日" % [y, m, dm]

# --- Buttons ---
func _on_trade() -> void:
    if hud and hud.has_method("_on_trade_btn"):
        hud.call("_on_trade_btn")

func _on_map() -> void:
    if hud and hud.has_method("_on_map_btn"):
        hud.call("_on_map_btn")

func _on_step() -> void:
    if world == null:
        return
    if world.is_paused():
        world.step_one_day()
    else:
        world.pause()
        world.step_one_day()

func _on_move() -> void:
    if hud and hud.has_method("_open_move_window"):
        hud.call("_open_move_window")

func _on_inv() -> void:
    if hud and hud.has_method("_open_inventory_window"):
        hud.call("_open_inventory_window")

func _on_close() -> void:
    visible = false

# --- タイトルバーのドラッグ処理 ---
func _on_title_gui_input(ev: InputEvent) -> void:
    if ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_LEFT:
        if ev.pressed:
            _dragging = true
            _drag_start = (ev as InputEventMouseButton).global_position
            _panel_start = panel.global_position
            accept_event()
        else:
            _dragging = false
    elif ev is InputEventMouseMotion and _dragging:
        var delta := (ev as InputEventMouseMotion).global_position - _drag_start
        panel.global_position = _panel_start + delta
