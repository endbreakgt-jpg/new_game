extends Control
@export var show_decay_dialog := true  # 劣化で手持ちが0になった時にダイアログ表示

@export var world_path: NodePath

var world: World

@export var show_supply_toast: bool = false
@export var supply_toast_seconds: float = 3.0
@export var show_supply_dialog: bool = true  # 将来: 情報収集などの条件でダイアログ表示に切替
@export var show_event_log_panel: bool = true   # ★ HUD右下のイベントログ欄を表示
@export var event_log_rows: int = 6             # ★ 表示行数（最新から）

# Runtime-only UIs (ツリーにプリセット不要)
var menu_win: Node = null            # res://ui/menu_panel.gd（通常 Control）
var trade_win: Node = null           # res://ui/trade_window.gd（Control もしくは Window）
var map_window: Window = null        # Map用サブウィンドウ
var move_window: Window = null       # Move用サブウィンドウ
var inventory_window: Window = null  # Inventory用サブウィンドウ
var debug_panel: DebugPanel = null
var debug_window: Window = null     # ← デバッグ専用サブウィンドウ

var _toast_layer: VBoxContainer = null  # 右上トースト用レイヤ
var _active_toasts: int = 0  # 表示中トースト数（>0 で自動停止）

var _user_paused: bool = true
var _popup_paused: bool = false
var play_btn: Button = null
var debug_btn: Button = null


@export var debug_embed: bool = true
@export var debug_open_on_start: bool = true
# ★ 追加：簡易ステータス／イベントログ
var _supply_label: Label = null
var _event_panel: PanelContainer = null
var _event_text: RichTextLabel = null


@onready var topbar: HBoxContainer = $Margin/VBox/TopBar
@onready var day_label: Label = $Margin/VBox/TopBar/DayLabel
@onready var city_label: Label = $Margin/VBox/TopBar/CityLabel
@onready var cash_label: Label = $Margin/VBox/TopBar/CashLabel
@onready var menu_btn: Button = $Margin/VBox/TopBar/MenuBtn
@onready var map_btn: Button  = $Margin/VBox/TopBar/MapBtn
@onready var trade_btn: Button = $Margin/VBox/TopBar/TradeBtn
#@onready var debug_btn: Button = $Margin/VBox/TopBar/DebugBtn

func _ready() -> void:
    _apply_full_rect(self)
    _apply_full_rect($Margin)
    _apply_full_rect($Margin/VBox)

    var m := $Margin as MarginContainer
    if m:
        m.add_theme_constant_override("margin_left", 16)
        m.add_theme_constant_override("margin_right", 16)
        m.add_theme_constant_override("margin_top", 8)
        m.add_theme_constant_override("margin_bottom", 8)

    topbar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    topbar.custom_minimum_size = Vector2(0, 44)
    topbar.mouse_filter = Control.MOUSE_FILTER_PASS

    if day_label:
        day_label.custom_minimum_size = Vector2(150, 0)
    for b in [menu_btn, map_btn, trade_btn]:
        b.mouse_filter = Control.MOUSE_FILTER_STOP
        b.custom_minimum_size = Vector2(90, 32)
        b.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
        b.disabled = false
        b.visible = true # インデント修正
    _ensure_spacer_before_buttons()

    _create_play_button()
    _create_debug_button()
    _create_supply_label()     # ★ 追加：当日供給数/今月累計の小さなピル
    _update_play_button()

    # World 取得
    world = (get_node_or_null(world_path) as World) if world_path != NodePath("") else (get_parent() as World)
    if world:
        world.day_advanced.connect(_on_day)
        world.world_updated.connect(_refresh)
        if not world.world_updated.is_connected(Callable(self, "_on_world_updated_debug")):
            world.world_updated.connect(_on_world_updated_debug)
        if world.has_signal("supply_event"):
            world.supply_event.connect(_on_supply_event)

    if world.has_signal("player_decay_event"):
        world.player_decay_event.connect(_on_player_decay_event)

    _wire_buttons()
    _ensure_ui_cancel()
    _ensure_debug_toggle()
    _ensure_toast_layer()
    _ensure_event_log_panel()  # ★ 追加：HUD右下のログ欄（非ポップアップ）
    _refresh()
    call_deferred("_place_popups")
    get_tree().root.size_changed.connect(_place_popups)
    if debug_open_on_start:
        _spawn_debug_if_needed()
        if debug_embed and is_instance_valid(debug_panel):
            debug_panel.visible = true
        elif is_instance_valid(debug_window):
            debug_window.popup_centered()
            debug_window.grab_focus()
        set_process_input(true)
    set_process_unhandled_input(true)

# ---- layout helpers ----
func _apply_full_rect(c: Control) -> void:
    # 複数行に修正
    c.anchor_left = 0
    c.anchor_top = 0
    c.anchor_right = 1
    c.anchor_bottom = 1
    c.offset_left = 0
    c.offset_top = 0
    c.offset_right = 0
    c.offset_bottom = 0

func _ensure_spacer_before_buttons() -> void:
    if not is_instance_valid(topbar):
        return
    var spacer: Control = topbar.get_node_or_null("Spacer") as Control
    if spacer == null:
        spacer = Control.new()
        spacer.name = "Spacer"
        spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        topbar.add_child(spacer)
    var min_btn_idx: int = 999999
    for b in [menu_btn, map_btn, trade_btn]:
        if b and b.get_parent() == topbar:
            min_btn_idx = min(min_btn_idx, b.get_index())
    if min_btn_idx != 999999:
        topbar.move_child(spacer, min_btn_idx)

func _create_play_button() -> void:
    if not is_instance_valid(topbar):
        return
    var existing := topbar.get_node_or_null("PlayBtn")
    if existing:
        play_btn = existing as Button
    else:
        play_btn = Button.new()
        play_btn.name = "PlayBtn"
        play_btn.text = "Play"
        play_btn.custom_minimum_size = Vector2(90, 32)
        play_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
        play_btn.mouse_filter = Control.MOUSE_FILTER_STOP
        topbar.add_child(play_btn)
        if menu_btn and play_btn.get_parent() == topbar:
            topbar.move_child(play_btn, menu_btn.get_index())
    if play_btn and not play_btn.pressed.is_connected(Callable(self, "_on_play_pause_btn")):
        play_btn.pressed.connect(_on_play_pause_btn)

func _create_debug_button() -> void:
    if not is_instance_valid(topbar):
        return
    var existing := topbar.get_node_or_null("DebugBtn")
    if existing:
        debug_btn = existing as Button
    else:
        debug_btn = Button.new()
        debug_btn.name = "DebugBtn"
        debug_btn.text = "Debug"
        debug_btn.custom_minimum_size = Vector2(84, 32)
        debug_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
        debug_btn.mouse_filter = Control.MOUSE_FILTER_STOP
        topbar.add_child(debug_btn)
        if play_btn and debug_btn.get_parent() == topbar:
            topbar.move_child(debug_btn, play_btn.get_index() + 1)
    if debug_btn and not debug_btn.pressed.is_connected(Callable(self, "_on_debug_btn")):
        debug_btn.pressed.connect(_on_debug_btn)

func _create_supply_label() -> void:
    if not is_instance_valid(topbar):
        return
    if _supply_label and is_instance_valid(_supply_label):
        return
    _supply_label = Label.new()
    _supply_label.name = "SupplyPill"
    _supply_label.text = "Sup: -/-"
    _supply_label.custom_minimum_size = Vector2(120, 0)
    _supply_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
    _supply_label.add_theme_font_size_override("font_size", 12)
    topbar.add_child(_supply_label)
    if cash_label and _supply_label.get_parent() == topbar:
        topbar.move_child(_supply_label, cash_label.get_index() + 1)

func _update_supply_label() -> void:
    if world == null or _supply_label == null:
        return
    var today: int = int(world.supply_count_today) if "supply_count_today" in world else 0
    var month_total: int = 0
    if "supply_count_by_month" in world and world.has_method("get_calendar"):
        var cal := world.get_calendar()
        var key := "%04d-%02d" % [int(cal.get("year", 1)), int(cal.get("month", 1))]
        month_total = int(world.supply_count_by_month.get(key, 0))
    _supply_label.text = "Sup: %d/%d" % [today, month_total]

func _update_play_button() -> void:
    if play_btn and world:
        play_btn.text = "Play" if world.is_paused() else "Pause"

# ---- state / refresh ----
func _on_play_pause_btn() -> void:
    if world == null: return
    if world.is_paused():
        _user_paused = false
        world.resume()
    else:
        _user_paused = true
        world.pause()
    _update_play_button()

func _on_day(_d: int) -> void:
    _refresh()

func _refresh() -> void:
    if world == null: return
    day_label.text = (world.format_date() if world and world.has_method("format_date") else "Day %d" % world.day)
    var cid: String = String(world.player.get("city", ""))
    var moving := bool(world.player.get("enroute", false))
    if moving:
        var dest := String(world.player.get("dest", ""))
        city_label.text = "%s → %s" % [_city_name(cid), _city_name(dest)]
    else:
        city_label.text = _city_name(cid)
    cash_label.text = "Cash: %.1f" % float(world.player.get("cash", 0.0))
    _update_play_button()
    _update_supply_label()    # ★ 追加
    _refresh_event_log()      # ★ 追加

func _city_name(cid: String) -> String:
    return String(world.cities[cid]["name"]) if world and world.cities.has(cid) else cid

# ---- placement ----
func _place_popups() -> void:
    var vp := get_viewport_rect()
    if trade_win:
        var x := vp.size.x
        var y := vp.size.y
        if trade_win is Control:
            var c := trade_win as Control
            c.position = Vector2(x * 0.56, y * 0.08)
            c.size     = Vector2(x * 0.40, y * 0.48)
    if menu_win:
        var x2 := vp.size.x
        var y2 := vp.size.y
        if menu_win is Control:
            var c2 := menu_win as Control
            c2.position = Vector2(x2 * 0.18, y2 * 0.52)
            c2.size     = Vector2(x2 * 0.32, y2 * 0.34)

# ---- wiring ----
func _wire_buttons() -> void:
    if menu_btn and not menu_btn.pressed.is_connected(Callable(self, "_on_menu_btn")):
        menu_btn.pressed.connect(_on_menu_btn)
    if map_btn and not map_btn.pressed.is_connected(Callable(self, "_on_map_btn")):
        map_btn.pressed.connect(_on_map_btn)
    if trade_btn and not trade_btn.pressed.is_connected(Callable(self, "_on_trade_btn")):
        trade_btn.pressed.connect(_on_trade_btn)
    if play_btn and not play_btn.pressed.is_connected(Callable(self, "_on_play_pause_btn")):
        play_btn.pressed.connect(_on_play_pause_btn)
    if debug_btn and not debug_btn.pressed.is_connected(Callable(self, "_on_debug_btn")):
        debug_btn.pressed.connect(_on_debug_btn)

# ---- open/toggle ----
func _on_menu_btn() -> void:
    _spawn_menu_if_needed()
    if menu_win: _place_popups()
    _toggle_popup(menu_win)

func _on_trade_btn() -> void:
    _spawn_trade_if_needed()
    if trade_win: _place_popups()
    _toggle_popup(trade_win)

func _on_map_btn() -> void:
    _open_map_popup()

func _on_debug_btn() -> void:
    _spawn_debug_if_needed()
    
    if debug_embed:
        if is_instance_valid(debug_panel):
            debug_panel.visible = not debug_panel.visible
            
            if debug_panel.visible and debug_panel.has_method("_update_stats"):
                debug_panel.call("_update_stats")
        
            _on_popup_visibility_changed()
            
        return
        
    # debug_embed が false の場合の処理は、if debug_embed: ブロックの
    # 閉じ括弧と return の後にインデントをリセットして記述する必要があります。
    if is_instance_valid(debug_window):
        if debug_window.visible:
            debug_window.hide()
        else:
            debug_window.popup_centered()
            debug_window.grab_focus()
            
            if is_instance_valid(debug_panel) and debug_panel.has_method("_update_stats"):
                debug_panel.call("_update_stats")

func _toggle_popup(win: Node) -> void:
    if win == null: return
    if win is Window:
        var w := win as Window
        if w.visible:
            if win == trade_win and trade_win and trade_win.has_method("reset_to_menu"):
                trade_win.call("reset_to_menu")
            w.hide()
        else:
            if win == trade_win and trade_win and trade_win.has_method("reset_to_menu"):
                trade_win.call("reset_to_menu")
            
            w.show()
            w.popup_centered()
            w.grab_focus()
    elif win is Control:
        var c := win as Control
        c.visible = not c.visible
        if c.visible: c.grab_focus()
    _on_popup_visibility_changed()

func _any_popup_visible() -> bool:
    var a := trade_win != null and bool(trade_win.get("visible"))
    var b := menu_win  != null and bool(menu_win.get("visible"))
    var c := is_instance_valid(map_window) and map_window.visible
    var d := is_instance_valid(move_window) and move_window.visible
    var e := is_instance_valid(inventory_window) and inventory_window.visible
    return a or b or c or d or e

func _on_popup_visibility_changed() -> void:
    _sync_pause_state()

# ---- input (ESC / F3 で操作) ----
func _input(event: InputEvent) -> void:
    _handle_esc_event(event)
    if event.is_action_pressed("toggle_debug"):
        _on_debug_btn()

func _unhandled_input(event: InputEvent) -> void:
    _handle_esc_event(event)
    if event.is_action_pressed("toggle_debug"):
        _on_debug_btn()

func _handle_esc_event(event: InputEvent) -> void:
    if event.is_action_pressed("ui_cancel"):
        var closed := false
        if is_instance_valid(map_window) and map_window.visible:
            map_window.hide()
            closed = true
        if is_instance_valid(move_window) and move_window.visible:
            move_window.hide()
            closed = true
        if is_instance_valid(inventory_window) and inventory_window.visible:
            inventory_window.hide()
            closed = true
        if trade_win != null and bool(trade_win.get("visible")):
            if trade_win.has_method("reset_to_menu"):
                trade_win.call("reset_to_menu")
            if trade_win.has_method("hide"):
                trade_win.call("hide")
            else:
                trade_win.set("visible", false)
            closed = true
        if menu_win != null and bool(menu_win.get("visible")):
            if menu_win.has_method("hide"):
                menu_win.call("hide")
            else:
                menu_win.set("visible", false)
            closed = true
        if is_instance_valid(debug_window) and debug_window.visible:
            debug_window.hide()
            closed = true

        if closed:
            get_viewport().set_input_as_handled()
            _on_popup_visibility_changed()

# --- 修正した _spawn_debug_if_needed ---
func _spawn_debug_if_needed() -> void:
    # ----------------------------------------------------------------------
    # 埋め込みパネルのフロー (debug_embed: true)
    # ----------------------------------------------------------------------
    if debug_embed:
        # Embed DebugPanel directly into HUD
        if not is_instance_valid(debug_panel):
            var found: Node = null
            if world:
                # DebugPanelをWorldから探す
                found = world.get_node_or_null("DebugPanel")
            
            if found and found is DebugPanel:
                # (1) 既存のパネルを移設
                debug_panel = found as DebugPanel
                if debug_panel.get_parent():
                    debug_panel.get_parent().remove_child(debug_panel)
            else:
                # (2) 新しいパネルを生成
                var DebugPanelScript: Script = preload("res://ui/debug_panel.gd")
                debug_panel = DebugPanelScript.new()

            # パネルを現在のノードに追加し、worldを紐付け
            if is_instance_valid(debug_panel):
                if world:
                    debug_panel.world = world
                # この関数を持つノード（HUD）の子として追加
                add_child(debug_panel)
                
                # パネルの初期化とシグナル接続（_init_debug_panel_after_ready）
                if debug_panel.is_node_ready():
                    _init_debug_panel_after_ready()
                else:
                    # readyシグナルに接続
                    debug_panel.ready.connect(_init_debug_panel_after_ready)
            
        # Layout for embedded panel (top-left, fixed size)
        if is_instance_valid(debug_panel):
            debug_panel.name = "DebugPanel"
            debug_panel.visible = false  # toggled by button / auto-open
            debug_panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
            debug_panel.position = Vector2(16, 72)
            
            # custom_minimum_size を設定
            if debug_panel.has_method("set"):
                debug_panel.set("custom_minimum_size", Vector2(460, 420))
                
            return  # 埋め込みモードの場合、ここで関数を終了
        
    # ----------------------------------------------------------------------
    # ウィンドウ表示のフロー (debug_embed: false)
    # ----------------------------------------------------------------------
    
    # ウィンドウとパネルが両方とも存在する場合は早期リターン
    if is_instance_valid(debug_window) and is_instance_valid(debug_panel):
        return

    # 1) ウィンドウ生成 (Create window)
    if not is_instance_valid(debug_window):
        debug_window = Window.new()
        debug_window.name = "DebugWindow"
        debug_window.title = "Debug"
        debug_window.size = Vector2i(480, 420)
        debug_window.min_size = Vector2i(360, 300)
        # Godot 4: unresizable は存在しないため、resizable = true に修正
        debug_window.resizable = true

        var main := get_window()
        if main:
            main.add_child(debug_window)
        else:
            get_tree().root.add_child(debug_window)
            
        debug_window.close_requested.connect(func(): debug_window.hide())

    # 2) パネル生成または移設 (Panel reuse/creation)
    if not is_instance_valid(debug_panel):
        var found: Node = null
        if world:
            found = world.get_node_or_null("DebugPanel")
            
        if found and found is DebugPanel:
            # (1) 既存のパネルを移設
            debug_panel = found as DebugPanel
            if debug_panel.get_parent():
                debug_panel.get_parent().remove_child(debug_panel)
        else:
            # (2) 新しいパネルを生成
            var DebugPanelScript: Script = preload("res://ui/debug_panel.gd")
            debug_panel = DebugPanelScript.new()
            
        # パネルをウィンドウに追加し、レイアウトを設定
        if is_instance_valid(debug_panel):
            debug_window.add_child(debug_panel)
            
            # レイアウトをフルサイズに設定
            if debug_panel.has_method("set_anchors_preset"):
                debug_panel.call("set_anchors_preset", Control.PRESET_FULL_RECT)
                if debug_panel.has_method("set"):
                    debug_panel.set("offset_left", 0)
                    debug_panel.set("offset_top", 0)
                    debug_panel.set("offset_right", 0)
                    debug_panel.set("offset_bottom", 0)

    # 3) Worldの紐付けと初期化 (Wire world + init)
    if is_instance_valid(debug_panel) and world:
        debug_panel.world = world
        
    # 初期化メソッドの呼び出し
    if is_instance_valid(debug_panel):
        if debug_panel.has_method("_populate_options"):
            debug_panel.call("_populate_options")
        if debug_panel.has_method("_update_stats"):
            debug_panel.call("_update_stats")
    
func _open_map_popup() -> void:
    if is_instance_valid(map_window):
        map_window.popup_centered()
        map_window.grab_focus()
        return
    map_window = Window.new()
    map_window.name = "MapWindow"
    map_window.title = "Map"
    map_window.size = Vector2i(900, 520)
    map_window.min_size = Vector2i(640, 360)
    # Godot 4: unresizable は存在しないため、resizable = true に修正
    map_window.resizable = true
    var main := get_window()
    if main:
        main.add_child(map_window)
    else:
        get_tree().root.add_child(map_window)
    var MapLayer: Script = preload("res://scripts/map_layer.gd")
    var map: Node = MapLayer.new()
    map.name = "MapLayer"
    map.world = world
    map_window.add_child(map)
    if map.has_method("set_anchors_preset"):
        map.call("set_anchors_preset", Control.PRESET_FULL_RECT)
        if map.has_method("set"):
            map.set("offset_left", 0) # 複数行に修正
            map.set("offset_top", 0)
            map.set("offset_right", 0)
            map.set("offset_bottom", 0)
    if map.has_signal("city_picked"):
        var cb := Callable(self, "_on_map_city_picked")
        if not map.is_connected("city_picked", cb):
            map.connect("city_picked", cb)
    map_window.popup_centered()
    map_window.grab_focus()
    map_window.close_requested.connect(func():
        if is_instance_valid(map_window): map_window.queue_free()
        map_window = null
    )

# ---- dynamic spawn (Control) ----
func _spawn_menu_if_needed() -> void:
    if menu_win == null:
        var MenuPanelScript: Script = preload("res://ui/menu_panel.gd")
        var mp: Node = MenuPanelScript.new()
        mp.name = "MenuPanel"
        get_tree().root.add_child(mp)
        mp.visible = false
        if mp.has_method("set_anchors_preset"):
            mp.call("set_anchors_preset", Control.PRESET_TOP_LEFT)
        mp.world = world
        mp.hud = self
        menu_win = mp

func _spawn_trade_if_needed() -> void:
    if trade_win == null:
        var TradeWindow: Script = preload("res://ui/trade_window.gd")
        var tw: Window = TradeWindow.new()
        tw.name = "TradeWindow"
        tw.world = world
        var main := get_window()
        if main:
            main.add_child(tw)
        else:
            get_tree().root.add_child(tw)
        tw.hide()
        tw.close_requested.connect(func(): tw.hide())
        trade_win = tw

# ---- Move / Inventory ----
func _size_and_center_window(win: Window) -> void:
    var main: Window = get_window()
    var screen_size: Vector2i
    if is_instance_valid(main):
        screen_size = main.size
    else:
        screen_size = Vector2i(1280, 720)
    var target: Vector2i = Vector2i(int(screen_size.x * 0.85), int(screen_size.y * 0.85))
    win.size = target
    win.position = (screen_size - target) / 2

func _open_move_window() -> void:
    _open_map_popup()
    if not is_instance_valid(map_window):
        return
    var map := map_window.get_node_or_null("MapLayer")
    if map == null and map_window.get_child_count() > 0:
        map = map_window.get_child(0)
    if map and map.has_method("begin_pick_for_player"):
        map.call("begin_pick_for_player")
    map_window.popup_centered()
    map_window.grab_focus()

func _on_map_city_picked(cid: String) -> void:
    if world == null or not is_instance_valid(map_window):
        return
    var origin: String = String(world.player.get("city", ""))
    var days: int = world._route_days(origin, cid)
    var travel_cost: float = world.travel_cost_per_day * float(days)
    var toll: float = 0.0
    if world.pay_toll_on_depart:
        toll = float(world._route_toll(origin, cid))
    var total: float = travel_cost + toll
    var cash: float = float(world.player.get("cash", 0.0))
    var dest_name: String = cid
    var origin_name: String = origin
    if world.cities.has(cid):
        dest_name = String(world.cities[cid].get("name", cid))
    if world.cities.has(origin):
        origin_name = String(world.cities[origin].get("name", origin))

    var dlg := ConfirmationDialog.new()
    dlg.title = "移動の確認"
    var text: String = "次の都市へ移動しますか？\n"
    text += "%s → %s\n" % [origin_name, dest_name]
    text += "日数: %d\n" % days
    text += "旅費: %.1f\n" % travel_cost
    text += "通行料: %.1f\n" % toll
    text += "――――――――――\n"
    text += "合計: %.1f\n" % total
    text += "所持金: %.1f" % cash
    dlg.dialog_text = text

    map_window.add_child(dlg)
    if dlg.get_ok_button(): dlg.get_ok_button().text = "移動する"
    if dlg.get_cancel_button(): dlg.get_cancel_button().text = "やめる"

    dlg.confirmed.connect(func():
        var dest_id := String(cid)
        var res := world.can_player_move_to(dest_id)
        if bool(res.get("ok", false)) and world.player_move(dest_id):
            var map := map_window.get_node_or_null("MapLayer")
            if map and map.has_method("end_pick"):
                map.call("end_pick")
            _refresh()
        else:
            var msg := ""
            var need := float(res.get("need", 0.0))
            var cash_now := float(world.player.get("cash", 0.0))
            match int(res.get("err", -1)):
                World.MoveErr.ARRIVED_TODAY:
                    msg = "本日は到着日のため出発できません。\n翌日以降にもう一度お試しください。"
                World.MoveErr.NOT_ADJACENT:
                    msg = "その都市は隣接していません。"
                World.MoveErr.LACK_CASH:
                    msg = "資金が不足しています。\n必要: %.1f / 所持: %.1f" % [need, cash_now]
                _:
                    msg = "出発できませんでした。"
            var err := AcceptDialog.new()
            err.title = "移動できません"
            err.dialog_text = msg
            map_window.add_child(err)
            err.popup_centered()
    )
    dlg.popup_centered()
    _sync_pause_state()
    dlg.confirmed.connect(_sync_pause_state)
    dlg.canceled.connect(_sync_pause_state)
    dlg.close_requested.connect(_sync_pause_state)
    dlg.grab_focus()

func _open_inventory_window() -> void:
    if is_instance_valid(inventory_window):
        _size_and_center_window(inventory_window)
        inventory_window.show()
        inventory_window.grab_focus()
        return
    var InvWin: Script = preload("res://ui/inventory_window.gd")
    inventory_window = InvWin.new()
    inventory_window.name = "InventoryWindow"
    inventory_window.title = "Inventory"
    inventory_window.resizable = true # 修正: unresizable -> resizable
    if inventory_window.has_method("set"):
        inventory_window.set("world", world)
    var main := get_window()
    if main:
        main.add_child(inventory_window)
    else:
        get_tree().root.add_child(inventory_window)
    _size_and_center_window(inventory_window)
    inventory_window.show()
    inventory_window.grab_focus()
    inventory_window.close_requested.connect(func():
        if is_instance_valid(inventory_window):
            inventory_window.queue_free()
        inventory_window = null
    )

# --- Supply toasts & event bridge ---
func _ensure_toast_layer() -> void:
    if _toast_layer and is_instance_valid(_toast_layer):
        return
    var vc := VBoxContainer.new()
    vc.name = "ToastLayer"
    # 複数行に修正
    vc.anchor_left = 1.0
    vc.anchor_right = 1.0
    vc.anchor_top = 0.0
    vc.anchor_bottom = 0.0
    vc.offset_left = -360
    vc.offset_right = -16
    vc.offset_top = 16
    vc.offset_bottom = 0
    vc.size_flags_horizontal = Control.SIZE_SHRINK_END
    vc.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
    vc.grow_horizontal = Control.GROW_DIRECTION_BEGIN
    vc.z_index = 100
    add_child(vc)
    _toast_layer = vc

func _show_toast(msg: String, seconds: float = -1.0) -> void:
    if not show_supply_toast:
        return
    if not _toast_layer or not is_instance_valid(_toast_layer):
        _ensure_toast_layer()
    _active_toasts += 1
    _sync_pause_state()
    var panel := PanelContainer.new()
    panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
    panel.modulate = Color(1, 1, 1, 0)
    panel.size_flags_horizontal = Control.SIZE_SHRINK_END
    panel.size_flags_vertical = Control.SIZE_SHRINK_CENTER
    var sb := StyleBoxFlat.new()
    sb.bg_color = Color(0, 0, 0, 0.75)
    sb.corner_radius_top_left = 8
    sb.corner_radius_top_right = 8
    sb.corner_radius_bottom_left = 8
    sb.corner_radius_bottom_right = 8
    panel.add_theme_stylebox_override("panel", sb)
    var margin := MarginContainer.new()
    margin.add_theme_constant_override("margin_left", 12)
    margin.add_theme_constant_override("margin_right", 12)
    margin.add_theme_constant_override("margin_top", 8)
    margin.add_theme_constant_override("margin_bottom", 8)
    var label := Label.new()
    label.text = msg
    label.autowrap_mode = TextServer.AUTOWRAP_WORD
    label.add_theme_color_override("font_color", Color(1, 1, 1))
    label.custom_minimum_size = Vector2(280, 0)
    margin.add_child(label)
    panel.add_child(margin)
    _toast_layer.add_child(panel)
    var dur := supply_toast_seconds if seconds <= 0.0 else seconds
    var tw := create_tween()
    tw.tween_property(panel, "modulate:a", 1.0, 0.20)
    tw.tween_interval(dur)
    tw.tween_property(panel, "modulate:a", 0.0, 0.35)
    tw.tween_callback(func():
        if is_instance_valid(panel):
            panel.queue_free()
        _active_toasts = max(0, _active_toasts - 1)
        _sync_pause_state()
    )

func _ensure_event_log_panel() -> void:
    if not show_event_log_panel:
        if _event_panel and is_instance_valid(_event_panel):
            _event_panel.visible = false
        return
    if _event_panel and is_instance_valid(_event_panel):
        _event_panel.visible = true
        _refresh_event_log()
        return
    # 右下に固定表示（ポーズに影響しない常駐パネル）
    var panel := PanelContainer.new()
    panel.name = "EventLogPanel"
    # 複数行に修正
    panel.anchor_left = 1.0
    panel.anchor_right = 1.0
    panel.anchor_top = 1.0
    panel.anchor_bottom = 1.0
    panel.offset_left = -360
    panel.offset_right = -16
    panel.offset_top = -220
    panel.offset_bottom = -16
    panel.size_flags_horizontal = Control.SIZE_SHRINK_END
    panel.size_flags_vertical = Control.SIZE_SHRINK_END
    var sb := StyleBoxFlat.new()
    sb.bg_color = Color(0, 0, 0, 0.60)
    sb.corner_radius_top_left = 8
    sb.corner_radius_top_right = 8
    sb.corner_radius_bottom_left = 8
    sb.corner_radius_bottom_right = 8
    panel.add_theme_stylebox_override("panel", sb)
    var margin := MarginContainer.new()
    margin.add_theme_constant_override("margin_left", 10)
    margin.add_theme_constant_override("margin_right", 10)
    margin.add_theme_constant_override("margin_top", 8)
    margin.add_theme_constant_override("margin_bottom", 8)
    panel.add_child(margin)
    var title := Label.new()
    title.text = "Events"
    title.add_theme_font_size_override("font_size", 12)
    margin.add_child(title)
    var txt := RichTextLabel.new()
    txt.bbcode_enabled = true
    txt.fit_content = true
    txt.scroll_active = true
    txt.custom_minimum_size = Vector2(300, 160)
    margin.add_child(txt)
    add_child(panel)
    _event_panel = panel
    _event_text = txt
    _refresh_event_log()

func _refresh_event_log() -> void:
    if not show_event_log_panel or _event_text == null:
        return
        
    var lines: Array[String] = []
    
    # world.event_log が存在し、イテレート可能であることを確認
    if world and "event_log" in world:
        for m in world.event_log:
            var s := String(m)
            if world.has_method("humanize_ids"):
                s = world.humanize_ids(s)
            lines.append(s)
            
    # 末尾（最新）から event_log_rows 件を表示
    var out: String = ""
    
    # 型推論エラー回避のため int 型を明示
    var n: int = min(event_log_rows, lines.size())
    
    for i in range(n):
        var idx: int = lines.size() - 1 - i
        out += "• %s\n" % lines[idx]
        
    _event_text.text = out

func _on_supply_event(cid: String, pid: String, qty: int, mode: String, flavor: String) -> void:
    if show_supply_dialog:
        var dlg := AcceptDialog.new()
        dlg.title = "市場の噂"
        var _txt := flavor
        if world and world.has_method("humanize_ids"):
            _txt = world.humanize_ids(flavor)
        dlg.dialog_text = _txt
        add_child(dlg)
        dlg.popup_centered()
        _sync_pause_state()
        dlg.confirmed.connect(func():
            if is_instance_valid(dlg):
                dlg.hide()
                dlg.queue_free()
            call_deferred("_sync_pause_state")
        )
        dlg.close_requested.connect(func():
            if is_instance_valid(dlg):
                dlg.hide()
                dlg.queue_free()
            call_deferred("_sync_pause_state")
        )
        dlg.visibility_changed.connect(func():
            call_deferred("_sync_pause_state")
        )
        dlg.grab_focus()
    else:
        _show_toast(flavor)
    _refresh_event_log()  # ★ イベントログを即時更新

# --- Pause/resume unifier ---
func _any_supply_dialog_visible() -> bool:
    for c in get_children():
        if c is AcceptDialog and (c as AcceptDialog).visible:
            return true
    var root := get_tree().root
    if root:
        for n in root.get_children():
            if n is AcceptDialog and (n as AcceptDialog).visible:
                return true
    return false

func _sync_pause_state() -> void:
    if world == null:
        return
    var any := _any_popup_visible() or _any_supply_dialog_visible()
    if any:
        _popup_paused = true
        world.pause()
    else:
        _popup_paused = false
        if _user_paused:
            world.pause()
        else:
            world.resume()
    _update_play_button()

# --- InputMap の保証（Esc / F3） ---
func _ensure_ui_cancel() -> void:
    if not InputMap.has_action("ui_cancel"):
        InputMap.add_action("ui_cancel")
        var ev := InputEventKey.new()
        ev.physical_keycode = KEY_ESCAPE
        InputMap.action_add_event("ui_cancel", ev)

func _ensure_debug_toggle() -> void:
    if not InputMap.has_action("toggle_debug"):
        InputMap.add_action("toggle_debug")
        var ev := InputEventKey.new()
        ev.physical_keycode = KEY_F3
        InputMap.action_add_event("toggle_debug", ev)

func _on_player_decay_event(pid: String, lost_qty: int, flavor: String) -> void:
    if not show_decay_dialog:
        return
    var dlg := AcceptDialog.new()
    dlg.title = "劣化のお知らせ"
    var _txt := flavor
    if world and world.has_method("humanize_ids"):
        _txt = world.humanize_ids(flavor)
        dlg.dialog_text = _txt
    add_child(dlg)
    dlg.popup_centered()
    _sync_pause_state()
    dlg.confirmed.connect(func():
        if is_instance_valid(dlg):
            dlg.hide()
            dlg.queue_free()
        call_deferred("_sync_pause_state")
    )
    dlg.close_requested.connect(func():
        if is_instance_valid(dlg):
            dlg.hide()
            dlg.queue_free()
        call_deferred("_sync_pause_state")
    )

# --- DebugPanel helpers ---
func _find_debug_panel() -> void:
    if is_instance_valid(debug_panel):
        return
    # 1) 兄弟 or 子に居る場合
    var local := get_node_or_null("../DebugPanel")
    if local and local is DebugPanel:
        debug_panel = local as DebugPanel
        return
    var child := get_node_or_null("DebugPanel")
    if child and child is DebugPanel:
        debug_panel = child as DebugPanel
        return
    # 2) シーンツリー上を探索
    var found := get_tree().root.find_child("DebugPanel", true, false)
    if found and found is DebugPanel:
        debug_panel = found as DebugPanel

func _on_world_updated_debug() -> void:
    _find_debug_panel()
    if debug_panel and debug_panel.visible and debug_panel.has_method("_update_stats"):
        debug_panel.call("_update_stats")


func _init_debug_panel_after_ready() -> void:
    if debug_panel and world:
        debug_panel.world = world
        if debug_panel.has_method("_populate_options"):
            debug_panel.call("_populate_options")
        if debug_panel.has_method("_update_stats"):
            debug_panel.call("_update_stats")
