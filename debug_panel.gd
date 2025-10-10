extends PanelContainer
class_name DebugPanel

@export var world_path: NodePath
@export var default_city: String = ""
@export var default_product: String = ""

var world: World = null
var _ob_city: OptionButton
var _ob_prod: OptionButton
var _val_mid: Label
var _val_spread: Label
var _val_shortage: Label

func _ready() -> void:
    _setup_anchor()
    _build_ui()
    if world_path != NodePath(""):
        world = get_node_or_null(world_path) as World
    else:
        var parent := get_parent()
        if parent:
            world = parent.get_node_or_null("World") as World
        if world == null and get_tree().root:
            world = get_tree().root.get_node_or_null("World") as World
    _populate_options()
    _update_stats()

func _refresh_from_world() -> void:
    _populate_options()
    _update_stats()

func _setup_anchor() -> void:
    name = "DebugPanel"
    # 親が Window ならフルレクト、HUD直下なら右上固定
    if get_parent() is Window:
        set_anchors_preset(Control.PRESET_FULL_RECT)
        offset_left = 8; offset_top = 8; offset_right = -8; offset_bottom = -8
        self.visible = true   # ★ Window内では可視
    else:
        anchor_left = 1.0; anchor_right = 1.0; anchor_top = 0.0; anchor_bottom = 0.0
        offset_left = -420; offset_right = -12; offset_top = 12; offset_bottom = 0
        self.visible = false  # ★ HUD内ではデフォルト非表示

func _build_ui() -> void:
    add_theme_constant_override("panel", 8)
    var vb := VBoxContainer.new()
    vb.custom_minimum_size = Vector2(360, 0)
    add_child(vb)

    var title := Label.new()
    title.text = "Debug: Price/Spread/Shortage"
    title.add_theme_font_size_override("font_size", 14)
    vb.add_child(title)

    var sel := HBoxContainer.new()
    vb.add_child(sel)

    sel.add_child(_mk_label("City", 10, 70))
    _ob_city = OptionButton.new()
    _ob_city.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _ob_city.item_selected.connect(_on_any_changed)
    sel.add_child(_ob_city)

    sel.add_child(_mk_label("Product", 10, 70))
    _ob_prod = OptionButton.new()
    _ob_prod.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _ob_prod.item_selected.connect(_on_any_changed)
    sel.add_child(_ob_prod)

    var grid := GridContainer.new()
    grid.columns = 2
    grid.add_theme_constant_override("h_separation", 8)
    grid.add_theme_constant_override("v_separation", 4)
    vb.add_child(grid)

    grid.add_child(_mk_label("Mid", 12, 120))
    _val_mid = _mk_value_label(); grid.add_child(_val_mid)

    grid.add_child(_mk_label("Spread", 12, 120))
    _val_spread = _mk_value_label(); grid.add_child(_val_spread)

    grid.add_child(_mk_label("Shortage (EMA)", 12, 120))
    _val_shortage = _mk_value_label(); grid.add_child(_val_shortage)

func _mk_label(t: String, size: int, minw: int) -> Label:
    var l := Label.new()
    l.text = t
    l.custom_minimum_size = Vector2(minw, 0)
    l.add_theme_font_size_override("font_size", size)
    return l

func _mk_value_label() -> Label:
    var l := Label.new()
    l.text = "-"
    l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
    l.custom_minimum_size = Vector2(120, 0)
    return l

func _populate_options() -> void:
    _ob_city.clear()
    _ob_prod.clear()
    if world == null:
        return

    # Cities
    var cities: Dictionary = world.cities
    var keys: Array = cities.keys()
    keys.sort()
    for cid_any in keys:
        var cid: String = String(cid_any)
        var name: String = String((cities[cid] as Dictionary).get("name", cid))
        var idx: int = _ob_city.get_item_count()
        _ob_city.add_item("%s (%s)" % [name, cid])
        _ob_city.set_item_metadata(idx, cid)

    # Products
    var products: Dictionary = world.products
    var keys_p: Array = products.keys()
    keys_p.sort()
    for pid_any in keys_p:
        var pid: String = String(pid_any)
        var namep: String = String((products[pid] as Dictionary).get("name", pid))
        var idxp: int = _ob_prod.get_item_count()
        _ob_prod.add_item("%s (%s)" % [namep, pid])
        _ob_prod.set_item_metadata(idxp, pid)

    # select defaults if provided
    if default_city != "":
        for i in range(_ob_city.get_item_count()):
            if String(_ob_city.get_item_metadata(i)) == default_city:
                _ob_city.select(i); break
    if default_product != "":
        for j in range(_ob_prod.get_item_count()):
            if String(_ob_prod.get_item_metadata(j)) == default_product:
                _ob_prod.select(j); break

func _on_any_changed(_idx: int) -> void:
    _update_stats()

func _sel_city() -> String:
    var idx: int = _ob_city.get_selected()
    if idx >= 0 and idx < _ob_city.get_item_count():
        return String(_ob_city.get_item_metadata(idx))
    return ""

func _sel_prod() -> String:
    var idx: int = _ob_prod.get_selected()
    if idx >= 0 and idx < _ob_prod.get_item_count():
        return String(_ob_prod.get_item_metadata(idx))
    return ""

func _update_stats() -> void:
    var cid: String = _sel_city()
    var pid: String = _sel_prod()
    if cid == "" or pid == "" or world == null:
        _val_mid.text = "-"
        _val_spread.text = "-"
        _val_shortage.text = "-"
        return

    var mid: float = 0.0
    var spread_abs: float = 0.0
    var shortage: float = 0.0

    # Mid price
    if world.has_method("get_mid_price"):
        mid = float(world.get_mid_price(cid, pid))
    else:
        if world.price.has(cid) and (world.price[cid] as Dictionary).has(pid):
            mid = float((world.price[cid] as Dictionary)[pid])

    # Spread (absolute, not fraction)
    if world.has_method("_spread_for"):
        var sp_frac: float = float(world._spread_for(cid, pid))
        spread_abs = mid * sp_frac
    else:
        spread_abs = mid * float(world.spread_base)

    # Shortage EMA
    if world._shortage_ema.has(cid):
        var row: Dictionary = world._shortage_ema[cid] as Dictionary
        if row.has(pid):
            shortage = float(row[pid])

    # Present
    _val_mid.text = "%.2f" % mid
    var pct: float = 0.0
    if mid > 0.0:
        pct = (spread_abs / mid) * 100.0
    _val_spread.text = "±%.2f (%.1f%%)" % [spread_abs, pct]
    _val_shortage.text = "%.2f" % shortage
