extends Window

var world: World

enum {
    MODE_MENU,
    MODE_MARKET,
    MODE_CONSIGN,
    MODE_FAIR
}

var page_menu: Control
var page_market: Control
var page_consign: Control
var page_fair: Control
var _suppress_qty_reset: bool = false

var m_product_list: ItemList
var m_inventory_list: ItemList
var m_qty_spin: SpinBox
var m_buy_btn: Button
var m_sell_btn: Button
var m_max_btn: Button
var m_info: RichTextLabel

var c_list: ItemList
var c_qty: SpinBox
var c_days: SpinBox
var c_mult: SpinBox
var c_btn: Button
var c_info: RichTextLabel

var f_info: RichTextLabel
var f_join_btn: Button

func _has_prop(o: Object, prop: String) -> bool:
    for p in o.get_property_list():
        if String(p.get("name", "")) == prop:
            return true
    return false

func _ready() -> void:
    title = "Trade"
    size = Vector2i(820, 540)
    min_size = Vector2i(680, 420)
    unresizable = false
    _ensure_root()

    if world == null:
        var p := get_parent()
        if p and p.has_method("get_world"):
            world = p.call("get_world")
        else:
            world = get_tree().root.find_child("World", true, false) as World

    if world and not world.world_updated.is_connected(Callable(self, "_on_world_updated")):
        world.world_updated.connect(_on_world_updated)

    if has_signal("close_requested"):
        close_requested.connect(func():
            _show_page(MODE_MENU)
            hide()
        )
    if has_signal("visibility_changed"):
        visibility_changed.connect(func():
            if visible:
                _show_page(MODE_MENU)
        )

    _show_page(MODE_MENU)

func _input(event: InputEvent) -> void:
    if event.is_action_pressed("ui_cancel"):
        _show_page(MODE_MENU)
        hide()
        get_viewport().set_input_as_handled()

func _ensure_root() -> void:
    var margin := get_node_or_null("Margin") as MarginContainer
    if margin == null:
        margin = MarginContainer.new()
        margin.name = "Margin"
        margin.add_theme_constant_override("margin_left", 12)
        margin.add_theme_constant_override("margin_right", 12)
        margin.add_theme_constant_override("margin_top", 10)
        margin.add_theme_constant_override("margin_bottom", 10)
        add_child(margin)
        margin.set_anchors_preset(Control.PRESET_FULL_RECT)
        margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        margin.size_flags_vertical = Control.SIZE_EXPAND_FILL

    var root := margin.get_node_or_null("Root") as VBoxContainer
    if root == null:
        root = VBoxContainer.new(); root.name = "Root"
        root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        root.size_flags_vertical = Control.SIZE_EXPAND_FILL
        margin.add_child(root)

    page_menu = root.get_node_or_null("PageMenu") as Control
    page_market = root.get_node_or_null("PageMarket") as Control
    page_consign = root.get_node_or_null("PageConsign") as Control
    page_fair = root.get_node_or_null("PageFair") as Control

func _hide_all_pages() -> void:
    if page_menu: page_menu.visible = false
    if page_market: page_market.visible = false
    if page_consign: page_consign.visible = false
    if page_fair: page_fair.visible = false

func _show_page(mode: int) -> void:
    _hide_all_pages()
    match mode:
        MODE_MENU:
            _build_menu_if_needed()
            page_menu.visible = true
            _update_menu_buttons()
        MODE_MARKET:
            _build_market_if_needed()
            page_market.visible = true
            _market_rebuild_lists()
            _market_refresh()
        MODE_CONSIGN:
            _build_consign_if_needed()
            page_consign.visible = true
            _consign_rebuild_list()
            _consign_refresh()
        MODE_FAIR:
            _build_fair_if_needed()
            page_fair.visible = true
            _fair_refresh()

func reset_to_menu() -> void:
    _show_page(MODE_MENU)

func _build_menu_if_needed() -> void:
    if page_menu: return
    var root := get_node("Margin/Root") as VBoxContainer
    var vb := VBoxContainer.new(); vb.name = "PageMenu"
    vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    vb.size_flags_vertical = Control.SIZE_EXPAND_FILL
    root.add_child(vb)

    var title_lbl := Label.new(); title_lbl.text = "取引"
    vb.add_child(title_lbl)

    var hb := HBoxContainer.new()
    hb.add_theme_constant_override("separation", 12)
    vb.add_child(hb)

    var btn_market := Button.new(); btn_market.text = "市場"
    hb.add_child(btn_market)
    btn_market.pressed.connect(func(): _show_page(MODE_MARKET))

    var btn_consign := Button.new(); btn_consign.text = "委託販売"
    hb.add_child(btn_consign)
    btn_consign.pressed.connect(func(): _show_page(MODE_CONSIGN))

    var btn_fair := Button.new(); btn_fair.text = "定期市"
    hb.add_child(btn_fair)
    btn_fair.disabled = not _is_fair_available_today()
    btn_fair.pressed.connect(func(): _show_page(MODE_FAIR))

    page_menu = vb

func _update_menu_buttons() -> void:
    if page_menu == null: return
    for child in page_menu.get_children():
        if child is HBoxContainer:
            for c in child.get_children():
                if c is Button and String(c.text) == "定期市":
                    c.disabled = not _is_fair_available_today()

func _build_market_if_needed() -> void:
    if page_market: return
    var root := get_node("Margin/Root") as VBoxContainer
    var vb := VBoxContainer.new(); vb.name = "PageMarket"
    vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    vb.size_flags_vertical = Control.SIZE_EXPAND_FILL
    root.add_child(vb)

    var top := HBoxContainer.new(); top.name = "Top"
    top.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    top.size_flags_vertical = Control.SIZE_EXPAND_FILL
    vb.add_child(top)

    var left := VBoxContainer.new(); left.name = "Left"
    left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    left.size_flags_vertical = Control.SIZE_EXPAND_FILL
    top.add_child(left)
    var l_title := Label.new(); l_title.text = "市場"; left.add_child(l_title)
    m_product_list = ItemList.new(); m_product_list.name = "Products"
    m_product_list.select_mode = ItemList.SELECT_SINGLE
    m_product_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
    m_product_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    m_product_list.custom_minimum_size = Vector2(340, 220)
    left.add_child(m_product_list)

    var right := VBoxContainer.new(); right.name = "Right"
    right.size_flags_vertical = Control.SIZE_EXPAND_FILL
    right.custom_minimum_size = Vector2(260, 0)
    top.add_child(right)
    var r_title := Label.new(); r_title.text = "所持品"; right.add_child(r_title)
    m_inventory_list = ItemList.new(); m_inventory_list.name = "Inventory"
    m_inventory_list.select_mode = ItemList.SELECT_SINGLE
    m_inventory_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
    m_inventory_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    m_inventory_list.custom_minimum_size = Vector2(260, 220)
    right.add_child(m_inventory_list)

    m_info = RichTextLabel.new(); m_info.name = "Info"
    m_info.bbcode_enabled = true
    m_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    m_info.scroll_active = true
    m_info.fit_content = false
    m_info.custom_minimum_size = Vector2(0, 192)
    m_info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    m_info.size_flags_vertical = Control.SIZE_FILL
    vb.add_child(m_info)

    var row := HBoxContainer.new(); row.name = "Row"
    row.add_theme_constant_override("separation", 8)
    row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    row.size_flags_vertical = Control.SIZE_SHRINK_CENTER
    row.custom_minimum_size = Vector2(0, 40)
    vb.add_child(row)

    m_qty_spin = SpinBox.new(); m_qty_spin.name = "Qty"
    m_qty_spin.min_value = 0; m_qty_spin.max_value = 9999; m_qty_spin.step = 1; m_qty_spin.value = 1
    m_qty_spin.custom_minimum_size = Vector2(96, 0)
    row.add_child(m_qty_spin)

    m_buy_btn = Button.new(); m_buy_btn.text = "Buy"; row.add_child(m_buy_btn)
    m_sell_btn = Button.new(); m_sell_btn.text = "Sell"; row.add_child(m_sell_btn)
    m_max_btn = Button.new(); m_max_btn.text = "Max"; row.add_child(m_max_btn)

    m_buy_btn.pressed.connect(_on_buy)
    m_sell_btn.pressed.connect(_on_sell)
    m_max_btn.pressed.connect(_on_max)
    m_product_list.item_selected.connect(_on_product_selected)
    m_inventory_list.item_selected.connect(_on_inventory_selected)
    m_qty_spin.value_changed.connect(_on_qty_changed)

    page_market = vb
    _market_rebuild_lists()

func _build_consign_if_needed() -> void:
    if page_consign: return
    var root := get_node("Margin/Root") as VBoxContainer
    var vb := VBoxContainer.new(); vb.name = "PageConsign"
    vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    vb.size_flags_vertical = Control.SIZE_EXPAND_FILL
    root.add_child(vb)

    var title_lbl := Label.new(); title_lbl.text = "委託販売"; vb.add_child(title_lbl)

    c_list = ItemList.new(); c_list.name = "Cargo"
    c_list.select_mode = ItemList.SELECT_SINGLE
    c_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    c_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
    c_list.custom_minimum_size = Vector2(340, 220)
    vb.add_child(c_list)

    var row := HBoxContainer.new(); row.add_theme_constant_override("separation", 8)
    row.custom_minimum_size = Vector2(0, 40)
    vb.add_child(row)

    var lq := Label.new(); lq.text = "数量"; row.add_child(lq)
    c_qty = SpinBox.new(); c_qty.min_value = 0; c_qty.max_value = 9999; c_qty.step = 1; c_qty.value = 0
    c_qty.custom_minimum_size = Vector2(96, 0)
    row.add_child(c_qty)

    var ld := Label.new(); ld.text = "日数"; row.add_child(ld)
    c_days = SpinBox.new(); c_days.min_value = 1; c_days.max_value = 60; c_days.step = 1; c_days.value = 7
    c_days.custom_minimum_size = Vector2(72, 0)
    row.add_child(c_days)

    var lm := Label.new(); lm.text = "倍率"; row.add_child(lm)
    c_mult = SpinBox.new(); c_mult.min_value = 0.5; c_mult.max_value = 2.0; c_mult.step = 0.1; c_mult.value = 1.0
    c_mult.custom_minimum_size = Vector2(72, 0)
    c_mult.editable = false
    c_mult.visible = false
    row.add_child(c_mult)
    lm.visible = false

    c_btn = Button.new(); c_btn.text = "委託"; row.add_child(c_btn)

    c_info = RichTextLabel.new(); c_info.bbcode_enabled = true; vb.add_child(c_info)

    c_list.item_selected.connect(func(_i: int): _consign_selected_changed())
    c_qty.value_changed.connect(func(_v: float): _consign_refresh())
    c_btn.pressed.connect(_on_consign)

    page_consign = vb
    _consign_rebuild_list()

func _build_fair_if_needed() -> void:
    if page_fair: return
    var root := get_node("Margin/Root") as VBoxContainer
    var vb := VBoxContainer.new(); vb.name = "PageFair"
    vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    vb.size_flags_vertical = Control.SIZE_EXPAND_FILL
    root.add_child(vb)

    var title_lbl := Label.new(); title_lbl.text = "定期市"; vb.add_child(title_lbl)

    f_info = RichTextLabel.new(); f_info.bbcode_enabled = true
    f_info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    f_info.size_flags_vertical = Control.SIZE_EXPAND_FILL
    vb.add_child(f_info)

    f_join_btn = Button.new(); f_join_btn.text = "市に参加"; vb.add_child(f_join_btn)
    f_join_btn.pressed.connect(_on_join_fair)
    page_fair = vb

func _on_world_updated() -> void:
    var keep := ""
    if page_market and m_product_list and m_product_list.item_count > 0:
        keep = _cur_pid_market()
    if page_market:
        _market_rebuild_lists(keep)
        _market_refresh()
    if page_consign:
        _consign_rebuild_list()
        _consign_refresh()
    if page_fair:
        _fair_refresh()

func _market_rebuild_lists(keep_pid: String = "") -> void:
    if page_market == null or world == null: return
    m_product_list.clear()
    var cid: String = String(world.player.get("city", ""))
    var idx: int = 0
    for pid in world.products.keys():
        var name: String = String(world.products[pid].get("name", pid))
        var ask: float = world.get_ask_price(cid, pid)
        var bid: float = world.get_bid_price(cid, pid)
        var avail: int = 0
        if world.stock.has(cid) and world.stock[cid].has(pid):
            avail = int(world.stock[cid][pid]["qty"])
        var line: String = "%s  買:%.1f 売:%.1f 在庫:%d" % [name, ask, bid, avail]
        m_product_list.add_item(line)
        m_product_list.set_item_metadata(idx, pid)
        idx += 1
    if m_product_list.item_count > 0:
        var target := 0
        if keep_pid != "":
            for i in range(m_product_list.item_count):
                if String(m_product_list.get_item_metadata(i)) == keep_pid:
                    target = i
                    break
        m_product_list.select(target)
        _suppress_qty_reset = true
        _on_product_selected(target)   # ← ここでは数量を変えない
        _suppress_qty_reset = false

    m_inventory_list.clear()
    var cargo := world.player.get("cargo", {}) as Dictionary
    idx = 0
    for pid2 in cargo.keys():
        var q: int = int(cargo[pid2])
        if q <= 0: continue
        var name2: String = String(world.products.get(pid2, {}).get("name", String(pid2)))
        var bid2: float = world.get_bid_price(cid, String(pid2))
        var line2: String = "%s  x%d  (売:%.1f)" % [name2, q, bid2]
        m_inventory_list.add_item(line2)
        m_inventory_list.set_item_metadata(idx, String(pid2))
        idx += 1

func _cur_pid_market() -> String:
    if m_product_list == null or m_product_list.item_count <= 0: return ""
    var sel: PackedInt32Array = m_product_list.get_selected_items()
    if sel.is_empty(): return ""
    var i: int = sel[0]
    return String(m_product_list.get_item_metadata(i))

func _market_refresh() -> void:
    if world == null or page_market == null: return
    var cid: String = String(world.player.get("city", ""))
    var pid: String = _cur_pid_market()
    var txt: String = ""
    if pid != "":
        var pname: String = String(world.products[pid].get("name", pid))
        var ask: float = world.get_ask_price(cid, pid)
        var bid: float = world.get_bid_price(cid, pid)
        var avail: int = 0
        if world.stock.has(cid) and world.stock[cid].has(pid):
            avail = int(world.stock[cid][pid]["qty"])
        var qty: int = int(m_qty_spin.value)
        var free_cap: int = max(0, int(world.player.get("cap", 0)) - int(world._cargo_used(world.player)))
        var size_u: int = int(world.products[pid].get("size", 1))
        var max_by_cap: int = int(free_cap / max(1, size_u))
        var max_by_cash: int = (int(floor(float(world.player.get("cash", 0.0)) / ask)) if ask > 0.0 else 0)
        var max_buy: int = max(0, min(avail, max_by_cap, max_by_cash))
        var carry: int = int(world.player.get("cargo", {}).get(pid, 0))
        txt += "[b]%s[/b]" % pname
        txt += "買: [b]%.1f[/b]  売: [b]%.1f[/b]" % [ask, bid]
        txt += "在庫: %d  / 最大購入可能: %d  / 手持ち: %d" % [avail, max_buy, carry]
        if qty > 0:
            var tax: float = float(bid) * float(qty) * float(world.trade_tax_rate)
            var est: float = float(qty) * (bid - ask) - tax
            txt += "\n仮益（同都市）: %.1f" % est
    if pid != "" and int(m_qty_spin.value) > 0 and world.has_method("_route_days") and world.has_method("_route_toll"):
        var pv_lines: Array = []
        var qtyp: int = int(m_qty_spin.value)
        var tcost: float = float(world.travel_cost_per_day)
        var taxr: float = float(world.trade_tax_rate)
        for dest in world.cities.keys():
            if String(dest) == cid: continue
            var d: int = int(world._route_days(cid, String(dest)))
            if d <= 0: continue
            var toll: float = float(world._route_toll(cid, String(dest)))
            var bid2: float = float(world.get_bid_price(String(dest), pid))
            var ask2: float = float(world.get_ask_price(cid, pid))
            var net: float = float(qtyp) * (bid2 * (1.0 - taxr) - ask2) - float(d) * tcost - toll
            var per_day: float = (net / float(d)) if d > 0 else 0.0
            pv_lines.append({"dest": String(dest), "days": d, "net": net, "per": per_day})
        pv_lines.sort_custom(func(a, b): return a["net"] > b["net"]) 
        var show_n: int = min(3, pv_lines.size())
        if show_n > 0:
            txt += "\n利益プレビュー:"
            for i in range(show_n):
                var rec = pv_lines[i]
                var dcity: String = String(rec["dest"])
                var dname: String = String(world.cities.get(dcity, {}).get("name", dcity))
                txt += "\n%s: %+0.1f (/日 %+0.1f, %d日)" % [dname, float(rec["net"]), float(rec["per"]), int(rec["days"])]
    m_info.text = txt

    var moving := bool(world.player.get("enroute", false))
    var disabled := moving
    m_buy_btn.disabled = disabled
    m_sell_btn.disabled = disabled

func _on_max() -> void:
    if world == null: return
    var pid: String = _cur_pid_market()
    if pid == "": m_qty_spin.value = 0; return
    var cid: String = String(world.player.get("city", ""))
    var ask: float = world.get_ask_price(cid, pid)
    var avail: int = 0
    if world.stock.has(cid) and world.stock[cid].has(pid):
        avail = int(world.stock[cid][pid]["qty"])
    var free_cap: int = max(0, int(world.player.get("cap", 0)) - int(world._cargo_used(world.player)))
    var size_u: int = int(world.products[pid].get("size", 1))
    var max_by_cap: int = int(free_cap / max(1, size_u))
    var max_by_cash: int = (int(floor(float(world.player.get("cash", 0.0)) / ask)) if ask > 0.0 else 0)
    var carry: int = int(world.player.get("cargo", {}).get(pid, 0))
    var target: int = (carry if carry > 0 else max(0, min(avail, max_by_cap, max_by_cash)))
    m_qty_spin.value = int(target)
    _market_refresh()

func _on_buy() -> void:
    if world == null: return
    var pid: String = _cur_pid_market()
    if pid == "": return
    var qty := int(m_qty_spin.value)
    if qty <= 0:
        _show_info_dialog("購入できません", "数量が 0 です。")
        return
    var cid: String = String(world.player.get("city", ""))
    var ask: float = world.get_ask_price(cid, pid)
    var avail: int = 0
    if world.stock.has(cid) and world.stock[cid].has(pid):
        avail = int(world.stock[cid][pid]["qty"])
    var free_cap: int = max(0, int(world.player.get("cap", 0)) - int(world._cargo_used(world.player)))
    var size_u: int = int(world.products[pid].get("size", 1))
    var need_cap: int = qty * max(1, size_u)
    var max_by_cap: int = int(free_cap / max(1, size_u))
    var max_by_cash: int = (int(floor(float(world.player.get("cash", 0.0)) / ask)) if ask > 0.0 else 0)

    if avail <= 0:
        _show_info_dialog("在庫なし", "この商品の在庫はありません。")
        return
    if qty > avail:
        _show_info_dialog("在庫不足", "要求数: %d / 在庫: %d" % [qty, avail])
        return
    if need_cap > free_cap:
        _show_info_dialog("積載容量不足", "必要容量: %d / 空き容量: %d" % [need_cap, free_cap])
        return
    if qty > max_by_cash:
        var need_cash := ask * float(qty)
        var have_cash := float(world.player.get("cash", 0.0))
        _show_info_dialog("所持金不足", "必要: %.1f / 所持: %.1f" % [need_cash, have_cash])
        return

    var ok: bool = world.player_buy(pid, qty)
    _on_world_updated()
    if not ok:
        _show_info_dialog("購入できません", "取引に失敗しました。")

func _on_sell() -> void:
    if world == null: return
    var pid: String = _cur_pid_market()
    if pid == "": return
    var ok: bool = world.player_sell(pid, int(m_qty_spin.value))
    _on_world_updated()
    if not ok:
        m_info.text += "\n[color=orange]売却できません[/color]"

func _on_product_selected(_i: int) -> void:
    # 商品リストを選んだ時の既定数量は 1。
    # 再描画中（_suppress_qty_reset=true）は値を触らない。
    if not _suppress_qty_reset:
        m_qty_spin.value = 1
    _market_refresh()

func _on_inventory_selected(i: int) -> void:
    var pid: String = String(m_inventory_list.get_item_metadata(i))
    for idx in range(m_product_list.item_count):
        if String(m_product_list.get_item_metadata(idx)) == pid:
            m_product_list.select(idx)
            break
    var carry: int = int(world.player.get("cargo", {}).get(pid, 0))
    m_qty_spin.value = max(1, carry)
    _market_refresh()

func _on_qty_changed(_v: float) -> void:
    _market_refresh()

func _consign_rebuild_list() -> void:
    if page_consign == null or world == null: return
    c_list.clear()
    var cargo := world.player.get("cargo", {}) as Dictionary
    var idx := 0
    for pid in cargo.keys():
        var q: int = int(cargo[pid])
        if q <= 0: continue
        var name: String = String(world.products.get(pid, {}).get("name", String(pid)))
        c_list.add_item("%s x%d" % [name, q])
        c_list.set_item_metadata(idx, String(pid))
        idx += 1

func _consign_selected_pid() -> String:
    if c_list == null or c_list.item_count <= 0: return ""
    var sel: PackedInt32Array = c_list.get_selected_items()
    if sel.is_empty(): return ""
    return String(c_list.get_item_metadata(sel[0]))

func _consign_selected_changed() -> void:
    var pid := _consign_selected_pid()
    var carry: int = int(world.player.get("cargo", {}).get(pid, 0))
    c_qty.value = min(carry, max(1, carry))
    _consign_refresh()

func _consign_refresh() -> void:
    if world == null or page_consign == null: return
    var pid := _consign_selected_pid()
    var txt := ""
    if pid != "":
        var name := String(world.products.get(pid, {}).get("name", String(pid)))
        var ask := float(world.get_ask_price(String(world.player.get("city", "")), pid))
        var qty := int(c_qty.value)
        var mult := 1.0
        var days := int(c_days.value)
        txt += "[b]%s[/b]" % name
        txt += "売値(都市): %.1f  日数: %d\n" % [ask, days]
        var gross := ask * float(qty)
        var tax := gross * float(world.trade_tax_rate)
        var commission := gross * float(world.stall_commission) if _has_prop(world, "stall_commission") else 0.0
        var fee := float(world.stall_fee_per_day) if _has_prop(world, "stall_fee_per_day") else 0.0
        var est := gross - tax - commission - fee
        txt += "概算日売上(最大): %.1f  概算純: %.1f" % [gross, est]
    c_info.text = txt

func _on_consign() -> void:
    if world == null: return
    var pid := _consign_selected_pid()
    if pid == "":
        _show_info_dialog("委託できません", "商品が選択されていません。")
        return
    var qty := int(c_qty.value)
    if qty <= 0:
        _show_info_dialog("委託できません", "数量が 0 です。")
        return
    var carry := int(world.player.get("cargo", {}).get(pid, 0))
    if qty > carry:
        _show_info_dialog("委託できません", "手持ちが不足しています。")
        return
    var cid: String = String(world.player.get("city", ""))
    var days := int(c_days.value)
    var mult := 1.0
    if world.has_method("consign"):
        var ok: bool = world.consign(cid, pid, qty, mult, days)
        if ok:
            _on_world_updated()
            _show_info_dialog("委託しました", "市場売値で %d日 間の委託を開始しました。" % [days])
        else:
            _show_info_dialog("委託できません", "条件を満たしていません。")

func _fair_refresh() -> void:
    if world == null or page_fair == null: return
    var cid: String = String(world.player.get("city", ""))
    var txt := ""
    var can := _is_fair_available_today()
    if can:
        var fee := 0.0
        var boost := 1.0
        var dur := 0
        if _has_prop(world, "fair_schedule"):
            var entries := world.fair_schedule.get(cid, []) as Array
            for e in entries:
                if int(e["start"]) == int(world.day):
                    fee = float(e["fee"])
                    boost = float(e["boost"])
                    dur = int(e["duration"])
                    break
        txt = "[b]%s[/b]\n本日開催中。参加料: %.1f  ブースト: x%.1f  期間: %d日" % [String(world.cities.get(cid, {}).get("name", cid)), fee, boost, dur]
    else:
        txt = "[b]%s[/b]\n現在開催中の市はありません。" % String(world.cities.get(cid, {}).get("name", cid))
    f_info.text = txt
    f_join_btn.disabled = not can

func _on_join_fair() -> void:
    if world == null: return
    var cid: String = String(world.player.get("city", ""))
    if world.has_method("join_fair"):
        var ok: bool = world.join_fair(cid)
        if ok:
            _show_info_dialog("参加しました", "本日の市に参加しました。")
        else:
            _show_info_dialog("参加できません", "本日は開催がないか、参加条件を満たしていません。")
    _fair_refresh()

func _is_fair_available_today() -> bool:
    if world == null: return false
    if not _has_prop(world, "enable_fairs") or not bool(world.enable_fairs):
        return false
    var cid: String = String(world.player.get("city", ""))
    if not _has_prop(world, "fair_schedule"): return false
    var entries := world.fair_schedule.get(cid, []) as Array
    for e in entries:
        if int(e["start"]) == int(world.day):
            return true
    return false

func _show_info_dialog(title_text: String, body_text: String) -> void:
    var dlg := AcceptDialog.new()
    dlg.title = title_text
    dlg.dialog_text = body_text
    add_child(dlg)
    dlg.popup_centered()
