extends Window
class_name MoveWindow
## プレイヤーの移動先を選ぶ小窓（隣接都市リスト）
signal travel_confirmed(origin: String, dest: String, days: int, path: Array)

var world: World

# UI
var _list: ItemList
var _info: Label
var _detail: Label
var _depart_btn: Button
var _close_btn: Button



var _confirm_dlg: ConfirmationDialog = null
var _click_guard_until: int = 0
var _suppress_confirm_once: bool = false



func _close_confirm_if_any() -> void:
    if is_instance_valid(_confirm_dlg):
        _confirm_dlg.queue_free()
    _confirm_dlg = null


func _ready() -> void:
    title = "Move"
    unresizable = true
    size = Vector2i(420, 320)
    min_size = Vector2i(360, 260)
    set_process_unhandled_input(true)
    close_requested.connect(func(): hide())

    # 動的にUI構築
    var margin := MarginContainer.new()
    margin.add_theme_constant_override("margin_left", 12)
    margin.add_theme_constant_override("margin_right", 12)
    margin.add_theme_constant_override("margin_top", 12)
    margin.add_theme_constant_override("margin_bottom", 12)
    add_child(margin)

    var vb := VBoxContainer.new()
    vb.size_flags_vertical = Control.SIZE_EXPAND_FILL
    margin.add_child(vb)

    _info = Label.new()
    vb.add_child(_info)

    _detail = Label.new()
    _detail.autowrap_mode = TextServer.AUTOWRAP_WORD
    _detail.add_theme_color_override("font_color", Color(0.9,0.9,0.9))
    vb.add_child(_detail)

    _list = ItemList.new()
    _list.size_flags_vertical = Control.SIZE_EXPAND_FILL
    _list.allow_reselect = true
    vb.add_child(_list)

    var row := HBoxContainer.new()
    vb.add_child(row)

    _depart_btn = Button.new()
    _depart_btn.text = "Depart"
    _depart_btn.disabled = true
    row.add_child(_depart_btn)

    _close_btn = Button.new()
    _close_btn.text = "Close"
    row.add_child(_close_btn)

    # 信号
    _list.item_selected.connect(_on_selected)
    _depart_btn.pressed.connect(_on_depart)
    _close_btn.pressed.connect(func(): hide())

    _update_text()
    call_deferred("_late_wire")

func _late_wire() -> void:
    if world == null:
        var w := get_tree().root.find_child("World", true, false)
        if w and w is World:
            world = w
    if world and not world.world_updated.is_connected(Callable(self, "_rebuild")):
        world.world_updated.connect(_rebuild)
    _rebuild()
    if _list.get_item_count() > 0:
       _suppress_confirm_once = true
       _list.select(0)
       _on_selected(0)
func _unhandled_input(e: InputEvent) -> void:
    if e.is_action_pressed("ui_cancel"):
        hide()
        get_viewport().set_input_as_handled()

func _update_text() -> void:
    var city: String = "?"
    if world:
        city = String(world.player.get("city", "?"))
    _info.text = "Current: %s" % city

func _rebuild() -> void:
    _list.clear()
    _depart_btn.disabled = true
    if world == null:
        _update_text()
        return
    var p := world.player
    var city: String = String(p.get("city", ""))
    _update_text()
    if city == "" or not world.adj.has(city):
        return

    # Build entries with province & name for sorting
    var entries: Array = []
    for nb in (world.adj[city] as Array):
        var nbid: String = String(nb)
        if not world.cities.has(nbid):
            continue
        var cmeta: Dictionary = world.cities[nbid]
        var province := String(cmeta.get("province", ""))
        var name := String(cmeta.get("name", nbid))
        var days: int = world._route_days(city, nbid)
        var toll: float = world._route_toll(city, nbid)
        var travel_cost: float = world.travel_cost_per_day * float(days)
        var hazard: float = _hazard_for(city, nbid)
        entries.append({
            "cid": nbid,
            "province": province,
            "name": name,
            "days": days,
            "toll": toll,
            "travel_cost": travel_cost,
            "hazard": hazard
        })

    # Sort by province, then name (ascending, case-insensitive-ish)
    entries.sort_custom(Callable(self, "_sort_city_entry"))

    for e in entries:
        var label := "%s / %s" % [String(e["province"]), String(e["name"])]
        var idx := _list.add_item(label)
        _list.set_item_metadata(idx, e)
    _detail.text = ""

    if entries.size() > 0:
        _list.select(0)
        _on_selected(0)

 

func _open_confirm_for(cid: String, use_path: Array = []) -> void:
    if world == null or cid == "":
        return
    var origin: String = String(world.player.get("city", ""))
    var days: int = 0
    var travel_cost: float = 0.0
    var toll: float = 0.0
    var path: Array[String] = []
    if world and world.has_method("compute_path"):
        var res: Dictionary = world.compute_path(origin, cid, "fastest")
        path = res.get("path", [])
        if path.size() >= 2:
            days = int(res.get("days", 0))
            travel_cost = float(res.get("travel_cost", world.travel_cost_per_day * float(days)))
            if world.pay_toll_on_depart:
                toll = float(res.get("toll", 0.0))
            else:
                toll = 0.0
        else:
            # no path found
            var err := AcceptDialog.new()
            err.title = "行けません"
            err.dialog_text = "その都市へ通じる道がありません。"
            add_child(err)
            err.popup_centered()
            return
    else:
        days = world._route_days(origin, cid)
        travel_cost = world.travel_cost_per_day * float(days)
        if world.pay_toll_on_depart:
            toll = float(world._route_toll(origin, cid))
        else:
            toll = 0.0

    var total: float = travel_cost + toll
    var cash: float = float(world.player.get("cash", 0.0))

    var dest_name: String = cid
    var origin_name: String = origin
    if world.cities.has(cid):
        dest_name = String(world.cities[cid].get("name", cid))
    if world.cities.has(origin):
        origin_name = String(world.cities[origin].get("name", origin))

    var hazard: float = 0.0
    if has_method("_hazard_for"):
        hazard = _hazard_for(origin, cid)

    # 既存の確認ダイアログが可視なら重複生成しない
    if is_instance_valid(_confirm_dlg) and _confirm_dlg.visible:
        _confirm_dlg.grab_focus()
        return
    # 壊れている/閉じた参照を掃除
    if is_instance_valid(_confirm_dlg) and not _confirm_dlg.visible:
        _confirm_dlg.queue_free()
        _confirm_dlg = null

    var dlg: ConfirmationDialog = ConfirmationDialog.new()
    _confirm_dlg = dlg
    dlg.title = "移動の確認"

    var text: String = "次の都市へ移動しますか？\n"
    text += "%s → %s\n" % [origin_name, dest_name]
    text += "日数: %d\n" % days
    text += "旅費: %.1f\n" % travel_cost
    text += "通行料: %.1f\n" % toll
    text += "危険度: %.2f\n" % hazard
    text += "――――――――――\n"
    text += "合計: %.1f\n" % total
    text += "所持金: %.1f" % cash
    dlg.dialog_text = text

    add_child(dlg)
    if dlg.get_ok_button():
        dlg.get_ok_button().text = "移動する"
    if dlg.get_cancel_button():
        dlg.get_cancel_button().text = "やめる"

    dlg.canceled.connect(func():
        _close_confirm_if_any()
    )

    dlg.confirmed.connect(func():
        var res_ok := false

        if world and world.has_method("player_move_via") and (path.size() >= 2 or use_path.size() >= 2):
            var p2: Array = []
            if use_path.size() >= 2:
                p2 = use_path
            else:
                p2 = path
            # 資金チェックと同日到着チェックはHUD準拠
            var arrived_today := int(world.player.get("last_arrival_day", -999)) == world.day
            if (not arrived_today) and cash >= total:
                res_ok = world.player_move_via(cid, p2)
        else:
            var r := world.can_player_move_to(cid)
            if bool(r.get("ok", false)):
                res_ok = world.player_move(cid)

        if res_ok:
            # ★ここでHUDに「自動移動開始」を依頼する
            var root := get_tree().root
            var hud := root.find_child("GameHUD", true, false)
            if hud and hud.has_method("start_auto_travel"):
                hud.start_auto_travel()
            hide()
        else:
            var err := AcceptDialog.new()
            err.title = "移動できません"
            err.dialog_text = "出発できませんでした。"
            add_child(err)
            err.popup_centered()
    )

    dlg.popup_centered()



func _on_selected(_i: int) -> void:

    # 既存の確認ダイアログが可視かつ同じ選択なら何もしない
    if is_instance_valid(_confirm_dlg) and _confirm_dlg.visible:
        _confirm_dlg.grab_focus()
        return

    # 行選択に応じて明細を更新（"entries" は参照しない）
    var sel: Array = _list.get_selected_items()
    if sel.is_empty():
        _detail.text = ""

    if _suppress_confirm_once:
        _suppress_confirm_once = false
        return
    var e2 := _list.get_item_metadata(int(_list.get_selected_items()[0])) as Dictionary
    var cid2: String = String(e2.get("cid", ""))
    if cid2 != "":
        _open_confirm_for(cid2)
        _depart_btn.disabled = true
        return
    _depart_btn.disabled = false
    var idx: int = int(sel[0])
    var e: Dictionary = _list.get_item_metadata(idx)
    if e.is_empty():
        _detail.text = ""
        _depart_btn.disabled = true
        return
    var origin: String = "?"
    if world:
        origin = String(world.player.get("city", ""))

    var days: int = int(e.get("days", 0))
    var travel_cost: float = float(e.get("travel_cost", 0.0))
    var toll: float = float(e.get("toll", 0.0))
    var hazard: float = float(e.get("hazard", 0.0))
    var total: float = travel_cost
    if world and world.pay_toll_on_depart:
        total += float(world._route_toll(origin, String(e.get("cid",""))))
    _detail.text = "日数: %d   旅費: %.1f   通行料: %.1f   危険度: %.2f   合計: %.1f" % [days, travel_cost, toll, hazard, total]

func _on_depart() -> void:
    if world == null:
        return
    var sel := _list.get_selected_items()
    if sel.is_empty():
        return
    var idx: int = sel[0]
    var meta := _list.get_item_metadata(idx) as Dictionary
    var dest: String = String(meta.get("cid", ""))
    if dest == "":
        return

    var origin := String(world.player.get("city", ""))
    var arrived_today := int(world.player.get("last_arrival_day", -999)) == world.day
    var adjacent := world.adj.has(origin) and (dest in (world.adj[origin] as Array))
    var days := world._route_days(origin, dest)
    var travel_cost := world.travel_cost_per_day * float(days)
    var toll := 0.0
    if world.pay_toll_on_depart:
        toll = float(world._route_toll(origin, dest))
    var total := travel_cost + toll
    var cash := float(world.player.get("cash", 0.0))

    var ok := false
    if arrived_today:
        ok = false
    elif not adjacent:
        ok = false
    elif cash < total:
        ok = false
    else:
        ok = world.player_move(dest)

    if ok:
        hide()  # 成功時のみ閉じる
    else:
        var msg := ""
        if arrived_today:
            msg = "本日は到着日のため出発できません。\n翌日以降にもう一度お試しください。"
        elif not adjacent:
            msg = "その都市は隣接していません。"
        elif cash < total:
            msg = "資金が不足しています。\n必要: %.1f / 所持: %.1f" % [total, cash]
        else:
            msg = "出発できませんでした。"
        var dlg := AcceptDialog.new()
        dlg.title = "移動できません"
        dlg.dialog_text = msg
        add_child(dlg)
        dlg.popup_centered()


func _sort_city_entry(a: Dictionary, b: Dictionary) -> bool:
    var ak := String(a.get("province","")) + "|" + String(a.get("name",""))
    var bk := String(b.get("province","")) + "|" + String(b.get("name",""))
    return ak.nocasecmp_to(bk) < 0

func _hazard_for(a: String, b: String) -> float:
    # 1. worldの存在チェック
    if world == null:
        return 0.0

    # 2. worldに専用のハザード計算メソッドがあるかチェック（優先）
    if world.has_method("_route_hazard"):
        # has_method() は Godot 4 の正しい書き方です
        return float(world._route_hazard(a, b))

    # 3. worldにハザードマッププロパティがあるかチェック
    # has_property() または "key" in object が Godot 4 の標準です
    var _hm = world.get("route_hazard_map")
    if _hm is Dictionary:
        # 3a. ルートキーの生成（必ずアルファベット順にする）
        var k: String
        if a < b:
            k = a + "-" + b
        else:
            k = b + "-" + a
            
        # 3b. マップから値を取得し、floatに変換して返す
        # .get(key, default_value) は安全なアクセス方法です
        # (world.route_hazard_map が Dictionary であることを想定)
        return float(_hm.get(k, 0.0))
        
    # 4. どの情報も見つからない場合のデフォルト値
    return 0.0
