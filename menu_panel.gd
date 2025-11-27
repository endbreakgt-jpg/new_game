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
var step_turn_btn: Button
var move_btn: Button

var info_btn: Button
var trust_btn: Button

# 情報（噂）ウィンドウ
var rumor_win: Window = null
var rumor_list: VBoxContainer = null
var _rumors_current: Array = []

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

# 信用ウィンドウ
var trust_win: Window = null
var trust_list: VBoxContainer = null

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
        # 固定 440x240 をやめ、親(Control)いっぱいに広げる
        panel.set_anchors_preset(Control.PRESET_FULL_RECT)
        panel.offset_left = 0
        panel.offset_top = 0
        panel.offset_right = 0
        panel.offset_bottom = 0
        add_child(panel)

        # 枠の見た目
        var sb := StyleBoxFlat.new()
        sb.bg_color = Color(0.18, 0.18, 0.18, 1.0)
        sb.border_color = Color(0.35, 0.35, 0.35, 1.0)
        sb.border_width_left = 2
        sb.border_width_top = 2
        sb.border_width_right = 2
        sb.border_width_bottom = 2
        panel.add_theme_stylebox_override("panel", sb)

    # 2. Frame (タイトルバー + コンテンツ)
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

# --- 1) 置換: _build_content_area() ---
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
        vb.name = "VBox"
        margin.add_child(vb)

    var row := vb.get_node_or_null("Row") as HBoxContainer
    if row == null:
        row = HBoxContainer.new()
        row.name = "Row"
        vb.add_child(row)

    # --- Buttons ---
    trade_btn = _ensure_button(row, "TradeBtn", "Trade")
    map_btn = _ensure_button(row, "MapBtn", "Map")
    step_btn = _ensure_button(row, "StepBtn", "+1 Day")
    step_turn_btn = _ensure_button(row, "StepTurnBtn", "+1 Turn")
    move_btn = _ensure_button(row, "MoveBtn", "Move")
    # ★ 追加：契約
    _ensure_button(row, "ContractBtn", "契約")
    info_btn = _ensure_button(row, "InfoBtn", "情報")
    inv_btn = _ensure_button(row, "InvBtn", "Inv")
    trust_btn = _ensure_button(row, "TrustBtn", "信用") 
    # --- Info Area ---
    var sep := vb.get_node_or_null("HSeparator") as HSeparator
    if sep == null:
        sep = HSeparator.new()
        sep.name = "HSeparator"
        vb.add_child(sep)

    var info := vb.get_node_or_null("Info") as VBoxContainer
    if info == null:
        info = VBoxContainer.new()
        info.name = "Info"
        vb.add_child(info)

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
    
# --- 2) 置換: _connect_signals() ---
func _connect_signals() -> void:
    # シグナル接続
    if close_btn and not close_btn.pressed.is_connected(Callable(self, "_on_close")):
        close_btn.pressed.connect(_on_close)
    if trade_btn and not trade_btn.pressed.is_connected(Callable(self, "_on_trade")):
        trade_btn.pressed.connect(_on_trade)
    if map_btn and not map_btn.pressed.is_connected(Callable(self, "_on_map")):
        map_btn.pressed.connect(_on_map)

    # ★ 追加：契約
    var contract_btn := panel.get_node("Frame/Margin/VBox/Row").get_node_or_null("ContractBtn") as Button
    if contract_btn and not contract_btn.pressed.is_connected(Callable(self, "_on_contracts")):
        contract_btn.pressed.connect(_on_contracts)

    if info_btn and not info_btn.pressed.is_connected(Callable(self, "_on_info")):
        info_btn.pressed.connect(_on_info)
    if step_btn and not step_btn.pressed.is_connected(Callable(self, "_on_step")):
        step_btn.pressed.connect(_on_step)
    if step_turn_btn and not step_turn_btn.pressed.is_connected(Callable(self, "_on_step_turn")):
        step_turn_btn.pressed.connect(_on_step_turn)
    if move_btn and not move_btn.pressed.is_connected(Callable(self, "_on_move")):
        move_btn.pressed.connect(_on_move)
    if inv_btn and not inv_btn.pressed.is_connected(Callable(self, "_on_inv")):
        inv_btn.pressed.connect(_on_inv)

    # ★ 追加：信用
    if trust_btn and not trust_btn.pressed.is_connected(Callable(self, "_on_trust")):
        trust_btn.pressed.connect(_on_trust)

# --- Info 更新 ---
func _rebuild() -> void:
    if world == null:
        return

    # --- 日付＋ターン表記（GameHUDと同じロジック） ---
    var date_txt: String
    if world.has_method("format_date"):
        date_txt = world.format_date()
    else:
        date_txt = "Day %d" % world.day

    var turn_now: int = 1
    if world.get("turn") != null:
        turn_now = int(world.get("turn")) + 1

    var tpd: int = 3
    if world.get("turns_per_day") != null:
        tpd = int(world.get("turns_per_day"))

    # 例: "1/3  T 1/3" のような表示になる
    info_day.text = "%s  T %d/%d" % [date_txt, turn_now, tpd]

    # --- 以降は既存ロジックそのまま ---
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


func _on_step_turn() -> void:
    if world == null:
        return
    if world.is_paused():
        world.step_one_turn()
    else:
        world.pause()
        world.step_one_turn()

func _on_info() -> void:
    if world == null:
        _show_info("World が見つかりません。")
        return
    var moving := bool(world.player.get("enroute", false))
    if moving:
        _show_info("移動中は情報を集められません。")
        return
    _open_rumor_window()

func _open_rumor_window() -> void:
    if rumor_win == null:
        rumor_win = Window.new()
        rumor_win.name = "RumorWindow"; rumor_win.title = "情報（市場の噂）"
        rumor_win.size = Vector2i(420, 320); rumor_win.min_size = Vector2i(360, 260)
        rumor_win.unresizable = false
        get_tree().root.add_child(rumor_win)
        var root := VBoxContainer.new(); rumor_win.add_child(root)
        root.set_anchors_preset(Control.PRESET_FULL_RECT)
        root.offset_left = 12; root.offset_right = -12; root.offset_top = 12; root.offset_bottom = -12
        # 説明
        var desc := Label.new(); desc.text = "入手した噂は即時に市場へ反映されます。\n価格はWorldのエクスポート変数で編集できます。"
        root.add_child(desc)
        # コスト選択（0/100/500）行
        var costs := _world_costs()
        var accs := _world_accs()
        var price_col := VBoxContainer.new()
        root.add_child(price_col)
        var btn_free := Button.new(); btn_free.text = "%s（精度%d%%）" % [_label_for_cost(costs["free"]), int(round(accs["free"]*100.0))]
        var btn_near := Button.new(); btn_near.text = "%s（精度%d%%）" % [_label_for_cost(costs["near"]), int(round(accs["near"]*100.0))]
        var btn_target := Button.new(); btn_target.text = "%s（精度%d%%）" % [_label_for_cost(costs["target"]), int(round(accs["target"]*100.0))]
        price_col.add_child(btn_free)
        price_col.add_child(btn_near)
        price_col.add_child(btn_target)
        btn_free.pressed.connect(func(): _buy_rumor("free"))
        btn_near.pressed.connect(func(): _buy_rumor("near"))
        btn_target.pressed.connect(func(): _buy_rumor("target"))
        var closeb := Button.new(); closeb.text = "閉じる"
        root.add_child(closeb)
        closeb.pressed.connect(func(): rumor_win.hide())
        rumor_win.close_requested.connect(func(): rumor_win.hide())
    rumor_win.popup_centered()
    rumor_win.grab_focus()

func _populate_rumors() -> void:
    if rumor_win == null or world == null:
        return
    if rumor_list == null:
        return
    # クリア
    for ch in rumor_list.get_children():
        rumor_list.remove_child(ch)
        ch.queue_free()
    _rumors_current = world.generate_rumors(String(world.player.get("city","")), 3)
    if _rumors_current.is_empty():
        var empty := Label.new(); empty.text = "噂は見つかりませんでした。"
        rumor_list.add_child(empty)
        return
    # 行を生成
    for r_any in _rumors_current:
        var r: Dictionary = r_any
        var row := HBoxContainer.new()
        var lab := Label.new(); lab.text = String(r.get("flavor_ja","")); lab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        var btn := Button.new(); btn.text = "適用"
        row.add_child(lab); row.add_child(btn); rumor_list.add_child(row)
        btn.pressed.connect(func():
            world.apply_rumor(r, _world_accs()["target"])
            rumor_win.hide()
        )
func _on_move() -> void:
    if hud and hud.has_method("_open_move_window"):
        hud.call("_open_move_window")

func _on_inv() -> void:
    if hud and hud.has_method("_open_inventory_window"):
        hud.call("_open_inventory_window")

func _on_trust() -> void:
    _ensure_trust_window()
    _rebuild_trust_list()

    if trust_win:
        # 位置とサイズをHUD共通ロジックに合わせる
        _size_and_center(trust_win)
        # Window は popup_centered() で前面＆表示
        trust_win.popup_centered()
        trust_win.grab_focus()


func _on_close() -> void:
    visible = false

# --- タイトルバーのドラッグ処理 ---
func _on_title_gui_input(ev: InputEvent) -> void:
    if ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_LEFT:
        if ev.pressed:
            _dragging = true
            _drag_start = (ev as InputEventMouseButton).global_position
            # ← Back ではなく MenuPanel(自分) の位置を基準にする
            _panel_start = global_position
            accept_event()
        else:
            _dragging = false
    elif ev is InputEventMouseMotion and _dragging:
        var delta := (ev as InputEventMouseMotion).global_position - _drag_start
        # ← ウィンドウ本体（MenuPanel）を動かす
        global_position = _panel_start + delta


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


func _label_for_cost(cost: int) -> String:
    return "無料" if cost <= 0 else str(cost)

func _world_costs() -> Dictionary:
    if world == null: return {"free":0,"near":100,"target":500}
    return {
        "free": int(world.rumor_cost_free),
        "near": int(world.rumor_cost_nearby),
        "target": int(world.rumor_cost_target)
    }

func _world_accs() -> Dictionary:
    if world == null: return {"free":1.0,"near":1.0,"target":1.0}
    return {
        "free": float(world.rumor_acc_free),
        "near": float(world.rumor_acc_nearby),
        "target": float(world.rumor_acc_target)
    }


# --- 情報（噂）購入：コスト＆精度 ---
func _buy_rumor(mode: String) -> void:
    if world == null:
        return
    var costs := _world_costs() if has_method("_world_costs") else {"free":0,"near":0,"target":0}
    var accs := _world_accs() if has_method("_world_accs") else {"free":1.0,"near":1.0,"target":1.0}
    var cost := int(costs.get(mode, 0))
    var acc := float(accs.get(mode, 1.0))
    # 支払い
    var cash := float(world.player.get("cash", 0.0))
    if cost > 0 and cash < float(cost):
        _show_info("所持金が足りません。（必要: %d）" % cost)
        return
    if cost > 0:
        world.player["cash"] = cash - float(cost)
        if world.has_method("world_updated"):
            world.world_updated.emit()
    # 噂生成（nearは近隣優先、targetは現在地優先のフォールバック）
    var here := String(world.player.get("city",""))
    var arr: Array
    arr = world.generate_rumors("", 1)
    if arr.is_empty():
            _show_info("噂は見つかりませんでした。")
            return
    var r: Dictionary = arr[0]
    world.apply_rumor(r, acc)
    var flavor := String(r.get("flavor_ja", "噂"))
    _show_info("%s（精度%d%%）" % [flavor, int(round(acc * 100.0))])

# --- 3) 追記: 契約UI（ファイル末尾にそのまま貼り付け） ---
# 押下→契約ウインドウ
func _on_contracts() -> void:
    _open_contracts_window()

# 契約ウインドウ生成
# 受注済み一覧（ホーム）— 「契約」ボタン押下時はこちらを開く
# 置換: _open_contracts_window（受注済み一覧）
func _open_contracts_window() -> void:
    if world == null:
        return
    var old := get_node_or_null("ContractsActiveWin")
    if old:
        old.queue_free()

    var win := Window.new()
    win.name = "ContractsActiveWin"
    win.title = "契約 — 受注済み一覧"
    win.initial_position = Window.WINDOW_INITIAL_POSITION_CENTER_PRIMARY_SCREEN
    win.exclusive = true
    win.transient = true
    add_child(win)
    win.close_requested.connect(func(): win.hide())

    # ── 骨組み ───────────────────────────────
    var margin := MarginContainer.new()
    margin.name = "Margin"
    win.add_child(margin)
    margin.set_anchors_preset(Control.PRESET_FULL_RECT)
    margin.add_theme_constant_override("margin_left", 12)
    margin.add_theme_constant_override("margin_right", 12)
    margin.add_theme_constant_override("margin_top", 8)
    margin.add_theme_constant_override("margin_bottom", 12)

    var vb := VBoxContainer.new(); vb.name = "VBox"
    vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    vb.size_flags_vertical = Control.SIZE_EXPAND_FILL
    margin.add_child(vb)

    var header := Label.new(); header.name = "Header"
    header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    header.text = "受注中の契約を表示します。"
    vb.add_child(header)

    var top := HBoxContainer.new(); top.name = "TopRow"
    top.add_theme_constant_override("separation", 8)
    vb.add_child(top)

    var new_btn := Button.new(); new_btn.text = "新規受注"
    top.add_child(new_btn)
    new_btn.pressed.connect(func(): _open_contracts_offers_window())

    var refresh_btn := Button.new(); refresh_btn.text = "更新"
    top.add_child(refresh_btn)

    var spacer := Control.new(); spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    top.add_child(spacer)

    var close_btn := Button.new(); close_btn.text = "閉じる"
    top.add_child(close_btn)

    var sc := ScrollContainer.new(); sc.name = "Scroll"
    sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
    sc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
    vb.add_child(sc)

    var list := VBoxContainer.new(); list.name = "List"
    list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    sc.add_child(list)
    # ────────────────────────────────────────

    refresh_btn.pressed.connect(func(): _refresh_active_contracts_list(win))
    close_btn.pressed.connect(func(): win.hide())

    _refresh_active_contracts_list(win)
    _size_and_center(win)
    win.popup_centered()
    win.grab_focus()


func _refresh_active_contracts_list(win: Window) -> void:
    if world == null or win == null:
        return

    var vb: VBoxContainer = win.get_node_or_null("Margin/VBox") as VBoxContainer
    if vb == null:
        return
    var header: Label = vb.get_node_or_null("Header") as Label
    var list: VBoxContainer = vb.get_node_or_null("Scroll/List") as VBoxContainer
    if header == null or list == null:
        return

    # クリア
    for c in list.get_children():
        c.queue_free()

    # 受注中（stateの揺れ "active"/"accepted" を許容）
    var actives: Array = []

    # まずは公式APIを試す（戻り値が配列なら採用）
    if world.has_method("contracts_get_active"):
        var res := world.contracts_get_active(false)
        if typeof(res) == TYPE_ARRAY:
            actives = res
    elif world.has_method("get_active_contracts"):
        var res2: Array = world.get_active_contracts(false)
        if typeof(res2) == TYPE_ARRAY:
            actives = res2

    # フォールバック: ワールドの内部配列を直接参照（プロパティ存在チェックを安全に）
    if actives.is_empty():
        var raw: Array = []
        var tmp = world.get("_contracts_active")  # ★ 第2引数なし
        if typeof(tmp) == TYPE_ARRAY:
            raw = tmp
        # state フィルタ（active/accepted）
        var filtered: Array = []
        for any in raw:
            if typeof(any) != TYPE_DICTIONARY:
                continue
            var ct: Dictionary = any
            var st := String(ct.get("state",""))
            if st == "active" or st == "accepted":
                filtered.append(ct)
        actives = filtered

    # ヘッダー
    var n: int = actives.size()
    header.text = "受注中の契約: %d 件（期限と残日数を確認してください）" % n

    if n <= 0:
        var empty := Label.new()
        empty.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        empty.text = "現在、受注中の契約はありません。"
        list.add_child(empty)
        return

    # 表示
    for i in range(actives.size()):
        var ct: Dictionary = actives[i]
        list.add_child(_active_row(ct))


# 受注済み1行のUI
# 置換: _active_row
func _active_row(ct: Dictionary) -> HBoxContainer:
    var row := HBoxContainer.new()
    row.add_theme_constant_override("separation", 8)
    row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

    var vb := VBoxContainer.new()
    vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    row.add_child(vb)

    var title := Label.new()
    title.text = _active_title_text(ct)
    title.autowrap_mode = TextServer.AUTOWRAP_OFF   # ← 早期改行を防止
    title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    vb.add_child(title)

    var sub := Label.new()
    sub.text = _active_sub_text(ct)                 # ← 共通関数で統一
    sub.autowrap_mode = TextServer.AUTOWRAP_OFF     # ← 2行目も改行を遅らせる
    sub.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    vb.add_child(sub)

    var right := HBoxContainer.new()
    right.alignment = BoxContainer.ALIGNMENT_END
    right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    vb.add_child(right)

    var detail_btn := Button.new()
    detail_btn.text = "詳細"
    right.add_child(detail_btn)
    detail_btn.pressed.connect(func(): _show_contract_detail(ct))

    return row


func _active_contract_row(ct: Dictionary) -> HBoxContainer:
    var row := HBoxContainer.new()
    row.add_theme_constant_override("separation", 8)
    row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

    var vb := VBoxContainer.new()
    vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    row.add_child(vb)

    var title := Label.new()
    title.text = _active_title_text(ct)
    title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    vb.add_child(title)

    var sub := Label.new()
    sub.autowrap_mode = TextServer.AUTOWRAP_WORD
    sub.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    sub.text = _active_sub_text(ct)
    vb.add_child(sub)

    # 右側：残日数ピル風の簡易表示
    var right := HBoxContainer.new()
    right.alignment = BoxContainer.ALIGNMENT_END
    right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    vb.add_child(right)

    var rem := Label.new()
    var left := _days_left_for(ct)
    rem.text = "残り %d 日" % left if left >= 0 else "期限切れ"
    # Godot 4.3 方針：三項演算子を使わない
    if left >= 0:
        rem.text = "残り %d 日" % left
    else:
        rem.text = "期限切れ"
    right.add_child(rem)

    return row

# 置換: _active_title_text
func _active_title_text(ct: Dictionary) -> String:
    return _contract_title_text(ct)

# 置換: _active_sub_text
func _active_sub_text(ct: Dictionary) -> String:
    return _contract_sub_text(ct)

# --- 共通：契約テキストの組み立て（受注済／新規どちらでも使う） ---

func _contract_title_text(d: Dictionary) -> String:
    var pid := String(d.get("pid",""))
    var qty := int(d.get("qty", 0))
    var pname := pid
    if world != null and world.has_method("get_product_name"):
        var resolved := String(world.call("get_product_name", pid))
        if resolved != "":
            pname = resolved
    var dest := String(d.get("dest_name", d.get("dest","")))
    if dest == "":
        dest = _city_name(String(d.get("to","")))
    return "[納品] %s × %d → %s" % [pname, qty, dest]

func _contract_sub_text(d: Dictionary) -> String:
    var from := _city_name(String(d.get("from","")))
    var to := _city_name(String(d.get("to","")))
    var lim := int(d.get("deadline_day", d.get("deadline", 0)))
    var left := -1
    if world != null and lim > 0:
        left = int(lim - int(world.day))
    var reward := float(d.get("reward_cash", d.get("reward", 0.0)))

    var parts: Array[String] = []
    if from != "" or to != "":
        parts.append("発: %s / 宛: %s" % [from, to])

    if lim > 0:
        var dd := ""
        if left >= 0:
            dd = "期限: Day %d（残り %d日）" % [lim, left]
        else:
            dd = "期限: Day %d（期限切れ）" % lim
        parts.append(dd)

    if reward > 0.0:
        parts.append("報酬: %.0f" % reward)

    return " / ".join(parts)


func _days_left_for(ct: Dictionary) -> int:
    var lim := int(ct.get("deadline_day", ct.get("deadline", 0)))
    if lim <= 0 or world == null:
        return -1
    return int(lim - int(world.day))

# 既存の「契約（掲示板＝オファー一覧）」ウィンドウ
# 置換: _open_contracts_offers_window（新規受注＝掲示板）
func _open_contracts_offers_window() -> void:
    if world == null:
        return
    var old := get_node_or_null("ContractsOffersWin")
    if old:
        old.queue_free()

    var win := Window.new()
    win.name = "ContractsOffersWin"
    win.title = "契約 — 新規受注（掲示板）"
    win.initial_position = Window.WINDOW_INITIAL_POSITION_CENTER_PRIMARY_SCREEN
    win.exclusive = true
    win.transient = true
    add_child(win)
    win.close_requested.connect(func(): win.hide())

    # ── 骨組み ───────────────────────────────
    var margin := MarginContainer.new()
    margin.name = "Margin"
    win.add_child(margin)
    margin.set_anchors_preset(Control.PRESET_FULL_RECT)
    margin.add_theme_constant_override("margin_left", 12)
    margin.add_theme_constant_override("margin_right", 12)
    margin.add_theme_constant_override("margin_top", 8)
    margin.add_theme_constant_override("margin_bottom", 12)

    var vb := VBoxContainer.new(); vb.name = "VBox"
    vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    vb.size_flags_vertical = Control.SIZE_EXPAND_FILL
    margin.add_child(vb)

    var header := Label.new(); header.name = "Header"
    header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    vb.add_child(header)

    var sc := ScrollContainer.new(); sc.name = "Scroll"
    sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
    sc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
    vb.add_child(sc)

    var list := VBoxContainer.new(); list.name = "List"
    list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    sc.add_child(list)

    var row := HBoxContainer.new()
    row.add_theme_constant_override("separation", 8)
    row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    vb.add_child(row)

    var refresh_btn := Button.new(); refresh_btn.text = "更新"
    row.add_child(refresh_btn)

    var spacer := Control.new(); spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    row.add_child(spacer)

    var close_btn := Button.new(); close_btn.text = "閉じる"
    row.add_child(close_btn)
    # ────────────────────────────────────────

    refresh_btn.pressed.connect(func(): _refresh_contracts_list(win))
    close_btn.pressed.connect(func(): win.hide())

    _refresh_contracts_list(win)
    _size_and_center(win)
    win.popup_centered()
    win.grab_focus()


# 一覧の再構築
func _refresh_contracts_list(win: Window) -> void:
    if world == null or win == null:
        return
    var vb := win.get_node_or_null("Margin/VBox") as VBoxContainer
    if vb == null:
        return
    var header := vb.get_node_or_null("Header") as Label
    var list := vb.get_node_or_null("Scroll/List") as VBoxContainer
    if header == null or list == null:
        return

    for c in list.get_children():
        c.queue_free()

    var cid := String(world.player.get("city",""))
    var cname := _city_name(cid)
    header.text = "現在地: %s — 月ごとに契約が更新されます。受注上限は%d件。" % [cname, int(world.contracts_active_limit)]


    var offers: Array = _get_offers_for(cid)
    if offers.is_empty():
        var empty := Label.new()
        empty.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        empty.text = "今月、この都市で受けられる契約はありません。"
        list.add_child(empty)
        return

    for any_offer in offers:
        list.add_child(_contract_row(any_offer))

# 行UI
func _contract_row(offer: Dictionary) -> HBoxContainer:
    var row := HBoxContainer.new()
    row.add_theme_constant_override("separation", 8)
    row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

    var vb := VBoxContainer.new()
    vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    row.add_child(vb)

    var title := Label.new()
    title.text = _offer_title_text(offer)
    title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    vb.add_child(title)

    var sub := Label.new()
    sub.autowrap_mode = TextServer.AUTOWRAP_WORD
    sub.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    sub.text = _offer_summary_text(offer)  # ★要約を表示
    vb.add_child(sub)

    # 右側にレア度と詳細ボタン
    var right := HBoxContainer.new()
    right.alignment = BoxContainer.ALIGNMENT_END
    right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    vb.add_child(right)

    var star := Label.new()
    star.text = _stars_text(_stars_from_offer(offer))
    right.add_child(star)

    var detail_btn := Button.new()
    detail_btn.text = "詳細"
    right.add_child(detail_btn)
    detail_btn.pressed.connect(Callable(self, "_show_contract_detail").bind(offer))

    return row

# 詳細→受諾
func _show_contract_detail(offer: Dictionary) -> void:
    var dlg := ConfirmationDialog.new()
    dlg.title = "契約の詳細"
    dlg.exclusive = true
    dlg.transient = true
    add_child(dlg)

    # 本文は共通フォーマッタで一回だけ生成
    var text := _contract_title_text(offer) + "\n\n" + _contract_sub_text(offer)
    dlg.dialog_text = text

    dlg.get_ok_button().text = "OK"
    dlg.canceled.connect(func(): dlg.queue_free())
    dlg.confirmed.connect(func():
        if _accept_offer(offer):
            _refresh_views_after_accept()
        dlg.queue_free()
    )

    _popup_dialog_wide(dlg)  # ← 横幅を確保してから中央表示


# 追加: 受注直後に開いている一覧を即時更新
func _refresh_views_after_accept() -> void:
    var active_win := get_node_or_null("ContractsActiveWin") as Window
    if active_win != null:
        _refresh_active_contracts_list(active_win)
    var offers_win := get_node_or_null("ContractsOffersWin") as Window
    if offers_win != null:
        _refresh_contracts_list(offers_win)

# 文言整形
func _offer_title_text(offer: Dictionary) -> String:
    return _contract_title_text(offer)

func _offer_summary_text(offer: Dictionary) -> String:
    return _contract_sub_text(offer)

func _popup_dialog_wide(win: Window) -> void:
    var screen := get_window()
    var scr := Vector2i(1280, 720)
    if is_instance_valid(screen):
        scr = screen.size

    # 画面に対して適切な初期サイズ（幅は広め）
    var w := int(scr.x * 0.42)
    var h := int(scr.y * 0.34)
    if w < 520:
        w = 520
    if h < 260:
        h = 260

    win.min_size = Vector2i(w, h)
    win.size = Vector2i(w, h)
    win.initial_position = Window.WINDOW_INITIAL_POSITION_CENTER_PRIMARY_SCREEN
    win.popup_centered()
    win.grab_focus()


func _stars_text(n: int) -> String:
    var v : int = clamp(n, 1, 5)
    var s := ""
    for i in range(v):
        s += "★"
    for i in range(5 - v):
        s += "☆"
    return s

# --- World 側の多態呼び出し（未実装でも落ちないように） ---
func _get_offers_for(cid: String) -> Array:
    if world == null:
        return []
    # World 側関数名いずれにも対応
    if world.has_method("contracts_get_offers_for"):
        return world.call("contracts_get_offers_for", cid)
    if world.has_method("get_contract_offers_for"):
        return world.call("get_contract_offers_for", cid)
    if world.has_method("contracts_get_offers"):
        return world.call("contracts_get_offers", cid)
    if world.has_method("get_contract_offers"):
        return world.call("get_contract_offers", cid)
    if world.has_method("get_contracts_for_city"):
        return world.call("get_contracts_for_city", cid)
    return []

# --- 共通: ウィンドウを広めにして中央配置 ---
func _size_and_center(win: Window) -> void:
    var main := get_window()
    var screen_size: Vector2i = Vector2i(1280, 720)
    if is_instance_valid(main):
        screen_size = main.size
    var target := Vector2i(int(screen_size.x * 0.85), int(screen_size.y * 0.85))
    win.size = target
    win.position = (screen_size - target) / 2
    # GameHUD側に共通関数があればそれを優先
    if hud != null and hud.has_method("_size_and_center_window"):
        hud._size_and_center_window(win)

func _accept_offer(offer: Dictionary) -> bool:
    if world == null:
        return false
    var id := int(offer.get("id", -1))
    var ok := false
    # World 側の名称バリエーションに対応
    if world.has_method("contracts_accept"):
        ok = bool(world.call("contracts_accept", id))
    elif world.has_method("contracts_accept_by_id"):
        ok = bool(world.call("contracts_accept_by_id", id))
    elif world.has_method("accept_contract_by_id"):
        ok = bool(world.call("accept_contract_by_id", id))
    elif world.has_method("accept_contract"):
        ok = bool(world.call("accept_contract", id))
    elif world.has_method("accept_contract_for_city"):
        var cid := String(world.player.get("city",""))
        ok = bool(world.call("accept_contract_for_city", cid, offer))
    else:
        _show_info("契約APIが未実装のため受注できません。")
        ok = false

    if ok:
        _show_info("契約を受注しました。")
    return ok

func _stars_from_offer(offer: Dictionary) -> int:
    var n: int = int(offer.get("stars", 0))
    if n >= 1:
        return clamp(n, 1, 5)

    var r: Variant = offer.get("rarity", null)
    var t: int = typeof(r)

    if t == TYPE_INT:
        return clamp(int(r), 1, 5)
    elif t == TYPE_FLOAT:
        return clamp(int(round(float(r))), 1, 5)
    elif t == TYPE_STRING:
        var s: String = String(r).to_lower()
        match s:
            "common":
                return 1
            "uncommon":
                return 2
            "rare":
                return 3
            "epic":
                return 4
            "legendary":
                return 5
            _:
                pass
        # 数値文字列（例: "3"）も許容
        var as_num: int = s.to_int()
        if as_num > 0:
            return clamp(as_num, 1, 5)

    return 1

func _ensure_trust_window() -> void:
    if trust_win != null and is_instance_valid(trust_win):
        return

    trust_win = Window.new()
    trust_win.name = "TrustWindow"
    trust_win.title = "信用度"
    trust_win.min_size = Vector2i(360, 240)
    trust_win.size = Vector2i(420, 280)
    trust_win.unresizable = false

    # 閉じる操作で非表示にする
    if trust_win.has_signal("close_requested"):
        trust_win.close_requested.connect(func():
            if trust_win:
                trust_win.hide()
        )

    var margin := MarginContainer.new()
    margin.name = "Margin"
    margin.add_theme_constant_override("margin_left", 12)
    margin.add_theme_constant_override("margin_right", 12)
    margin.add_theme_constant_override("margin_top", 10)
    margin.add_theme_constant_override("margin_bottom", 10)
    margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
    trust_win.add_child(margin)
    margin.set_anchors_preset(Control.PRESET_FULL_RECT)

    var root := VBoxContainer.new()
    root.name = "Root"
    root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    root.size_flags_vertical = Control.SIZE_EXPAND_FILL
    margin.add_child(root)

    var header := Label.new()
    header.name = "Header"
    header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    header.text = "現在知られている地方ごとの信用度です。"
    root.add_child(header)

    var scroll := ScrollContainer.new()
    scroll.name = "Scroll"
    scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
    root.add_child(scroll)

    trust_list = VBoxContainer.new()
    trust_list.name = "List"
    trust_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    trust_list.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
    scroll.add_child(trust_list)

    var btn_row := HBoxContainer.new()
    btn_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    root.add_child(btn_row)

    var close_button := Button.new()
    close_button.text = "閉じる"
    close_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
    close_button.pressed.connect(func():
        if trust_win:
            trust_win.hide()
    )
    btn_row.add_child(close_button)

    # シーンツリーに追加
    get_tree().root.add_child(trust_win)
    _size_and_center(trust_win)

func _rebuild_trust_list() -> void:
    if trust_list == null:
        return

    # 一旦クリア
    for child in trust_list.get_children():
        child.queue_free()

    if world == null:
        var lbl_world := Label.new()
        lbl_world.text = "World が見つからないため信用情報を表示できません。"
        trust_list.add_child(lbl_world)
        return

    # プロヴィンス別の生データ（0〜100 の想定）
    var rep_dict: Dictionary = {}
    var any_rep = world.get("rep_by_province")
    if typeof(any_rep) == TYPE_DICTIONARY:
        rep_dict = any_rep

    if rep_dict.is_empty():
        var lbl_empty := Label.new()
        lbl_empty.text = "まだ信用度データがありません。"
        trust_list.add_child(lbl_empty)
        return

    # 「プレイヤーから見えている」プロヴィンスを抽出
    var visible_provs: Dictionary = {}
    var any_cities = world.get("cities")
    if typeof(any_cities) == TYPE_DICTIONARY:
        var cities: Dictionary = any_cities
        for cid_any in cities.keys():
            var cid := String(cid_any)
            var unlocked := true
            if world.has_method("is_city_unlocked"):
                unlocked = bool(world.call("is_city_unlocked", cid))
            if not unlocked:
                continue

            var city_info = cities.get(cid, {}) as Dictionary
            var prov := String(city_info.get("province", ""))
            if prov != "":
                visible_provs[prov] = true

    var filter_by_visibility := not visible_provs.is_empty()

    # プロヴィンスIDでソート（"Pilton","Tolkken"...）
    var prov_ids: Array = rep_dict.keys()
    prov_ids.sort_custom(func(a, b):
        return String(a) < String(b)
    )

    var shown_any := false
    for prov_any in prov_ids:
        var prov_id := String(prov_any)
        if filter_by_visibility and not visible_provs.has(prov_id):
            continue

        shown_any = true
        var v = rep_dict.get(prov_id, 0.0)
        var value: float = 0.0

        match typeof(v):
            TYPE_FLOAT:
                value = float(v)
            TYPE_INT:
                value = float(int(v))
            _:
                value = float(v)

        var line := Label.new()
        line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        # ひとまず数値のみ表示（将来はランク名を足す）
        line.text = "%s：%.1f" % [prov_id, value]
        trust_list.add_child(line)

    if not shown_any:
        var lbl_none := Label.new()
        lbl_none.text = "まだ訪れた地方がありません。"
        trust_list.add_child(lbl_none)
