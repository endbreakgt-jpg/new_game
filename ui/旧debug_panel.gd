extends Control

@export var world_path: NodePath
var world: World

@onready var day_label: Label = $MarginContainer/VBoxContainer/HBoxContainer/DayLabel
@onready var play_btn: Button = $MarginContainer/VBoxContainer/HBoxContainer/PlayPauseBtn
@onready var step_btn: Button = $MarginContainer/VBoxContainer/HBoxContainer/StepBtn
@onready var city_select: OptionButton = $MarginContainer/VBoxContainer/HBoxContainer/CitySelect
@onready var info_text: RichTextLabel = $MarginContainer/VBoxContainer/InfoText

var _last_player_focus_id: String = ""
var _map_window: Window = null

func _ready() -> void:
    if world_path != NodePath(""):
        world = get_node(world_path) as World
    else:
        world = get_parent() as World
    if world == null:
        push_error("DebugPanel: world not found")
        return

    world.day_advanced.connect(_on_day)
    world.world_updated.connect(_on_world_updated)

    _populate_cities_if_needed()
    play_btn.pressed.connect(_on_toggle_play)
    step_btn.pressed.connect(_on_step)
    city_select.item_selected.connect(_on_city_changed)

    _ensure_speed_buttons()
    _ensure_map_button()
    _ensure_player_row()

    _sync_play_button() # 起動時にボタン表示を同期（デフォルトは Play）
    var init_focus: String = _target_player_focus_id()
    if init_focus != "":
        _focus_city(init_focus)

    _refresh()

func _on_toggle_play() -> void:
    if world.is_paused():
        world.resume()
    else:
        world.pause()
    _sync_play_button()

func _on_step() -> void:
    if world.is_paused():
        world.step_one_day()
    else:
        world.pause()
        _sync_play_button()
        world.step_one_day()

func _on_day(_d: int) -> void:
    day_label.text = "Day %d" % world.day
    _refresh()

func _on_world_updated() -> void:
    _populate_cities_if_needed()
    var vb: VBoxContainer = $MarginContainer/VBoxContainer
    if vb.has_node("PlayerRow"):
        var pr: OptionButton = vb.get_node("PlayerRow/ProdSelect")
        var mv: OptionButton = vb.get_node("PlayerRow/MoveSelect")
        _populate_products(pr)
        _populate_move_cities(mv)
        _update_cash_label()
    # プレイヤーの都市が変わっていたら自動フォーカス
    var target_id := _target_player_focus_id()
    if target_id != "" and target_id != _last_player_focus_id:
        _last_player_focus_id = target_id
        _focus_city(target_id)
    _sync_play_button()  # ← この1行を追加
    _set_player_controls_enabled(not bool(world.player.get("enroute", false)))
    _refresh()

func _populate_cities_if_needed() -> void:
    if world == null:
        return
    if city_select.item_count == world.cities.size():
        return
    city_select.clear()
    var i := 0
    for cid in world.cities.keys():
        var label: String = String(world.cities[cid]["name"])
        city_select.add_item(label)
        city_select.set_item_metadata(i, cid)
        i += 1
    if city_select.item_count > 0:
        city_select.select(0)

func _on_city_changed(_i: int) -> void:
    _refresh()
    var vb: VBoxContainer = $MarginContainer/VBoxContainer
    if vb.has_node("PlayerRow"):
        var mv: OptionButton = vb.get_node("PlayerRow/MoveSelect")
        _populate_move_cities(mv)

func _refresh() -> void:
    if world == null:
        return
    day_label.text = "Day %d" % world.day
    var cid := _current_city_id()
    if cid == "":
        info_text.text = "(no city)"
        return
    info_text.text = _build_city_info(cid)
    _update_cash_label()
    _set_player_controls_enabled(not bool(world.player.get("enroute", false)))

func _build_city_info(cid: String) -> String:
    var sb := "[b]" + String(world.cities[cid]["name"]) + "[/b]\n"
    # 見出し（置換前: "商品（価格 / 在庫 / 目標）"）
    sb += "商品（買 / 売 / 在庫 / 目標）\n"
    for pid in world.products.keys():
        var p: Dictionary = world.products[pid]
        var ask: float = world.get_ask_price(cid, pid)
        var bid: float = world.get_bid_price(cid, pid)
        var rec: Dictionary = world.stock[cid].get(pid, {})
        var qty: int = int(rec.get("qty", 0))
        var target: int = int(rec.get("target", 0))
        sb += "  %s: %.1f / %.1f / %d / %d\n" % [String(p["name"]), ask, bid, qty, target]
    sb += "\nプレイヤー:\n"
    var pcid: String = String(world.player.get("city", ""))
    var _enroute: bool = bool(world.player.get("enroute", false))
    var _pdest: String = String(world.player.get("dest", ""))
    var cargo_str: String = str(world.player.get("cargo", {}))
    sb += "  YOU @ %s 所持金=%.1f 積載=%d/%d 積荷=%s\n" % [
        pcid,
        float(world.player.get("cash", 0.0)),
        world._cargo_used(world.player), int(world.player.get("cap", 0)),
        cargo_str
    ]
    sb += "\n商人:\n"
    for t in world.traders:
        var here: String = String(t.get("city", ""))
        var carry: int = world._cargo_used(t)
        sb += "  %s @ %s 所持金=%.1f 積載=%d/%d\n" % [String(t["id"]), here, float(t["cash"]), carry, int(t["cap"]) ]
        sb += " =" + str(t.get("cargo", {})) + " [g=%.1f r=%.1f e=%.1f]\n" % [float(t.get("greedy",0.7)), float(t.get("risk",0.5)), float(t.get("explore",0.2))]
    sb += "\n都市金庫: %.1f\n" % float(world.cities[cid].get("funds", 0.0))
    return sb

func _current_city_id() -> String:
    if city_select.selected < 0 or city_select.item_count == 0:
        return ""
    return String(city_select.get_item_metadata(city_select.selected))

# --- 速度ボタン（既存ノードを使う前提。必要なら生成してもOK）
func _ensure_speed_buttons() -> void:
    pass

# --- マップポップアウトボタンを追加（別ウインドウで表示） ---
func _ensure_map_button() -> void:
    var hb: HBoxContainer = $MarginContainer/VBoxContainer/HBoxContainer
    if hb.has_node("MapBtn"):
        return
    var btn := Button.new()
    btn.name = "MapBtn"
    btn.text = "Map"
    hb.add_child(btn)
    btn.pressed.connect(_on_map_pressed)

func _on_map_pressed() -> void:
    # すでに開いていればフォーカスを戻す
    if _map_window and is_instance_valid(_map_window):
        _map_window.grab_focus()
        return
    # 新規ウインドウ作成
    var win := Window.new()
    win.title = "Map"
    win.size = Vector2i(900, 520)
    win.position = Vector2i(120, 80)
    win.always_on_top = false
    get_tree().root.add_child(win)
    _map_window = win
    win.close_requested.connect(func():
        if _map_window:
            _map_window.queue_free()
            _map_window = null
    )
    # MapLayer を新規に生成してウインドウへ。World 参照を渡す
    var MapLayer := preload("res://scripts/map_layer.gd")
    var map := MapLayer.new()
    map.name = "MapLayer"
    map.world = world
    win.add_child(map)

func _ensure_player_row() -> void:
    var vb: VBoxContainer = $MarginContainer/VBoxContainer
    if vb.has_node("PlayerRow"):
        return
    var hb := HBoxContainer.new()
    hb.name = "PlayerRow"
    vb.add_child(hb)

    var l := Label.new(); l.text = "Player:"; hb.add_child(l)

    var prod := OptionButton.new(); prod.name = "ProdSelect"; hb.add_child(prod)
    var qty := SpinBox.new(); qty.name = "QtyBox"; qty.min_value = 1; qty.max_value = 999; qty.step = 1; qty.value = 1; qty.custom_minimum_size = Vector2(80,0); hb.add_child(qty)
    var buy := Button.new(); buy.name = "BuyBtn"; buy.text = "Buy"; hb.add_child(buy)
    var sell := Button.new(); sell.name = "SellBtn"; sell.text = "Sell"; hb.add_child(sell)

    var cash := Label.new(); cash.name = "CashLabel"; cash.text = "Cash: 0"; hb.add_child(cash)

    var arrow := Label.new(); arrow.text = " → "; hb.add_child(arrow)
    var move := OptionButton.new(); move.name = "MoveSelect"; hb.add_child(move)
    var depart := Button.new(); depart.name = "DepartBtn"; depart.text = "Depart"; hb.add_child(depart)

    buy.pressed.connect(_on_buy_pressed)
    sell.pressed.connect(_on_sell_pressed)
    depart.pressed.connect(_on_depart_pressed)

    _populate_products(prod)
    _populate_move_cities(move)

func _populate_products(ob: OptionButton) -> void:
    ob.clear()
    if world == null:
        return
    var idx := 0
    for pid in world.products.keys():
        var nm: String = String(world.products[pid]["name"])
        ob.add_item(nm)
        ob.set_item_metadata(idx, pid)
        idx += 1
    if ob.item_count > 0:
        ob.select(0)

func _populate_move_cities(ob: OptionButton) -> void:
    ob.clear()
    if world == null:
        return
    var cid := _current_city_id()
    var idx := 0
    if world.adj.has(cid):
        for nb in (world.adj[cid] as Array):
            var city_name: String = (String(world.cities[nb]["name"]) if world.cities.has(nb) else String(nb))
            ob.add_item(city_name)
            ob.set_item_metadata(idx, nb)
            idx += 1
    if ob.item_count > 0:
        ob.select(0)

func _on_buy_pressed() -> void:
    var hb: HBoxContainer = $MarginContainer/VBoxContainer/PlayerRow
    var pr: OptionButton = hb.get_node("ProdSelect")
    var qty: SpinBox = hb.get_node("QtyBox")
    if pr.selected < 0:
        return
    var pid: String = String(pr.get_item_metadata(pr.selected))
    if world.player_buy(pid, int(qty.value)):
        _update_cash_label()
        _refresh()

func _on_sell_pressed() -> void:
    var hb: HBoxContainer = $MarginContainer/VBoxContainer/PlayerRow
    var pr: OptionButton = hb.get_node("ProdSelect")
    var qty: SpinBox = hb.get_node("QtyBox")
    if pr.selected < 0:
        return
    var pid: String = String(pr.get_item_metadata(pr.selected))
    if world.player_sell(pid, int(qty.value)):
        _update_cash_label()
        _refresh()

func _on_depart_pressed() -> void:
    var hb: HBoxContainer = $MarginContainer/VBoxContainer/PlayerRow
    var mv: OptionButton = hb.get_node("MoveSelect")
    if mv.selected < 0:
        return
    var dest: String = String(mv.get_item_metadata(mv.selected))
    if world.player_move(dest):
        _update_cash_label()
        _focus_city(dest)
        _refresh()

func _update_cash_label() -> void:
    var vb: VBoxContainer = $MarginContainer/VBoxContainer
    if not vb.has_node("PlayerRow"):
        return
    var cashl: Label = vb.get_node("PlayerRow/CashLabel")
    if world:
        cashl.text = "Cash: %.1f" % float(world.player.get("cash", 0.0))

# プレイヤー操作の有効/無効を切り替える
func _set_player_controls_enabled(enabled: bool) -> void:
    var vb: VBoxContainer = $MarginContainer/VBoxContainer
    if not vb.has_node("PlayerRow"):
        return
    var hb: HBoxContainer = vb.get_node("PlayerRow")
    if hb.has_node("BuyBtn"):
        hb.get_node("BuyBtn").disabled = not enabled
    if hb.has_node("SellBtn"):
        hb.get_node("SellBtn").disabled = not enabled
    if hb.has_node("QtyBox"):
        (hb.get_node("QtyBox") as SpinBox).editable = enabled
    if hb.has_node("ProdSelect"):
        hb.get_node("ProdSelect").disabled = not enabled
    if hb.has_node("MoveSelect"):
        hb.get_node("MoveSelect").disabled = not enabled
    if hb.has_node("DepartBtn"):
        hb.get_node("DepartBtn").disabled = not enabled

func _sync_play_button() -> void:
    if world and world.is_paused():
        play_btn.text = "Play"
    else:
        play_btn.text = "Pause"

func _target_player_focus_id() -> String:
    if world == null:
        return ""
    return String(world.player.get("dest", "")) if bool(world.player.get("enroute", false)) else String(world.player.get("city", ""))

func _focus_city(cid: String) -> void:
    if cid == "":
        return
    for i in range(city_select.item_count):
        if String(city_select.get_item_metadata(i)) == cid:
            city_select.select(i)
            break
    var vb: VBoxContainer = $MarginContainer/VBoxContainer
    if vb.has_node("PlayerRow"):
        var mv: OptionButton = vb.get_node("PlayerRow/MoveSelect")
        _populate_move_cities(mv)
