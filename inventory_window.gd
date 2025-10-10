extends Window
class_name InvWindow

@export var world_path: NodePath
var world: World

# --- Visual tweaks (Inventory list) ---
@export var list_panel_color: Color = Color(0.19, 0.19, 0.19, 1.0)
@export var row_color_a: Color = Color(0.24, 0.24, 0.24, 1.0)
@export var row_color_b: Color = Color(0.21, 0.21, 0.21, 1.0)
@export var grid_line_color: Color = Color(1, 1, 1, 0.10)
@export var bid_net_of_tax: bool = true  # 売値を税引き後で表示

@onready var info_label: Label = $Margin/VBox/Info
@onready var header: HBoxContainer = $Margin/VBox/Header
@onready var rows_sc: ScrollContainer = $Margin/VBox/RowsSC
@onready var rows_box: VBoxContainer = $Margin/VBox/RowsSC/Rows
@onready var totals_label: Label = $Margin/VBox/Totals

func _ready() -> void:
    # World 取得
    if world_path != NodePath(""):
        world = get_node_or_null(world_path) as World
    if world == null:
        world = get_tree().root.find_child("World", true, false) as World

    # シーンに UI が無ければ動的構築
    if get_child_count() == 0:
        _build_ui()
    else:
        # 既存シーン（Margin）があればフルレクト化
        var m := get_node_or_null("Margin") as MarginContainer
        if m:
            m.set_anchors_preset(Control.PRESET_FULL_RECT)

    _rebuild()

func _build_ui() -> void:
    # フルレクト & 余白
    var margin := MarginContainer.new()
    margin.name = "Margin"
    margin.add_theme_constant_override("margin_left", 24)
    margin.add_theme_constant_override("margin_right", 24)
    margin.add_theme_constant_override("margin_top", 24)
    margin.add_theme_constant_override("margin_bottom", 24)
    add_child(margin)
    margin.set_anchors_preset(Control.PRESET_FULL_RECT)

    var vb := VBoxContainer.new()
    vb.size_flags_vertical = Control.SIZE_EXPAND_FILL
    vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    margin.add_child(vb)

    # 上部情報
    info_label = Label.new(); info_label.name = "Info"
    vb.add_child(info_label)

    # 見出し行（品名 / 個数 / 容量 / 売値 / 合計）
    header = HBoxContainer.new(); header.name = "Header"
    header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    vb.add_child(header)
    _add_header_label("品名", 2, HORIZONTAL_ALIGNMENT_LEFT)
    _add_header_label("個数", 1, HORIZONTAL_ALIGNMENT_RIGHT)
    _add_header_label("容量", 1, HORIZONTAL_ALIGNMENT_RIGHT)
    _add_header_label("売値", 1, HORIZONTAL_ALIGNMENT_RIGHT)
    _add_header_label("合計", 1, HORIZONTAL_ALIGNMENT_RIGHT)

    # ヘッダ下に薄い罫線
    var header_sep := ColorRect.new()
    header_sep.color = grid_line_color
    header_sep.custom_minimum_size = Vector2(0, 1)
    vb.add_child(header_sep)

    # スクロール + 行ボックス（画面いっぱいに広げる）
    rows_sc = ScrollContainer.new(); rows_sc.name = "RowsSC"
    rows_sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
    rows_sc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    vb.add_child(rows_sc)

    # リスト背景用のパネル（視認性向上）
    var list_panel := PanelContainer.new(); list_panel.name = "RowsPanel"
    var sb_panel := StyleBoxFlat.new(); sb_panel.bg_color = list_panel_color
    sb_panel.corner_radius_top_left = 6
    sb_panel.corner_radius_top_right = 6
    sb_panel.corner_radius_bottom_left = 6
    sb_panel.corner_radius_bottom_right = 6
    # リスト内側に左右の余白（コンテンツパディング）
    sb_panel.set_content_margin(SIDE_LEFT, 12)
    sb_panel.set_content_margin(SIDE_RIGHT, 12)
    sb_panel.set_content_margin(SIDE_TOP, 6)
    sb_panel.set_content_margin(SIDE_BOTTOM, 6)
    list_panel.add_theme_stylebox_override("panel", sb_panel)
    list_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    list_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
    rows_sc.add_child(list_panel)

    rows_box = VBoxContainer.new(); rows_box.name = "Rows"
    rows_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    list_panel.add_child(rows_box)

    # リスト下に薄い罫線
    var list_sep := ColorRect.new()
    list_sep.color = grid_line_color
    list_sep.custom_minimum_size = Vector2(0, 1)
    vb.add_child(list_sep)

    # 下部トータル
    totals_label = Label.new(); totals_label.name = "Totals"
    vb.add_child(totals_label)

    # タイトルバーの×で閉じる想定。内部 Close ボタンは無し。

func _add_header_label(text: String, ratio: float, align: int) -> void:
    var l := Label.new(); l.text = text
    l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    l.size_flags_stretch_ratio = ratio
    l.horizontal_alignment = align
    header.add_child(l)

func _add_row(name: String, qty: int, size: int, bid: float, total: float) -> void:
    # 交互背景の行パネル
    var idx: int = rows_box.get_child_count()
    var row_panel := PanelContainer.new()
    var sb := StyleBoxFlat.new()
    sb.bg_color = (row_color_a if (idx % 2 == 0) else row_color_b)
    sb.border_color = grid_line_color
    if idx > 0:
        sb.border_width_top = 1
    row_panel.add_theme_stylebox_override("panel", sb)
    row_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    rows_box.add_child(row_panel)

    var hb := HBoxContainer.new()
    hb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    row_panel.add_child(hb)

    var c1 := Label.new(); c1.text = name
    c1.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    c1.size_flags_stretch_ratio = 2
    c1.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
    hb.add_child(c1)

    var c2 := Label.new(); c2.text = str(qty)
    c2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    c2.size_flags_stretch_ratio = 1
    c2.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
    hb.add_child(c2)

    var cap_used: int = qty * max(1, size)
    var ccap := Label.new(); ccap.text = str(cap_used)
    ccap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    ccap.size_flags_stretch_ratio = 1
    ccap.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
    hb.add_child(ccap)

    var c3 := Label.new(); c3.text = str(roundf(bid * 10.0) / 10.0)
    c3.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    c3.size_flags_stretch_ratio = 1
    c3.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
    hb.add_child(c3)

    var c4 := Label.new(); c4.text = str(roundf(total * 10.0) / 10.0)
    c4.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    c4.size_flags_stretch_ratio = 1
    c4.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
    hb.add_child(c4)

func _rebuild() -> void:
    if world == null:
        return
    # ヘッダ情報
    var cap := int(world.player.get("cap", 0))
    var used := _capacity_used()
    var cash := float(world.player.get("cash", 0.0))
    info_label.text = "Capacity: %d / %d   Cash: %.1f" % [used, cap, cash]

    # 一覧描画
    for n in rows_box.get_children():
        n.queue_free()

    var city := String(world.player.get("city", ""))
    var cargo := world.player.get("cargo", {}) as Dictionary
    var total_value: float = 0.0
    for pid in cargo.keys():
        var qty: int = int(cargo[pid])
        if qty <= 0:
            continue
        var name := String(world.products.get(pid, {}).get("name", pid))
        var size: int = int(world.products.get(pid, {}).get("size", 1))
        var bid := _get_bid(city, pid)
        var sum := bid * float(qty)
        total_value += sum
        _add_row(name, qty, size, bid, sum)

    totals_label.text = "合計価値: %.1f" % total_value

func _capacity_used() -> int:
    var total := 0
    var cargo := world.player.get("cargo", {}) as Dictionary
    for pid in cargo.keys():
        var qty: int = int(cargo[pid])
        var size: int = 1
        if world.products.has(pid):
            size = int(world.products[pid].get("size", 1))
        total += qty * size
    return total

func _get_bid(city: String, pid: String) -> float:
    var v: float
    if world and world.has_method("get_bid_price"):
        v = float(world.call("get_bid_price", city, pid))
    else:
        var base := 0.0
        if world and world.products.has(pid):
            base = float(world.products[pid].get("base", 0.0))
        v = float(world.price.get(city, {}).get(pid, base))
    if bid_net_of_tax:
        v *= (1.0 - float(world.trade_tax_rate))
    return v
