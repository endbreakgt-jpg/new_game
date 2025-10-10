extends Window

var world: World
var _list: ItemList
var _depart_btn: Button

func _ready() -> void:
    title = "Move"
    unresizable = false
    var vb := VBoxContainer.new()
    add_child(vb)
    _list = ItemList.new()
    _list.select_mode = ItemList.SELECT_SINGLE
    vb.add_child(_list)
    var hb := HBoxContainer.new()
    vb.add_child(hb)
    _depart_btn = Button.new()
    _depart_btn.text = "出発"
    hb.add_child(_depart_btn)
    _depart_btn.pressed.connect(_on_depart)
    _refresh()

func _refresh() -> void:
    if world == null:
        return
    _list.clear()
    var city: String = String(world.player.get("city", ""))
    if not world.adj.has(city):
        return
    for nb in (world.adj[city] as Array):
        var days := world._route_days(city, nb)
        var toll := (float(world._route_toll(city, nb)) if world.pay_toll_on_depart else 0.0)
        _list.add_item("%s (%d日, 通行料=%.1f)" % [nb, days, toll])
        _list.set_item_metadata(_list.item_count - 1, nb)

func _on_depart() -> void:
    if world == null:
        return
    var sel := _list.get_selected_items()
    if sel.is_empty():
        return
    var idx: int = sel[0]
    var dest: String = String(_list.get_item_metadata(idx))
    if dest == "":
        return

    var res := world.can_player_move_to(dest)
    if bool(res.get("ok", false)):
        if world.player_move(dest):
            hide()  # 成功時のみ閉じる
        return

    var msg := ""
    var need := float(res.get("need", 0.0))
    var cash := float(world.player.get("cash", 0.0))
    match int(res.get("err", -1)):
        World.MoveErr.ARRIVED_TODAY:
            msg = "本日は到着日のため出発できません。\n翌日以降にもう一度お試しください。"
        World.MoveErr.NOT_ADJACENT:
            msg = "その都市は隣接していません。"
        World.MoveErr.LACK_CASH:
            msg = "資金が不足しています。\n必要: %.1f / 所持: %.1f" % [need, cash]
        _:
            msg = "出発できませんでした。"
    var dlg := AcceptDialog.new()
    dlg.title = "移動できません"
    dlg.dialog_text = msg
    add_child(dlg)
    dlg.popup_centered()
