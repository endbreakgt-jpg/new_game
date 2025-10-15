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
var save_btn: Button
var save_menu: PanelContainer
var inv_btn: Button
var info_day: Label
var info_city: Label
var info_cash: Label
var info_cargo: Label

var dlg_save_confirm: ConfirmationDialog
var dlg_load_confirm: ConfirmationDialog
var dlg_info: AcceptDialog
var _pending_slot: int = 0


# ドラッグ用
var _dragging := false
var _drag_start := Vector2.ZERO
var _panel_start := Vector2.ZERO

func _ready() -> void:
    # World 取得の試み
    if world_path != NodePath(""):
        world = get_node_or_null(world_path) as World
    if world == null:
        # 見つからない場合は、ツリー全体を検索
        world = get_tree().root.find_child("World", true, false) as World

    _ensure_ui()
    _connect_signals()
    call_deferred("_late_wire")
    call_deferred("_ensure_dialogs")

func _late_wire() -> void:
    # Worldのシグナル接続は遅延実行
    if world and not world.world_updated.is_connected(Callable(self, "_rebuild")):
        world.world_updated.connect(_rebuild)
    _rebuild()

# --- UI 構築 ---

func _ensure_ui() -> void:
    # 1. Back Panel
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

    # 2. Frame (ルート VBox: タイトルバー + コンテンツ)
    var frame := panel.get_node_or_null("Frame") as VBoxContainer
    if frame == null:
        frame = VBoxContainer.new()
        frame.name = "Frame"
        panel.add_child(frame)
    
    _build_title_bar(frame)
    _build_content_area(frame)

    call_deferred("_ensure_save_ui")

func _build_title_bar(parent: VBoxContainer) -> void:
    # タイトルバー (HBoxContainer)
    title_bar = parent.get_node_or_null("TitleBar") as HBoxContainer
    if title_bar == null:
        title_bar = HBoxContainer.new()
        title_bar.name = "TitleBar"
        title_bar.mouse_filter = Control.MOUSE_FILTER_PASS
        parent.add_child(title_bar)

        var title := Label.new()
        title.text = "Menu"
        title.add_theme_font_size_override("font_size", 16)
        title_bar.add_child(title)

        var spacer := Control.new()
        spacer.name = "Spacer"; spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        title_bar.add_child(spacer)

        # Close ボタン
        close_btn = Button.new()
        close_btn.name = "CloseX"; close_btn.text = "X"; close_btn.focus_mode = Control.FOCUS_NONE
        title_bar.add_child(close_btn)
        
        # Save/Load ボタンをここで生成 (TitleBar内に追加)
        save_btn = Button.new()
        save_btn.name = "SaveBtn"; save_btn.text = "Save/Load"
        title_bar.add_child(save_btn)

        # タイトルバーでドラッグ
        title_bar.gui_input.connect(_on_title_gui_input)
    else:
        close_btn = title_bar.get_node_or_null("CloseX") as Button
        save_btn = title_bar.get_node_or_null("SaveBtn") as Button

func _build_content_area(parent: VBoxContainer) -> void:
    # コンテンツ部分（余白つき）
    var margin := parent.get_node_or_null("Margin") as MarginContainer
    if margin == null:
        margin = MarginContainer.new()
        margin.name = "Margin"
        margin.add_theme_constant_override("margin_left", 12)
        margin.add_theme_constant_override("margin_right", 12)
        margin.add_theme_constant_override("margin_top", 8)
        margin.add_theme_constant_override("margin_bottom", 12)
        parent.add_child(margin)

    var vb := margin.get_node_or_null("VBox") as VBoxContainer
    if vb == null:
        vb = VBoxContainer.new()
        vb.name = "VBox"; margin.add_child(vb)

    var row := vb.get_node_or_null("Row") as HBoxContainer
    if row == null:
        row = HBoxContainer.new()
        row.name = "Row"; vb.add_child(row)

    # --- Buttons ---
    trade_btn = _ensure_button(row, "TradeBtn", "Trade")
    map_btn = _ensure_button(row, "MapBtn", "Map")
    step_btn = _ensure_button(row, "StepBtn", "+1 Day")
    move_btn = _ensure_button(row, "MoveBtn", "Move")
    inv_btn = _ensure_button(row, "InvBtn", "Inv")

    # --- Info Area ---
    var sep := vb.get_node_or_null("HSeparator") as HSeparator
    if sep == null:
        sep = HSeparator.new()
        sep.name = "HSeparator"; vb.add_child(sep)

    var info := vb.get_node_or_null("Info") as VBoxContainer
    if info == null:
        info = VBoxContainer.new()
        info.name = "Info"; vb.add_child(info)

    # Info Labels
    info_day = info.get_node_or_null("Day") as Label
    if info_day == null:
        info_day = _add_info_line(info, "日数", "Day")
    info_city = info.get_node_or_null("City") as Label
    if info_city == null:
        info_city = _add_info_line(info, "現在地", "City")
    info_cash = info.get_node_or_null("Cash") as Label
    if info_cash == null:
        info_cash = _add_info_line(info, "所持金", "Cash")
    info_cargo = info.get_node_or_null("Cargo") as Label
    if info_cargo == null:
        info_cargo = _add_info_line(info, "積載", "Cargo")

# ヘルパー関数: ボタン生成
func _ensure_button(parent: HBoxContainer, name: String, text: String) -> Button:
    var btn = parent.get_node_or_null(name) as Button
    if btn == null:
        btn = Button.new()
        btn.name = name
        btn.text = text
        parent.add_child(btn)
    return btn

# ヘルパー関数: 情報行生成
func _add_info_line(parent: VBoxContainer, title: String, name: String) -> Label:
    var row := HBoxContainer.new()
    var l := Label.new()
    l.text = title; l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    var v := Label.new()
    v.name = name
    row.add_child(l); row.add_child(v); parent.add_child(row)
    return v

func _ensure_save_ui() -> void:
    if panel == null: return
    
    # Save/LoadボタンがTitleBarに存在することを確認し、シグナル接続
    if save_btn and not save_btn.pressed.is_connected(Callable(self, "_on_save_menu")):
        save_btn.pressed.connect(_on_save_menu)

    # Save Menuの親ノードとしてFrame (VBoxContainer) を使用する
    var frame = panel.get_node_or_null("Frame") as VBoxContainer
    if frame == null: return

    save_menu = frame.get_node_or_null("SaveMenu") as PanelContainer
    if save_menu == null:
        save_menu = PanelContainer.new()
        save_menu.name = "SaveMenu"; save_menu.visible = false
        frame.add_child(save_menu)

        var sm_v := VBoxContainer.new()
        sm_v.name = "SBody"; save_menu.add_child(sm_v)
        
        var sm_title := Label.new()
        sm_title.text = "Save / Load"
        sm_title.add_theme_font_size_override("font_size", 14); sm_v.add_child(sm_title)

        for s in [1, 2]:
            var row_s := HBoxContainer.new()
            row_s.name = "Slot%d" % s; sm_v.add_child(row_s)
            
            var lab := Label.new()
            lab.name = "Label"; lab.text = "-"
            row_s.add_child(lab)
            
            var spacer_s := Control.new()
            spacer_s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
            row_s.add_child(spacer_s)
            
            var btn_save := Button.new()
            btn_save.name = "SaveBtn"; btn_save.text = "Save"
            row_s.add_child(btn_save)
            
            var btn_load := Button.new()
            btn_load.name = "LoadBtn"; btn_load.text = "Load"
            row_s.add_child(btn_load)
            
            btn_save.pressed.connect(Callable(self, "_on_save_slot").bind(s))
            btn_load.pressed.connect(Callable(self, "_on_load_slot").bind(s))


# --- Dialogs ---
func _ensure_dialogs() -> void:
    if dlg_save_confirm == null:
        dlg_save_confirm = ConfirmationDialog.new()
        dlg_save_confirm.name = "SaveConfirm"
        dlg_save_confirm.title = "確認"
        dlg_save_confirm.dialog_text = "セーブしますか？"
        add_child(dlg_save_confirm)
        dlg_save_confirm.confirmed.connect(func():
            if world and world.save_to_slot(_pending_slot):
                _refresh_save_menu()
                _show_info("セーブしました。")
        )
    if dlg_load_confirm == null:
        dlg_load_confirm = ConfirmationDialog.new()
        dlg_load_confirm.name = "LoadConfirm"
        dlg_load_confirm.title = "確認"
        dlg_load_confirm.dialog_text = "ロードしますか？"
        add_child(dlg_load_confirm)
        dlg_load_confirm.confirmed.connect(func():
            if world and world.load_from_slot(_pending_slot):
                _rebuild()
                _refresh_save_menu()
                _show_info("ロードしました。")
        )
    if dlg_info == null:
        dlg_info = AcceptDialog.new()
        dlg_info.name = "InfoDialog"
        dlg_info.title = "情報"
        add_child(dlg_info)

func _show_info(msg: String) -> void:
    if dlg_info == null:
        return
    dlg_info.dialog_text = msg
    dlg_info.popup_centered()
func _connect_signals() -> void:
    # シグナル接続
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
    info_day.text = str(world.day)
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


# --- Save/Load submenu logic ---
func _on_save_menu() -> void:
    if save_menu == null:
        return
    save_menu.visible = not save_menu.visible
    if save_menu.visible:
        _refresh_save_menu()

func _refresh_save_menu() -> void:
    if world == null or save_menu == null:
        return
    for s in [1, 2]:
        var row := save_menu.get_node("SBody/Slot%d" % s) as HBoxContainer
        var lab := row.get_node("Label") as Label
        var btn_load := row.get_node("LoadBtn") as Button
        # 修正箇所: 戻り値の型をDictionaryとして明示
        var meta := world.get_slot_summary(s) as Dictionary
        
        if meta.get("exists", false):
            var date := String(meta.get("date", "-"))
            var city := String(meta.get("city", ""))
            var cash := float(meta.get("cash", 0.0))
            lab.text = "Slot %d — %s  /  %s  /  %.1f" % [s, date, _city_name(city), cash]
            btn_load.disabled = false
        else:
            lab.text = "Slot %d — (Empty)" % s
            btn_load.disabled = true

func _on_save_slot(slot: int) -> void:
    _pending_slot = slot
    if dlg_save_confirm == null:
        _ensure_dialogs()
    dlg_save_confirm.popup_centered()

func _on_load_slot(slot: int) -> void:
    _pending_slot = slot
    if dlg_load_confirm == null:
        _ensure_dialogs()
    dlg_load_confirm.popup_centered()
