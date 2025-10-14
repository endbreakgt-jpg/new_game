# === OFFICIAL CANVAS ===
# World.gd (res://scripts/world.gd)
# このキャンバスを唯一の最新版として使用します。重複キャンバスはアーカイブ対象。

extends Node2D
class_name World

signal day_advanced(day: int)
signal world_updated()
signal supply_event(city_id: String, product_id: String, qty: int, mode: String, flavor: String)

@export var data_dir: String = "res://data/"
@export var day_seconds: float = 0.5

# 価格ダイナミクス
@export var price_k: float = 0.25
@export var min_mult: float = 0.5
@export var max_mult: float = 2.0
# スプレッド設定（買値/売値の差）
@export var spread_base: float = 0.10   # 平常時スプレッド（±5% = 計10%）
@export var spread_k: float = 0.10      # 在庫不足で上乗せ
@export var min_spread: float = 0.04    # 下限
@export var max_spread: float = 0.30    # 上限

# 経済コスト
@export var travel_cost_per_day: float = 2.0     # 出発時に（日数×この額）
@export var trade_tax_rate: float = 0.03         # 売上税（販売都市の金庫へ）
@export var events_daily_file: String = "events_daily.csv"   # 日時イベントテーブル（CSV）
@export var events_travel_file: String = "events_travel.csv" # 道中イベントテーブル（CSV）
@export var pay_toll_on_depart: bool = true      # 出発時に通行料を支払う（両端都市に折半）
@export var depart_same_day: bool = false      # 到着日に再出発しない（方針）

# ヒストリ＆速度
@export var history_days: int = 60               # 価格の記録日数
var _speed_mult: float = 1.0                     # 速度倍率（1x/2x/4x）

var day: int = 0

# データ
var products: Dictionary = {}         # pid -> {"name": String, "base": float, "size": int}
var cities: Dictionary = {}           # cid -> {"name": String, "province": String, "note": String, "funds": float}
var routes: Array[Dictionary] = []    # [{"from": String, "to": String, "days": int, "toll": float}]
var adj: Dictionary = {}              # cid -> Array[String]
var stock: Dictionary = {}            # city_id -> pid -> {"qty": float, "target": float, "prod": float, "cons": float}
var price: Dictionary = {}            # city_id -> pid -> float
var history: Dictionary = {}          # city_id -> pid -> Array[float]
var traders: Array[Dictionary] = []   # list of traders
# --- dynamics & logs (added) ---
@export var year_days: int = 360                     # 供給の季節サイクル長（ゲーム内日数）
# 供給ルール（A案：スタンダード）
var supply_rules: Dictionary = {
    # 季節・バーストを薄め頻度で多品目に拡張（A案：控えめ、長期テスト向け）
    "PR03": {"mode":"seasonal_burst", "p_base":0.010, "qty_min":6,  "qty_max":14, "amp":0.5},  # 魚介：豊漁期
    "PR05": {"mode":"seasonal_burst", "p_base":0.006, "qty_min":4,  "qty_max":12, "amp":0.6},  # 香辛料：季節便
    "PR10": {"mode":"burst",          "p_base":0.003, "qty_min":1,  "qty_max":2},              # 宝飾：希少
    "PR11": {"mode":"burst",          "p_base":0.008, "qty_min":4,  "qty_max":10},             # 油：隊商入荷
    "PR12": {"mode":"seasonal_burst", "p_base":0.008, "qty_min":3,  "qty_max":8,  "amp":0.4}, # チーズ：季節差
    "PR13": {"mode":"seasonal_burst", "p_base":0.010, "qty_min":5,  "qty_max":12, "amp":0.5}, # ワイン：収穫期
    "PR14": {"mode":"seasonal_burst", "p_base":0.006, "qty_min":6,  "qty_max":14, "amp":0.5}, # 羊毛：剪毛期
    "PR15": {"mode":"burst",          "p_base":0.007, "qty_min":4,  "qty_max":10},             # 皮革：ロット入荷
    "PR16": {"mode":"burst",          "p_base":0.006, "qty_min":2,  "qty_max":6},              # 染料：小ロット
    "PR17": {"mode":"seasonal_burst", "p_base":0.009, "qty_min":4,  "qty_max":10, "amp":0.5}, # 茶：季節便
    "PR18": {"mode":"burst",          "p_base":0.007, "qty_min":5,  "qty_max":12}              # 紙：束入荷
}


var shortage_alpha: float = 0.3              # 不足EMAの係数 (0..1)
var event_log_max: int = 50                  # イベントログ最大件数（HUDで表示するなら）
var _shortage_ema: Dictionary = {}           # city_id -> pid -> EMA(shortage)
var event_log: Array[String] = []            # 直近イベントログ
var _events_daily: Array[Dictionary] = []    # 日時イベントテーブル
var _events_travel: Array[Dictionary] = []   # 道中イベントテーブル
var _effects_active: Array[Dictionary] = []  # 効果レイヤ（kind, target_city, target_pid, price_mult, tax_delta, remain, src_id）

# 供給イベント頻度コントロール（クールダウン＆上限）
@export var supply_cooldown_min_days: int = 12      # 直近イベントからこの日数は発生しない
@export var supply_cooldown_ramp_days: int = 12     # クール明けの確率を徐々に戻す日数
@export var supply_daily_cap: int = 3               # 1日に起きる供給イベントの最大件数（世界全体）
@export var supply_skip_when_above_ratio: float = 1.4  # 在庫/目標がこの比率以上ならスキップ（豊富すぎる時は入荷しない）
var _last_supply_day: Dictionary = {}               # city_id -> pid -> last_day

# --- Debug / Stats & Seasonal gates ---
@export var supply_debug_boost_enable: bool = true
@export var supply_debug_boost: float = 1.35                 # デバッグ時の発火確率ブースト
@export var log_each_supply_event: bool = true              # 1件ごとのログ出力を抑制（デフォルトOFF）
@export var log_daily_supply_count: bool = true              # 日次件数のみログ出力

@export var log_event_dice: bool = true                    # イベントダイスのデバッグ出力（ON/OFF）
@export var log_event_dice_verbose: bool = false           # さらに詳細（重み一覧など）

# ルート危険度と護衛による重み補正（道中イベント用）
@export var travel_bad_weight_per_hazard: float = 0.6      # 危険度1.0で悪イベント重み +60%
@export var travel_bad_weight_per_escort: float = -0.4     # 護衛Lv1で悪イベント重み -40%
@export var travel_good_weight_per_hazard: float = -0.2    # 危険度で良イベントはやや減
@export var travel_good_weight_per_escort: float = 0.3     # 護衛で良イベントはやや増
@export var route_hazard_map: Dictionary = {}               # 例: { "RE0004-RE0005": 0.6, "RE0002-RE0003": 0.2 }

# 月別・季節別の係数（枠組み）
@export var monthly_supply_mult: Array = [
    0.85, # 1月（冬：やや少なめ）
    0.85, # 2月（冬）
    1.00, # 3月（春）
    1.00, # 4月（春）
    1.00, # 5月（春）
    1.00, # 6月（夏）
    1.00, # 7月（夏）
    1.00, # 8月（夏）
    1.25, # 9月（秋：やや多め）
    1.25, # 10月（秋）
    1.25, # 11月（秋）
    0.85  # 12月（冬）
]
@export var season_supply_mult: Dictionary = {
    "spring": 1.00,
    "summer": 1.00,
    "autumn": 1.10,
    "winter": 0.92
}

# デバッグ用カウンタ
var supply_count_today: int = 0
var supply_count_total: int = 0
var supply_count_by_month: Dictionary = {}   # "YYYY-MM" -> int
var supply_count_by_city: Dictionary = {}    # city_id -> int
var supply_count_by_pid: Dictionary = {}     # pid -> int


var _loader: CsvLoader
var _timer: Timer
var _paused: bool = false

# -------- utils --------
func _num(x) -> float:
    var s: String = str(x)
    s = s.replace("�", "").replace("，", "").replace(",", "")
    s = s.replace("．", ".").replace("－", "-")
    var fw := "０１２３４５６７８９"
    for i in range(10):
        s = s.replace(fw.substr(i, 1), str(i))
    s = s.strip_edges()
    if s == "":
        return 0.0
    if s.is_valid_float():
        return s.to_float()
    if s.is_valid_int():
        return float(s.to_int())
    var acc := ""
    for ch in s:
        if "0123456789.-".find(ch) != -1:
            acc += ch
    return acc.to_float() if acc != "" else 0.0

# -------- lifecycle --------
func _ready() -> void:
    randomize()
    _loader = CsvLoader.new()
    add_child(_loader)
    load_data()
    build_graph()
    update_prices()
    init_traders()
    init_player()

    _timer = Timer.new()
    _timer.wait_time = day_seconds
    _timer.one_shot = false
    _timer.autostart = false      # 起動時はタイマー停止（手動進行がデフォルト）
    add_child(_timer)
    _timer.timeout.connect(_on_day_tick)
    set_speed(1.0)

    _paused = true                # 起動時はポーズ

    _log("World ready. Cities=%d, Products=%d, Routes=%d" % [cities.size(), products.size(), routes.size()])
    world_updated.emit()

func set_speed(m: float) -> void:
    _speed_mult = clamp(m, 0.25, 8.0)
    if _timer:
        _timer.wait_time = day_seconds / _speed_mult

func _on_day_tick() -> void:
    if _paused:
        return
    step_one_day()

func pause() -> void:
    _paused = true
    if _timer:
        _timer.stop()

func resume() -> void:
    _paused = false
    if _timer:
        _timer.start()

func is_paused() -> bool:
    return _paused

# 日の進行度（0.0〜1.0）
func get_day_progress() -> float:
    if _paused or _timer == null or _timer.wait_time <= 0.0:
        return 0.0
    var tl: float = _timer.time_left
    var wt: float = _timer.wait_time
    var prog: float = 1.0 - (tl / wt)
    return clamp(prog, 0.0, 1.0)

# -------- core sim --------
func step_one_day() -> void:
    day += 1
    supply_count_today = 0
    # 日次イベントの効果残日数を減らす ＆ 日次イベントロール
    _effects_tick_down()
    _roll_daily_event()
    # 道中イベントロール（プレイヤーが移動中のみ）
    _roll_travel_event_for_player()

    # 生産/消費
    for city_id in stock.keys():
        for pid in stock[city_id].keys():
            var rec: Dictionary = stock[city_id][pid]
            var new_qty: float = max(0.0, float(rec["qty"]) + float(rec["prod"]) - float(rec["cons"]))
            stock[city_id][pid]["qty"] = new_qty

    # 追加：ランダム供給（デフォルト無効＝rules空）
    _apply_supply_events()

    update_prices()
    # ▼▼▼ 追加：定期市/委託の“日次処理” ▼▼▼
    if enable_fairs:
        _tick_fairs()
    if enable_stalls:
        _process_auto_sales()
    # ▲▲▲ ここまで ▲▲▲
    # NPC 行動
    for t in traders:
        var just_arrived: bool = bool(t.get("enroute", false)) and int(t.get("arrival_day", 0)) <= day
        if just_arrived:
            _arrive_and_trade(t)
        if not bool(t.get("enroute", false)) and (depart_same_day or not just_arrived):
            _plan_and_depart(t)

    # プレイヤー到着
    if bool(player.get("enroute", false)) and int(player.get("arrival_day", 0)) <= day:
        _player_arrive()

    if enable_player_decay:
        _apply_player_decay()

    day_advanced.emit(day)
    world_updated.emit()
    _log_day_summary()
    if log_daily_supply_count:
        _log_supply_daily_count()

# ---- Effects / Message helpers ----
func _effects_tick_down() -> void:
    var next: Array[Dictionary] = []
    for e_any in _effects_active:
        var e: Dictionary = e_any
        var remain := int(e.get("remain", 0)) - 1
        if remain > 0:
            e["remain"] = remain
            next.append(e)
    _effects_active = next

func _price_mult_for(c: String, pid: String) -> float:
    var m: float = 1.0
    for e_any in _effects_active:
        var e: Dictionary = e_any
        if String(e.get("kind","")) != "price_mult":
            continue
        var tc := String(e.get("target_city","*"))
        var tp := String(e.get("target_pid","*"))
        if (tc == "*" or tc == c) and (tp == "*" or tp == pid):
            m *= float(e.get("price_mult", 1.0))
    return m

func get_trade_tax_rate() -> float:
    var r: float = trade_tax_rate
    for e_any in _effects_active:
        var e: Dictionary = e_any
        if String(e.get("kind","")) == "tax_offset":
            r += float(e.get("tax_delta", 0.0))
    return clamp(r, 0.0, 0.5)


func _roll_daily_event() -> void:
    if _events_daily.size() == 0:
        return
    # 重み付き（NONEを含む）
    var total_w := 0.0
    for r_any in _events_daily:
        total_w += float(r_any.get("weight", 0))
    if total_w <= 0.0:
        return
    if log_event_dice_verbose:
        _dice_debug("DailyDice: total_w=%.3f entries=%d" % [total_w, _events_daily.size()])
    var pick := randf() * total_w
    var chosen: Dictionary = {}
    var acc := 0.0
    for r_any in _events_daily:
        acc += float(r_any.get("weight", 0))
        if pick <= acc:
            chosen = r_any
            break
    var kind := String(chosen.get("kind","none"))
    _dice_debug("DailyDice: pick=%.3f kind=%s id=%s" % [pick, kind, String(chosen.get("id",""))])
    if kind == "none":
        var msg := String(chosen.get("flavor_ja", ""))
        if msg != "": _world_message(msg)
        return
    if kind == "price_mult":
        var e := {
            "kind":"price_mult",
            "target_city": String(chosen.get("target_city","*")),
            "target_pid": String(chosen.get("target_pid","*")),
            "price_mult": float(chosen.get("value", 1.0)),
            "remain": int(chosen.get("duration", 1)),
            "src_id": String(chosen.get("id",""))
        }
        _effects_active.append(e)
    elif kind == "tax_offset":
        var e2 := {
            "kind":"tax_offset",
            "tax_delta": float(chosen.get("value", 0.0)),
            "remain": int(chosen.get("duration", 1)),
            "src_id": String(chosen.get("id",""))
        }
        _effects_active.append(e2)
    var msg2 := String(chosen.get("flavor_ja", ""))
    if msg2 != "": _world_message(msg2)


func _roll_travel_event_for_player() -> void:
    if _events_travel.size() == 0:
        return
    if not bool(player.get("enroute", false)):
        return
    var origin := String(player.get("city", ""))
    var dest := String(player.get("dest", ""))
    var hazard := _route_hazard(origin, dest)
    var escort := int(player.get("escort_level", 0))

    # 1日1回、重み付き（NONE含む）— 危険度/護衛で良悪の重みを調整
    var total_w := 0.0
    var weights: Array[float] = []
    for r_any in _events_travel:
        var w := float(r_any.get("weight", 0.0))
        var sev := _classify_travel_row(r_any)   # -1=良, 0=無, +1=悪
        if sev > 0:
            w *= max(0.0, 1.0 + hazard * travel_bad_weight_per_hazard + float(escort) * travel_bad_weight_per_escort)
        elif sev < 0:
            w *= max(0.0, 1.0 + hazard * travel_good_weight_per_hazard + float(escort) * travel_good_weight_per_escort)
        weights.append(w)
        total_w += w
    if total_w <= 0.0:
        return

    if log_event_dice_verbose:
        _dice_debug("TravelDice: origin=%s dest=%s hazard=%.2f escort=%d total_w=%.3f" % [origin, dest, hazard, escort, total_w])

    var pick := randf() * total_w
    var chosen: Dictionary = {}
    var acc := 0.0
    var idx := 0
    for r_any in _events_travel:
        acc += float(weights[idx])
        if pick <= acc:
            chosen = r_any
            break
        idx += 1

    var kind := String(chosen.get("kind","none"))
    var val := float(chosen.get("value", 0))

    _dice_debug("TravelDice: pick=%.3f kind=%s id=%s val=%.3f (hazard=%.2f escort=%d)" % [pick, kind, String(chosen.get("id","")), val, hazard, escort])

    if kind == "none":
        var msg := String(chosen.get("flavor_ja", ""))
        if msg != "": _world_message(msg)
        return
    if kind == "days_delta":
        var arrive := int(player.get("arrival_day", day))
        arrive = max(day + 1, arrive + int(round(val)))
        player["arrival_day"] = arrive
        var msg2 := String(chosen.get("flavor_ja", ""))
        if msg2 != "": _world_message(msg2)
    elif kind == "cargo_loss_pct":
        var ratio: float = clamp(float(val), 0.0, 1.0)
        var cargo: Dictionary = player.get("cargo", {}) as Dictionary
        for pid in cargo.keys():
            var have := int(cargo[pid])
            var loss := int(floor(float(have) * ratio))
            if loss > 0:
                if _is_perishable(pid):
                    _lots_take(pid, loss)
                    cargo[pid] = int(_lots_total(pid))
                else:
                    cargo[pid] = max(0, have - loss)
        player["cargo"] = cargo
        var msg3 := String(chosen.get("flavor_ja", ""))
        if msg3 != "": _world_message(msg3)


# ---- スプレッドと価格API ----
func _spread_for(c: String, pid: String) -> float:
    var sp: float = spread_base
    if stock.has(c) and stock[c].has(pid):
        var rec: Dictionary = stock[c][pid]
        var target: float = max(1.0, float(rec.get("target", 1.0)))
        var qty: float = max(0.0, float(rec.get("qty", 0.0)))
        var s: float = max(0.0, 1.0 - (qty / target))
        if _shortage_ema.has(c) and (_shortage_ema[c] as Dictionary).has(pid):
            s = float((_shortage_ema[c] as Dictionary)[pid])
        sp += spread_k * s
    return clamp(sp, min_spread, max_spread)


func get_mid_price(c: String, pid: String) -> float:
    return float(price[c].get(pid, products[pid]["base"]))

func get_ask_price(c: String, pid: String) -> float:
    var mid: float = get_mid_price(c, pid)
    var sp: float = _spread_for(c, pid)
    return max(1.0, mid * (1.0 + sp * 0.5))

func get_bid_price(c: String, pid: String) -> float:
    var mid: float = get_mid_price(c, pid)
    var sp: float = _spread_for(c, pid)
    return max(1.0, mid * (1.0 - sp * 0.5))

# --- 補助API：UIやデバッグ用（商品増加に対応しやすく） ---
func get_product_ids() -> Array:
    var ids: Array = products.keys()
    ids.sort()
    return ids

func get_product_name(pid: String) -> String:
    if products.has(pid):
        return String(products[pid].get("name", pid))
    return pid


func load_data() -> void:
    # products
    var prod_rows: Array[Dictionary] = _loader.load_csv_dicts(data_dir + "products.csv")
    for row_any in prod_rows:
        var row: Dictionary = row_any
        var pid: String = String(row.get("product_id", ""))
        if pid == "":
            continue
        var pname: String = String(row.get("name_ja", row.get("name_jp", row.get("name", ""))))
        var base_val: float = _num(row.get("base_price", 0))
        var carry_val: int = int(_num(row.get("carry_size", row.get("carrySize", row.get("size", 1)))))
        
        products[pid] = {"name": pname, "base": base_val, "size": carry_val}
        # decay/category (optional columns)
        if product_category == null: product_category = {}
        if product_decay_cfg == null: product_decay_cfg = {}
        var cat := String(row.get("category", "general")).to_lower()
        var rate := float(_num(row.get("decay_rate", player_decay_default_rate)))
        var grace := int(_num(row.get("decay_grace_days", player_decay_grace_default)))
        product_category[pid] = cat
        product_decay_cfg[pid] = {"rate": rate, "grace": grace}


    # cities
    var city_rows: Array[Dictionary] = _loader.load_csv_dicts(data_dir + "cities.csv")
    for row_any2 in city_rows:
        var row2: Dictionary = row_any2
        var cid: String = String(row2.get("city_id", ""))
        if cid == "":
            continue
        cities[cid] = {
            "name": String(row2.get("name_ja", row2.get("name_jp", row2.get("name", "")))),
            "province": String(row2.get("province", "")),
            "note": String(row2.get("note", "")),
            "funds": 0.0
        }

    # routes
    routes.clear()
    var route_rows: Array[Dictionary] = _loader.load_csv_dicts(data_dir + "routes.csv")
    for rr_any in route_rows:
        var rr: Dictionary = rr_any
        routes.append({
            "from": String(rr.get("from", "")),
            "to": String(rr.get("to", "")),
            "days": int(_num(rr.get("days", 1))),
            "toll": float(_num(rr.get("toll", 0.0)))

        })

    # stock/price
    stock.clear()
    price.clear()
    history.clear()
    for cid in cities.keys():
        stock[cid] = {}
        price[cid] = {}
        history[cid] = {}
    var st_rows: Array[Dictionary] = _loader.load_csv_dicts(data_dir + "city_stock.csv")
    for st_any in st_rows:
        var st: Dictionary = st_any
        var c: String = String(st.get("city_id", ""))
        var p: String = String(st.get("product_id", ""))
        if c == "" or p == "":
            continue
        if not stock.has(c):
            stock[c] = {}
            price[c] = {}
            history[c] = {}
        stock[c][p] = {
            "qty": _num(st.get("stock_qty", 0)),
            "target": _num(st.get("target_stock", 1)),
            "prod": _num(st.get("prod_per_day", 0)),
            "cons": _num(st.get("cons_per_day", 0)),
        }

    # --- イベントテーブル読込（無ければ空配列） ---
    _events_daily = _loader.load_csv_dicts(data_dir + events_daily_file)
    _events_travel = _loader.load_csv_dicts(data_dir + events_travel_file)

func build_graph() -> void:
    adj.clear()
    for cid in cities.keys():
        adj[cid] = []
    for r in routes:
        var a: String = String(r["from"])
        var b: String = String(r["to"])
        (adj[a] as Array).append(b)
        (adj[b] as Array).append(a)

func update_prices() -> void:
    for c in cities.keys():
        for pid in products.keys():
            var base: float = float(products[pid]["base"])
            # city_stock に該当 pid が無い都市では rec は null になり得る
            var rec: Variant = null
            if stock.has(c):
                rec = (stock[c] as Dictionary).get(pid, null)
            if rec == null:
                price[c][pid] = base
                _update_shortage_ema(c, pid, 0.0)
            else:
                var rd: Dictionary = rec
                var target: float = max(1.0, float(rd.get("target", 1.0)))
                var diff: float = float(rd.get("target", 1.0)) - float(rd.get("qty", 0.0))
                var mult: float = 1.0 + price_k * (diff / target)
                mult = clamp(mult, min_mult, max_mult)
                var eff := _price_mult_for(c, pid)
                price[c][pid] = max(1.0, base * mult * eff)
                var _s_tmp: float = max(0.0, 1.0 - (float(rd.get("qty", 0.0)) / max(1.0, float(rd.get("target", 1.0)))))
                _update_shortage_ema(c, pid, _s_tmp)
            # ヒストリ
            if not history.has(c):
                history[c] = {}
            var arr: Array = history[c].get(pid, [])
            arr.append(price[c][pid])
            if arr.size() > history_days:
                arr.pop_front()
            history[c][pid] = arr

func init_traders() -> void:
    traders.clear()
    var presets: Array = []
    var p1: Dictionary = {}
    p1["greedy"] = 0.9
    p1["risk"] = 0.8
    p1["explore"] = 0.2
    presets.append(p1)
    var p2: Dictionary = {}
    p2["greedy"] = 0.6
    p2["risk"] = 0.3
    p2["explore"] = 0.5
    presets.append(p2)

    for i in range(2):
        var traits: Dictionary = presets[i % presets.size()]
        var t: Dictionary = {}
        t["id"] = "NPC%02d" % (i + 1)
        t["city"] = "RE0001"
        t["cash"] = 200.0
        t["cap"] = 30
        t["cargo"] = {}
        t["enroute"] = false
        t["dest"] = ""
        t["arrival_day"] = 0
        t["greedy"] = float(traits.get("greedy", 0.7))
        t["risk"] = float(traits.get("risk", 0.5))
        t["explore"] = float(traits.get("explore", 0.2))
        traders.append(t)

    # Load fair calendar from CSV if present
    var cal_path := data_dir + "calendar_events.csv"
    if FileAccess.file_exists(cal_path):
        var cal_rows: Array[Dictionary] = _loader.load_csv_dicts(cal_path)
        fair_schedule = {}
        for r_any in cal_rows:
            var r: Dictionary = r_any
            var kind := String(r.get("type", r.get("kind", "")))
            if kind != "" and kind != "fair":
                continue
            var cid := String(r.get("city_id", ""))
            if cid == "":
                continue
            var start := int(_num(r.get("start_day", r.get("start", 0))))
            var duration := int(_num(r.get("duration", 1)))
            var fee := float(_num(r.get("fee", 0.0)))
            var boost := float(_num(r.get("crowd_factor", r.get("boost", 1.0))))
            if not fair_schedule.has(cid): fair_schedule[cid] = []
            (fair_schedule[cid] as Array).append({"start":start, "duration":duration, "fee":fee, "boost":boost})

# -------- trading / travel --------
func _arrive_and_trade(t: Dictionary) -> void:
    # 到着処理：売却のみ（仕入れは出発計画で行う）
    t["enroute"] = false
    t["city"] = t["dest"]

    for pid in (t["cargo"] as Dictionary).keys():
        var qty: float = float(t["cargo"][pid])
        if qty <= 0.0:
            continue
        _ensure_stock_record(String(t["city"]), String(pid))
        stock[t["city"]][pid]["qty"] = float(stock[t["city"]][pid]["qty"]) + qty
        _update_price_for(String(t["city"]), String(pid))
        var gross: float = qty * get_bid_price(t["city"], pid)
        var tax: float = gross * get_trade_tax_rate()
        var revenue: float = gross - tax
        t["cash"] = float(t["cash"]) + revenue
        t["cargo"][pid] = 0
        cities[t["city"]]["funds"] = float(cities[t["city"]]["funds"]) + tax
        _log("%s sold %s x%d @%.1f in %s (+%.1f, tax %.1f)" % [t["id"], pid, int(qty), get_bid_price(t["city"], pid), t["city"], revenue, tax])


func _plan_and_depart(t: Dictionary) -> void:
    var city: String = String(t["city"])

    var plan: Dictionary = _best_trade_from(city, t)
    var dest: String = String(plan.get("dest", ""))
    if dest == "":
        return

    var pid: String = String(plan.get("pid", ""))
    var qty: int = int(plan.get("qty", 0))
    if pid == "" or qty <= 0:
        return

    var days_cost: int = int(plan.get("days", _route_days(city, dest)))
    var travel_cost: float = float(plan.get("travel", travel_cost_per_day * float(days_cost)))
    var toll: float = (float(plan.get("toll", _route_toll(city, dest))) if pay_toll_on_depart else 0.0)

    var ask_price: float = get_ask_price(city, pid)
    var cash_now: float = float(t.get("cash", 0.0))
    var max_q_cash: int = int(floor((cash_now - (travel_cost + toll)) / max(1.0, ask_price)))
    if max_q_cash < qty:
        qty = max(0, max_q_cash)

    _ensure_stock_record(city, pid)
    var avail: int = int(floor(float(stock[city][pid]["qty"])))
    var unit_size: int = int(products[pid].get("size", 1))
    var cap_free: int = max(0, int(t.get("cap", 0)) - _cargo_used(t))
    var max_by_cap: int = cap_free / max(1, unit_size)
    qty = max(0, min(qty, avail, max_by_cap))
    if qty <= 0:
        return

    stock[city][pid]["qty"] = float(stock[city][pid]["qty"]) - float(qty)
    t["cash"] = cash_now - float(qty) * ask_price
    t["cargo"][pid] = int(t["cargo"].get(pid, 0)) + qty
    _update_price_for(city, pid)

    t["dest"] = dest
    t["arrival_day"] = day + days_cost
    t["enroute"] = true

    if travel_cost > 0.0:
        t["cash"] = max(0.0, float(t["cash"]) - travel_cost)
        cities[city]["funds"] = float(cities[city]["funds"]) + travel_cost
    if pay_toll_on_depart and toll > 0.0:
        t["cash"] = max(0.0, float(t["cash"]) - toll)
        cities[city]["funds"] = float(cities[city]["funds"]) + toll * 0.5
        cities[dest]["funds"] = float(cities[dest]["funds"]) + toll * 0.5

    _log("%s depart %s -> %s carrying %s x%d (profit≈%.1f)" % [t["id"], city, dest, pid, qty, float(plan.get("profit", 0.0))])

func _best_trade_from(city: String, t: Dictionary) -> Dictionary:
    var best: Dictionary = {"dest": "", "pid": "", "qty": 0, "profit": -1e20}
    if not adj.has(city):
        return best

    var cap_free: int = max(0, int(t.get("cap", 0)) - _cargo_used(t))

    for nb in (adj[city] as Array):
        var days: int = _route_days(city, nb)
        var travel: float = travel_cost_per_day * float(days)
        var toll: float = (float(_route_toll(city, nb)) if pay_toll_on_depart else 0.0)

        for pid in products.keys():
            if not stock.has(city) or not stock[city].has(pid):
                continue

            var ask: float = get_ask_price(city, pid)
            var bid: float = get_bid_price(nb, pid)
            var unit_gain: float = bid - ask
            if unit_gain <= 0.0:
                continue

            var unit_size: int = int(products[pid].get("size", 1))
            var max_by_cap: int = cap_free / max(1, unit_size)
            var avail: int = int(floor(float(stock[city][pid]["qty"])) )
            var max_by_cash: int = int(floor(float(t.get("cash", 0.0)) / max(1.0, ask)))
            var q: int = max(0, min(avail, max_by_cap, max_by_cash))
            if q <= 0:
                continue

            var profit: float = unit_gain * float(q) - (travel + toll)

            # 強欲度に応じた最低相対利幅（2%～10%）を要求
            var min_rel: float = 0.02 + 0.08 * float(t.get("greedy", 0.7))
            if (unit_gain / max(1.0, ask)) < min_rel:
                continue

            if profit > float(best.get("profit", -1e20)):
                best = {"dest": nb, "pid": pid, "qty": q, "profit": profit, "days": days, "travel": travel, "toll": toll}
    return best

# -------- helpers --------

# 供給イベントのフレーバーテキスト生成（UIでダイアログ/トーストに使う想定）
func _format_supply_flavor(cid: String, pid: String, q: int, mode: String) -> String:
    var cname: String = String(cities.get(cid, {}).get("name", cid))
    var pname: String = get_product_name(pid)
    if pid == "PR03":
        return "%sで%sが大漁のようです。（+%d）" % [cname, pname, q]
    if mode.find("seasonal") != -1:
        return "%sでは季節の恵みで%sの入荷が増えています。（+%d）" % [cname, pname, q]
    return "%sに%sの入荷があったようです。（+%d）" % [cname, pname, q]

# 供給イベントの実行（確率・クール・上限・季節補正・デバッグカウント）
func _apply_supply_events() -> void:
    if supply_rules.is_empty():
        return

    var events_today: int = 0

    var city_ids: Array = cities.keys()
    city_ids.shuffle()
    var pids: Array = supply_rules.keys()
    pids.shuffle()

    for cid in city_ids:
        for pid in pids:
            if events_today >= supply_daily_cap:
                return

            var r: Dictionary = supply_rules[pid]
            var mode: String = String(r.get("mode", "burst"))
            var p: float = float(r.get("p_base", 0.0))
            if p <= 0.0:
                continue

            # 季節sin（季節系のみ）
            if mode.find("seasonal") != -1:
                var denom: int = max(1, year_days)
                var phase: float = float(hash(cid) % denom) / float(denom)
                var season: float = 0.5 + 0.5 * sin(TAU * (float(day) / float(denom) + phase))
                p *= 1.0 + float(r.get("amp", 0.0)) * ((season - 0.5) * 2.0)

            # 月/季節係数（UIの暦に合わせた枠組み）
            var cal := get_calendar()
            var month_now: int = int(cal.get("month", 1))
            p *= _month_supply_multiplier(month_now) * _season_supply_multiplier(month_now)

            # デバッグ時の全体ブースト
            if supply_debug_boost_enable:
                p *= max(0.0, supply_debug_boost)

            # 在庫が豊富すぎればスキップ
            if supply_skip_when_above_ratio > 0.0 and stock.has(cid) and (stock[cid] as Dictionary).has(pid):
                var rd: Dictionary = stock[cid][pid]
                var target: float = max(1.0, float(rd.get("target", 1.0)))
                var qty: float = max(0.0, float(rd.get("qty", 0.0)))
                if qty / target >= supply_skip_when_above_ratio:
                    continue

            # クールダウン（ハード）
            var cd_min: int = int(r.get("cooldown", supply_cooldown_min_days))
            var last_d: int = -1000000
            if _last_supply_day.has(cid):
                var m: Dictionary = _last_supply_day[cid] as Dictionary
                last_d = int(m.get(pid, last_d))
            var days_since: int = day - last_d
            if days_since < cd_min:
                continue

            # クール明けの確率ランプ（ソフト）
            var ramp: float = 1.0
            if supply_cooldown_ramp_days > 0:
                ramp = clamp(float(days_since - cd_min) / float(supply_cooldown_ramp_days), 0.05, 1.0)
            var peff: float = p * ramp

            if randf() < peff:
                var qmin: int = int(r.get("qty_min", 1))
                var qmax: int = int(r.get("qty_max", qmin))
                var q: int = randi_range(min(qmin, qmax), max(qmin, qmax))

                _ensure_stock_record(cid, pid)
                stock[cid][pid]["qty"] = float(stock[cid][pid]["qty"]) + float(q)
                _update_price_for(cid, pid)

                var flavor: String = _format_supply_flavor(cid, pid, q, mode)
                push_event(flavor)
                supply_event.emit(cid, pid, q, mode, flavor)
                if log_each_supply_event:
                    _log("SupplyEvent: %s %s +%d" % [cid, pid, q])

                if not _last_supply_day.has(cid):
                    _last_supply_day[cid] = {}
                (_last_supply_day[cid] as Dictionary)[pid] = day

                # カウント更新
                supply_count_today += 1
                supply_count_total += 1
                var cal2 := get_calendar()
                var month_now2: int = int(cal2.get("month", 1))
                var key := "%04d-%02d" % [int(cal2.get("year", 1)), month_now2]
                supply_count_by_month[key] = int(supply_count_by_month.get(key, 0)) + 1
                supply_count_by_city[cid] = int(supply_count_by_city.get(cid, 0)) + 1
                supply_count_by_pid[pid] = int(supply_count_by_pid.get(pid, 0)) + 1

                events_today += 1

func _cheapest_ratio_pid(city_id: String) -> String:
    var best_pid: String = ""
    var best_ratio: float = 1e20
    for pid in products.keys():
        var p: float = float(price[city_id].get(pid, products[pid]["base"]))
        var base: float = float(products[pid]["base"])
        var ratio: float = p / max(0.0001, base)
        if stock[city_id].has(pid) and float(stock[city_id][pid]["qty"]) > 0.0 and ratio < best_ratio:
            best_ratio = ratio
            best_pid = String(pid)
    return best_pid

func _first_positive_pid(t: Dictionary) -> String:
    for pid in (t["cargo"] as Dictionary).keys():
        if int(t["cargo"][pid]) > 0:
            return String(pid)
    return ""

func _best_neighbor_for_product(city_id: String, pid: String, t: Dictionary = {}) -> String:
    var best: String = ""
    var best_score: float = -1e20
    var explore: float = float(t.get("explore", 0.0)) if t.size() > 0 else 0.0
    for nb in (adj[city_id] as Array):
        var current: float = float(price[city_id][pid])
        var nextp: float = float(price[nb][pid])
        var delta: float = nextp - current
        var toll: float = float(_route_toll(city_id, nb))
        var noise: float = (randf() - 0.5) * explore  # 探索性：小さなランダム要素
        var score: float = (delta - toll) + noise
        if score > best_score:
            best_score = score
            best = String(nb)
    return best

func _route_days(a: String, b: String) -> int:
    for r in routes:
        if (String(r["from"]) == a and String(r["to"]) == b) or (String(r["from"]) == b and String(r["to"]) == a):
            return int(r["days"])
    return 1

func _route_toll(a: String, b: String) -> float:
    for r in routes:
        if (String(r["from"]) == a and String(r["to"]) == b) or (String(r["from"]) == b and String(r["to"]) == a):
            return float(r["toll"])
    return 0.0

func _update_price_for(c: String, pid: String) -> void:
    if not products.has(pid):
        return
    if not price.has(c):
        price[c] = {}
    var base: float = float(products[pid]["base"])
    var rec: Variant = null
    if stock.has(c):
        rec = (stock[c] as Dictionary).get(pid, null)
    if rec == null:
        price[c][pid] = base
        _update_shortage_ema(c, pid, 0.0)
    else:
        var rd: Dictionary = rec
        var target: float = max(1.0, float(rd.get("target", 1.0)))
        var diff: float = target - float(rd.get("qty", 0.0))
        var mult: float = clamp(1.0 + price_k * (diff / target), min_mult, max_mult)
        price[c][pid] = max(1.0, base * mult)
        var s: float = max(0.0, 1.0 - (float(rd.get("qty", 0.0)) / target))
        _update_shortage_ema(c, pid, s)

# Ensure a stock record exists for a city/product before read/write
func _ensure_stock_record(c: String, pid: String) -> void:
    if not stock.has(c):
        stock[c] = {}
    if not (stock[c] as Dictionary).has(pid):
        stock[c][pid] = {
            "qty": 0.0,
            "target": 1.0,
            "prod": 0.0,
            "cons": 0.0,
        }

func _update_shortage_ema(c: String, pid: String, s: float) -> void:
    if not _shortage_ema.has(c):
        _shortage_ema[c] = {}
    var d: Dictionary = _shortage_ema[c] as Dictionary
    var prev: float = float(d.get(pid, s))
    d[pid] = prev + (s - prev) * clamp(shortage_alpha, 0.0, 1.0)


func _cargo_used(t: Dictionary) -> int:
    var total: int = 0
    for pid in (t["cargo"] as Dictionary).keys():
        var qty: int = int(t["cargo"][pid])
        var size: int = 1
        if products.has(pid):
            size = int(products[pid].get("size", 1))
        total += qty * size
    return total

# -------- logging --------
func _log_day_summary() -> void:
    var s: String = "Day %d | Prices:" % day
    for c in cities.keys():
        s += "\n  %s:" % String(c)
        for pid in products.keys():
            s += " %s=%.1f" % [String(pid), float(price[c].get(pid, products[pid]["base"]))]
    print(s)

func _world_message(msg: String) -> void:
    var txt := _humanize_ids_in_text(msg)
    event_log.append(txt)
    if event_log.size() > event_log_max: event_log.pop_front()
    # HUD既存の supply_event 表示を流用（city/pid空）
    supply_event.emit("", "", 0, "event", txt)

func _log(m: String) -> void:
    print(m)

func _log_supply_daily_count() -> void:
    var cal := get_calendar()
    var month_now: int = int(cal.get("month", 1))
    var key := "%04d-%02d" % [int(cal.get("year", 1)), month_now]
    _log("SupplyCount: Day %d -> %d events (Month %s total %d)" % [day, supply_count_today, key, int(supply_count_by_month.get(key, 0))])

func push_event(m: String) -> void:
    event_log.append(m)
    if event_log.size() > event_log_max:
        event_log.pop_front()

# -------- Player --------
var player: Dictionary = {}

func init_player() -> void:
    player = {
        "id": "YOU",
        "city": "RE0001",
        "cash": 500.0,
        "cap": 40,
        "cargo": {},
        "enroute": false,
        "dest": "",
        "arrival_day": 0,
    }
    player["escort_level"] = int(player.get("escort_level", 0))

    player["last_arrival_day"] = -999
func _player_arrive() -> void:
    player["enroute"] = false
    player["city"] = player["dest"]
    player["last_arrival_day"] = day
    world_updated.emit()


enum MoveErr { OK, ARRIVED_TODAY, NOT_ADJACENT, LACK_CASH }

func can_player_move_to(dest: String) -> Dictionary:
    var a: String = String(player.get("city", ""))
    if int(player.get("last_arrival_day", -999)) == day:
        return {"ok": false, "err": MoveErr.ARRIVED_TODAY}
    if not adj.has(a) or not (dest in (adj[a] as Array)):
        return {"ok": false, "err": MoveErr.NOT_ADJACENT}
    var days: int = _route_days(a, dest)
    var travel_cost: float = travel_cost_per_day * float(days)
    var toll: float = (float(_route_toll(a, dest)) if pay_toll_on_depart else 0.0)
    var total_cost: float = travel_cost + toll
    if float(player.get("cash", 0.0)) < total_cost:
        return {"ok": false, "err": MoveErr.LACK_CASH, "need": total_cost, "days": days}
    return {"ok": true, "need": total_cost, "days": days}

func player_move(dest: String) -> bool:
    if bool(player.get("enroute", false)):
        return false
    if int(player.get("last_arrival_day", -999)) == day:
        return false
    var a: String = String(player.get("city", ""))
    if not adj.has(a) or not (dest in (adj[a] as Array)):
        return false
    var days: int = _route_days(a, dest)
    var travel_cost: float = travel_cost_per_day * float(days)
    var toll: float = (float(_route_toll(a, dest)) if pay_toll_on_depart else 0.0)
    var total_cost: float = travel_cost + toll
    if float(player.get("cash", 0.0)) < total_cost:
        return false
    player["cash"] = float(player["cash"]) - total_cost
    cities[a]["funds"] = float(cities[a]["funds"]) + travel_cost + toll * 0.5
    cities[dest]["funds"] = float(cities[dest]["funds"]) + toll * 0.5
    player["dest"] = dest
    player["arrival_day"] = day + days
    player["enroute"] = true
    world_updated.emit()
    return true

func player_buy(pid: String, qty: int) -> bool:
    if bool(player.get("enroute", false)):
        return false
    var city: String = String(player.get("city", ""))
    if not stock.has(city) or not stock[city].has(pid):
        return false
    var price_u: float = get_ask_price(city, pid)
    var avail: float = float(stock[city][pid]["qty"])
    qty = clamp(qty, 1, int(avail))
    var unit_size: int = int(products[pid].get("size", 1))
    var free_cap: int = max(0, int(player["cap"]) - _cargo_used(player))
    var max_by_cap: int = free_cap / max(1, unit_size)
    qty = min(qty, max_by_cap)
    var can_spend: float = float(player["cash"]) / price_u
    qty = min(qty, int(floor(can_spend)))
    if qty <= 0:
        return false
    stock[city][pid]["qty"] = float(stock[city][pid]["qty"]) - float(qty)
    player["cash"] = float(player["cash"]) - float(qty) * price_u
    player["cargo"][pid] = int(player["cargo"].get(pid, 0)) + qty
    _lots_add(pid, qty)
    _update_price_for(city, pid)
    world_updated.emit()
    return true

func player_sell(pid: String, qty: int) -> bool:
    if bool(player.get("enroute", false)):
        return false
    var have: int = int(player["cargo"].get(pid, 0))
    qty = clamp(qty, 1, have)
    if qty <= 0:
        return false
    var city: String = String(player.get("city", ""))
    stock[city][pid]["qty"] = float(stock[city][pid]["qty"]) + float(qty)
    var gross: float = float(qty) * get_bid_price(city, pid)
    var tax: float = gross * get_trade_tax_rate()
    player["cash"] = float(player["cash"]) + (gross - tax)
    if _is_perishable(pid):
        _lots_take(pid, qty)
        player["cargo"][pid] = int(_lots_total(pid))
    else:
        player["cargo"][pid] = have - qty
    cities[city]["funds"] = float(cities[city]["funds"]) + tax
    _update_price_for(city, pid)
    world_updated.emit()
    return true

# === Calendar constants ===
@export var DAYS_PER_MONTH: int = 30
@export var MONTHS_PER_YEAR: int = 12
var DAYS_PER_YEAR: int = DAYS_PER_MONTH * MONTHS_PER_YEAR

# day は従来どおり「通算日」。0スタート想定（Day 0 ＝ 1年1月1日）
func get_calendar(day_idx: int = -1) -> Dictionary:
    var d := (day if day_idx < 0 else day_idx)
    var y := (d / DAYS_PER_YEAR) + 1
    var m := ((d % DAYS_PER_YEAR) / DAYS_PER_MONTH) + 1
    var dm := (d % DAYS_PER_MONTH) + 1
    return {"year": y, "month": m, "day": dm}

func format_date(day_idx: int = -1) -> String:
    var c := get_calendar(day_idx)
    return "%d年%02d月%02d日" % [int(c.get("year", 0)), int(c.get("month", 0)), int(c.get("day", 0))]

# 月→係数
func _month_supply_multiplier(month: int) -> float:
    if monthly_supply_mult.size() >= 12 and month >= 1 and month <= 12:
        return float(monthly_supply_mult[month - 1])
    return 1.0

# 月→季節タグ
func _season_of_month(m: int) -> String:
    if m == 12 or m == 1 or m == 2: return "winter"
    if m >= 3 and m <= 5: return "spring"
    if m >= 6 and m <= 8: return "summer"
    return "autumn"

# 季節→係数
func _season_supply_multiplier(month: int) -> float:
    var tag := _season_of_month(month)
    return float(season_supply_mult.get(tag, 1.0))

# ==== Config / State ====
@export var enable_stalls := false
@export var enable_fairs := false
@export var enable_player_decay: bool = true
@export var log_decay_debug: bool = false  # プレイヤー在庫の劣化ログ（デバッグ）
@export var perishable_categories := ["fish","meat","food"]
@export var player_decay_default_rate: float = 0.20
@export var player_decay_grace_default: int = 0
var product_category := {}
var product_decay_cfg := {}
var cargo_lots := {}            # pid -> [ {"qty": int, "age": int}, ... ]

@export var stall_commission := 0.06      # 委託手数料（売上の%）
@export var stall_fee_per_day := 0.5      # 屋台/場所代（日額）
@export var stall_base_rate := 1.0        # 基準販売速度（不足=1で1個/日が目安）

var player_home_city: String = "RE0001"

# 委託在庫: {city: {pid: {"qty":int,"price_mult":float,"days_left":int,"boost":float}}}
var stalls: Dictionary = {}

# 定期市スケジュールと開催中ブースト
var fair_schedule := {
    "RE0003": [ {"start":30,"duration":3,"fee":5.0,"boost":2.0} ],
}
var fair_active := {}  # {city: {"days_left":int,"boost":float}}

signal stall_sold(city_id: String, product_id: String, qty: int, unit_price: float, gross: float, tax: float, commission: float, fee: float)
signal player_decay_event(pid: String, lost_qty: int, flavor: String)
func consign(city: String, pid: String, qty: int, price_mult := 1.0, days := 10, boost := 1.0) -> bool:
    if not enable_stalls or qty <= 0:
        return false
    var cargo := player.get("cargo", {}) as Dictionary
    var have := int(cargo.get(pid, 0))
    qty = min(qty, have)
    if qty <= 0: return false
    if _is_perishable(pid):
        _lots_take(pid, qty)
        cargo[pid] = int(_lots_total(pid))
    else:
        cargo[pid] = have - qty  # 手持ちから引く

    if not stalls.has(city): stalls[city] = {}
    var c := stalls[city] as Dictionary
    if not c.has(pid):
        c[pid] = {"qty":0, "price_mult":price_mult, "days_left":days, "boost":boost}
    var s := c[pid] as Dictionary
    s["qty"] = int(s["qty"]) + qty
    s["price_mult"] = float(price_mult)
    s["days_left"] = max(int(s["days_left"]), int(days))
    s["boost"] = max(float(s["boost"]), float(boost))
    return true

func join_fair(city: String) -> bool:
    if not enable_fairs: return false
    var entries := fair_schedule.get(city, []) as Array
    for e in entries:
        if int(e["start"]) == day:  # 当日参加
            var fee := float(e["fee"])
            var cash := float(player.get("cash", 0.0))
            if cash < fee: return false
            player["cash"] = cash - fee
            fair_active[city] = {"days_left": int(e["duration"]), "boost": float(e["boost"])}
            _log("FairJoin: %s fee=%.1f" % [city, fee])
            return true
    return false

# ==== Day tick hooks ====
func _tick_fairs() -> void:
    if fair_active.is_empty(): return
    for city in fair_active.keys():
        fair_active[city]["days_left"] = int(fair_active[city]["days_left"]) - 1
    for city in fair_active.keys():
        if int(fair_active[city]["days_left"]) <= 0:
            fair_active.erase(city)



func _process_auto_sales() -> void:
    if not enable_stalls or stalls.is_empty(): return
    for city in stalls.keys():
        var by_pid: Dictionary = stalls[city] as Dictionary
        for pid in by_pid.keys():
            var s: Dictionary = by_pid[pid] as Dictionary
            var q: int = int(s["qty"])
            if q <= 0: continue

            var st: Dictionary = stock.get(city, {}).get(pid, {}) as Dictionary
            var target: float = max(1.0, float(st.get("target", 1)))
            var cur: float = float(st.get("stock_qty", st.get("qty", 0)))
            var shortage: float = clamp(1.0 - cur / target, 0.0, 1.2)

            var boost: float = float(s["boost"])
            if fair_active.has(city):
                boost *= float((fair_active[city] as Dictionary).get("boost", 1.0))

            var base_rate: float = float(stall_base_rate) * (0.3 + shortage) * boost
            var sell: int = int(clamp(roundf(base_rate * (0.7 + randf() * 0.6)), 0.0, float(q)))
            var unit_price: float = min(get_ask_price(city, pid), get_bid_price(city, pid) * float(s["price_mult"]))

            s["days_left"] = int(s["days_left"]) - 1
            if sell <= 0: continue

            var gross: float = unit_price * float(sell)
            var tax: float = gross * get_trade_tax_rate()
            var commission: float = gross * stall_commission
            var fee: float = stall_fee_per_day
            cities[city]["treasury"] = float(cities[city].get("treasury", 0.0)) + tax
            player["cash"] = float(player.get("cash", 0.0)) + (gross - tax - commission - fee)

            s["qty"] = q - sell
            emit_signal("stall_sold", city, pid, sell, unit_price, gross, tax, commission, fee)
            _log("StallSold: %s %s x%d @%.1f (net %.1f)" % [city, pid, sell, unit_price, gross - tax - commission - fee])

        for k in by_pid.keys():
            var ss: Dictionary = by_pid[k] as Dictionary
            if int(ss["qty"]) <= 0 or int(ss["days_left"]) <= 0:
                by_pid.erase(k)
    for c in stalls.keys():
        if (stalls[c] as Dictionary).is_empty():
            stalls.erase(c)


# step_one_day() の末尾あたりに呼び出し
# _apply_supply_events(day) の後あたりが分かりやすいです
#   if enable_fairs: _tick_fairs()
#   if enable_stalls: _process_auto_sales()

func _is_perishable(pid: String) -> bool:
    var cat: String = String(product_category.get(pid, "general"))
    var cfg = product_decay_cfg.get(pid, null)
    var decay_on: bool = (cfg != null and float(cfg.get("rate", 0.0)) > 0.0)
    return decay_on or (cat in perishable_categories)

func _lots_add(pid: String, qty: int) -> void:
    if qty <= 0: return
    if not _is_perishable(pid): return
    if not cargo_lots.has(pid): cargo_lots[pid] = []
    var arr = cargo_lots[pid]
    arr.append({"qty": int(qty), "age": 0})
    cargo_lots[pid] = arr

func _lots_take(pid: String, qty: int) -> int:
    if qty <= 0: return 0
    if not cargo_lots.has(pid): return 0
    var arr = cargo_lots[pid]
    var remain: int = int(qty)
    var i: int = 0
    while i < arr.size() and remain > 0:
        var lot: Dictionary = arr[i]
        var take: int = min(int(lot.get("qty", 0)), remain)
        lot["qty"] = int(lot.get("qty", 0)) - take
        remain -= take
        if int(lot["qty"]) <= 0:
            arr.remove_at(i)
        else:
            arr[i] = lot
            i += 1
    cargo_lots[pid] = arr
    return qty - remain

func _lots_total(pid: String) -> int:
    if not cargo_lots.has(pid): return int(player.get("cargo", {}).get(pid, 0))
    var s: int = 0
    for lot in cargo_lots[pid]:
        s += int((lot as Dictionary).get("qty", 0))
    return s

func _apply_player_decay() -> void:
     # プレイヤー在庫の劣化処理（ロット単位）
     # ・ロット年齢を進め、猶予(grace)日を超えたら rate で減衰
     # ・商品ごとの合計が 0 になった場合のみ通知シグナルを発火
     for pid in cargo_lots.keys():
         if not _is_perishable(pid):
             continue
         var cfg: Dictionary = product_decay_cfg.get(pid, {"rate": player_decay_default_rate, "grace": player_decay_grace_default})
         var rate: float = float(cfg.get("rate", 0.0))
         var grace: int = int(cfg.get("grace", 0))
         if rate <= 0.0:
             continue

         var before_total: int = _lots_total(pid)
         var lots: Array = cargo_lots.get(pid, [])
         var i := 0
         while i < lots.size():
             var lot: Dictionary = lots[i]
             lot["age"] = int(lot.get("age", 0)) + 1
             var qty0: int = int(lot.get("qty", 0))
             if int(lot["age"]) > grace and qty0 > 0:
                 var qf: float = float(qty0) * (1.0 - rate)
                 var q1: int = int(max(0.0, floor(qf + 0.0001)))
                 if log_decay_debug and q1 != qty0:
                     _log("Decay %s: age %d qty %d -> %d" % [pid, int(lot["age"]), qty0, q1])
                 lot["qty"] = q1
             if int(lot.get("qty", 0)) <= 0:
                 lots.remove_at(i)
             else:
                 lots[i] = lot
                 i += 1

         cargo_lots[pid] = lots
         var after_total: int = _lots_total(pid)
         if after_total > 0:
             player["cargo"][pid] = after_total
         else:
             # 0 になった：消失通知（その日の合計ロスは before_total）
             if (player.get("cargo", {}) as Dictionary).has(pid):
                 (player["cargo"] as Dictionary).erase(pid)
             if before_total > 0:
                 var pname: String = get_product_name(pid)
                 var flavor: String = "%sは劣化して全て失われました。（-%d）" % [pname, before_total]
                 push_event(flavor)
                 if has_signal("player_decay_event"):
                     player_decay_event.emit(pid, before_total, flavor)
                 if log_decay_debug:
                     _log("PlayerDecay: %s lost %d (now 0)" % [pid, before_total])


# === Helper: name lookup & ID humanizing ===
func get_city_name(cid: String) -> String:
    return String(cities.get(cid, {}).get("name", cid))

func humanize_ids(msg: String) -> String:
    return _humanize_ids_in_text(msg)

func _humanize_ids_in_text(msg: String) -> String:
    var out := String(msg)
    for cid in cities.keys():
        out = out.replace(String(cid), get_city_name(String(cid)))
    for pid in products.keys():
        out = out.replace(String(pid), get_product_name(String(pid)))
    return out

# === Helper: route hazard & dice debug ===
func _route_key(a: String, b: String) -> String:
    var arr := [String(a), String(b)]
    arr.sort()
    return "%s-%s" % [arr[0], arr[1]]

func _route_hazard(a: String, b: String) -> float:
    var key := _route_key(a, b)
    return float(route_hazard_map.get(key, 0.0))

func _dice_debug(msg: String) -> void:
    if log_event_dice:
        _log(msg)

func _classify_travel_row(r: Dictionary) -> int:
    var kind := String(r.get("kind", "none"))
    var val := float(r.get("value", 0.0))
    if kind == "none":
        return 0
    if kind == "days_delta":
        if val > 0.0: return 1   # 遅延（悪）
        if val < 0.0: return -1  # 短縮（良）
        return 0
    if kind == "cargo_loss_pct":
        if val > 0.0: return 1   # 損失（悪）
        if val < 0.0: return -1  # 回収（良）
        return 0
    return 0
