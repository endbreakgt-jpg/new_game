# === OFFICIAL CANVAS ===
# World.gd (res://scripts/world.gd)
# このキャンバスを唯一の最新版として使用します。重複キャンバスはアーカイブ対象。

extends Node2D
class_name World

signal day_advanced(day: int)
signal world_updated()
signal turn_advanced(turn: int, day: int)
signal supply_event(city_id: String, product_id: String, qty: int, mode: String, flavor: String)
signal weekly_report(province: String, payload: Dictionary)

# --- Tutorial state / locks (TUT-STATE) ---
signal tutorial_state_changed(prev: String, cur: String)
signal tutorial_locks_changed(locks: Dictionary)

const TUT_STATE_NONE := "none"
const TUT_STATE_PROLOGUE := "prologue"
const TUT_STATE_TUT1 := "tut1"
const TUT_STATE_TUT2 := "tut2"
const TUT_STATE_TUT3 := "tut3"

const TUT_LOCK_TRADE := "trade"
const TUT_LOCK_MAP := "map"
const TUT_LOCK_MOVE := "move"
const TUT_LOCK_INV := "inv"
const TUT_LOCK_INFO := "info"
const TUT_LOCK_CONTRACT := "contract"
const TUT_LOCK_TRUST := "trust"
const TUT_LOCK_STEP := "step"
const TUT_LOCK_STEP_TURN := "step_turn"

var tutorial_state: String = TUT_STATE_NONE
# key -> reason(String).  存在する=ロック中
var tutorial_locks: Dictionary = {}

@export var data_dir: String = "res://data/"
@export var day_seconds: float = 0.5

# ターン制（1日は複数ターンで構成）
@export var turns_per_day: int = 3

# 価格ダイナミクス
@export var price_k: float = 0.25
@export var min_mult: float = 0.5
@export var max_mult: float = 2.0
# スプレッド設定（買値/売値の差）
@export var spread_base: float = 0.10   # 平常時スプレッド（±5% = 計10%）
@export var spread_k: float = 0.10      # 在庫不足で上乗せ
@export var min_spread: float = 0.04    # 下限
@export var max_spread: float = 0.30    # 上限
@export var enable_price_inertia: bool = true   # 価格の粘性（α追随）ON/OFF
@export var enable_external_signal: bool = true  # 周辺相場の遅延シグナル（β）ON/OFF

# 経済コスト
@export var travel_cost_per_day: float = 2.0     # 出発時に（日数×この額）
@export var trade_tax_rate: float = 0.03         # 売上税（販売都市の金庫へ）
@export var travel_tax_per_cap: float = 0.05     # 1容量あたりの通行税・関税ベース額（都市RANK係数を掛ける）

@export var events_daily_file: String = "events_daily.csv"   # 日時イベントテーブル（CSV）
@export var events_travel_file: String = "events_travel.csv" # 道中イベントテーブル（CSV）
@export var key_items_file: String = "key_items.csv"        # 大切なもの定義CSV

@export var enable_auto_supply: bool = false  # 旧パッシブ供給のON/OFF（デフォルトOFF）

# --- 噂コスト/真実度（Inspectorで即変更可） ---
@export var rumor_cost_free: int = 0
@export var rumor_cost_nearby: int = 50
@export var rumor_cost_target: int = 100
@export_range(0.0, 1.0, 0.01) var rumor_acc_free: float = 0.80
@export_range(0.0, 1.0, 0.01) var rumor_acc_nearby: float = 0.90
@export_range(0.0, 1.0, 0.01) var rumor_acc_target: float = 0.98

@export var use_event_dice: bool = true             # イベントダイスを使う（HUDが可視化→解決を呼ぶ）
@export var daily_event_prob: float = 0.40

@export var weekly_report_interval_days: int = 7
@export var weekly_report_on_morning: bool = true
@export var weekly_report_top_n: int = 3          # 日次イベントの発生確率（0..1）
@export var weekly_include_world: bool = true

var _last_roll_kind: String = ""
var _last_roll_value: int = 0

# === Rank / Consumption / Tax (2025-10 spec update) ===

@export var consume_rules_file: String = "product_consume_rule.csv"   # 消費ルール（商品ごと）

@export var rank_tax_k: float = 0.02                                  # 税率のランク補正： (rank-5)*k を乗算係数に
@export var rank_consume_k: float = 0.10                               # 予備：乗算式の傾き（未使用。テーブル優先）
@export var rank_ratio_file: String = "rank_ratio.csv"
const RankTableScript: Script = preload("res://ui/rank_table.gd")
var rank_table: RankTable = RankTableScript.new()
@export var rank_consume_multipliers: Array = [                        # RANK→消費倍率（index=rank、1..10）
    0.0,   # dummy (0)
    0.55,  # 1: 村
    0.65,  # 2
    0.78,  # 3
    0.90,  # 4
    1.00,  # 5: 基準
    1.15,  # 6
    1.30,  # 7
    1.50,  # 8
    1.70,  # 9
    2.00   # 10: 大都市
]

func _rank_travel_mult(rank: int) -> float:
    var r: int = clamp(rank, 1, 10)
    if rank_travel_multipliers.size() > r:
        return float(rank_travel_multipliers[r])
    # 足りない場合のフォールバック（とりあえず1.0＝補正なし）
    return 1.0


@export var rank_travel_multipliers: Array = [                  # RANK→旅費・関税の係数（index=rank、1..10）
    0.0,   # dummy (0)
    0.85,  # 1: 村（かなり安い）
    0.90,  # 2
    0.95,  # 3
    1.00,  # 4: やや安い
    1.05,  # 5: 標準クラス
    1.10,  # 6
    1.15,  # 7
    1.20,  # 8
    1.25,  # 9
    1.30   # 10: ハイランク都市（港・大都市）
]


@export var category_base_consume: Dictionary = {  # category→日次ベース（RANK5時の基準）
    "staple": 0.80,   # 主食（小麦/豆/パン等）
    "food":   0.60,   # 食料（魚/チーズ等）
    "drink":  0.50,   # 飲料（エール/ワイン等）
    "textile":0.22,   # 繊維（羊毛/麻等）
    "material":0.15,  # 材料（木材/革/石鹸等）
    "luxury": 0.08,   # 嗜好品
    "general":0.20    # その他
}
@export var consume_base_override: Dictionary = {} # pid→ベース値の上書き（あれば最優先）
var consume_rules: Dictionary = {}                 # pid→{consume_model, period_days, base?}
var _consume_period_cache: Dictionary = {}         # pid→period（最適化）

@export var pay_toll_on_depart: bool = true      # 出発時に通行料を支払う（両端都市に折半）
@export var depart_same_day: bool = false      # 到着日に再出発しない（方針）

# ヒストリ＆速度
@export var history_days: int = 60               # 価格の記録日数
var _speed_mult: float = 1.0                     # 速度倍率（1x/2x/4x）

var day: int = 0


# 当日内の現在ターン（0..turns_per_day-1）
var turn: int = 0
# データ
var products: Dictionary = {}         # pid -> {"name": String, "base": float, "size": int}
var cities: Dictionary = {}           # cid -> {"name": String, "province": String, "note": String, "funds": float}
var routes: Array[Dictionary] = []    # [{"from": String, "to": String, "days": int, "toll": float}]
var adj: Dictionary = {}              # cid -> Array[String]
var stock: Dictionary = {}            # city_id -> pid -> {"qty": float, "target": float, "prod": float, "cons": float}
var price: Dictionary = {}            # city_id -> pid -> float
var history: Dictionary = {}          # city_id -> pid -> Array[float]
var traders: Array[Dictionary] = []   # list of traders

# --- Key Items definitions (key_id -> row Dictionary) ---
var key_items: Dictionary = {}
# === Reputation / Trust ===
@export_range(0.0, 100.0, 0.1) var rep_global: float = 0.0
var rep_by_province: Dictionary = {}
var rep_by_city: Dictionary = {}  # 将来拡張用（現状は未使用）
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

# 週報（Weekly Reports）
var intel_provinces: Array[String] = []
var weekly_reports: Array[Dictionary] = []
var _last_snapshot_by_prov: Dictionary = {}   # prov -> {day, rows}
var _prev_snapshot_by_prov: Dictionary = {}   # ★追加：prov -> {day, rows}（一週前の「先週」）

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
@export var route_hazard_map: Dictionary = {}
@export var hazard_layer_weights: Dictionary = {"bandit":1.0,"terrain":0.8,"weather":0.8,"water":0.9,"politics":0.7}
var route_hazard_layers: Dictionary = {}    # key -> {kind:value}
var route_hazard_deltas: Dictionary = {}    # key -> {kind: Array[Dictionary]}
var route_id_to_key: Dictionary = {}        # "RT01" -> "RE0001-RE0002"
               # 例: { "RE0004-RE0005": 0.6, "RE0002-RE0003": 0.2 }

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

# --- Contracts: settings / state ---
@export var contracts_enabled: bool = true
@export var contracts_offer_min: int = 3
@export var contracts_offer_max: int = 5
@export var contracts_active_limit: int = 3
@export var contracts_deadline_min: int = 8
@export var contracts_deadline_max: int = 20
@export var contracts_reward_k: float = 0.25

var _contracts_rarity_weights := {
    "common": 55.0, "uncommon": 28.0, "rare": 12.0, "epic": 5.0
}

var _contract_offers: Dictionary = {}   # city_id -> Array[Dictionary]
var _contracts_active: Array[Dictionary] = []
var _contracts_next_id: int = 1
var _contracts_last_month_key: String = ""
var _contracts_last_sweep_day: int = -1


# === Weekly Report / Delayed mode switches ===
@export var weekly_report_delayed_mode: bool = true           # ← 遅延モードON/OFF（デフォ OFF）
@export var weekly_report_delayed_include_live: bool = true    # ← 遅延時に“現在値のプレビュー”も併記

# 未充足需要（バックログ）: city_id -> pid -> float
var backlog: Dictionary = {}

# バックログ吸収のON/OFF（ON推奨）
@export var use_backlog_absorption: bool = true

# 価格弾力性（ε）: カテゴリごと。cons = base * pow(mid/base, -ε)
@export var elasticity_by_category: Dictionary = {
    "staple": 0.3,   # 小麦・豆などの主食は鈍い
    "food":   0.4,
    "drink":  0.5,
    "textile":0.6,
    "material":0.4,
    "luxury": 1.0,   # 嗜好品は効きが強い
    "general":0.5
}

@export var supply_min_batch: float = 1.0       # 最小放出ロット（整数化前の閾値）
@export var supply_max_batch: float = 6.0       # 1回の最大放出量（市場へのドカ出し抑制）
@export var supply_cooldown_days: int = 2       # 最低クールダウン（日）
@export var supply_cooldown_jitter: int = 2     # クールダウンに乗る±揺らぎ（日）0なら固定
@export var supply_use_poisson: bool = false    # trueなら指数分布の間隔（上級）
var _supply_sched: Dictionary = {}   # city_id -> pid -> { "buf":float, "next":int, "cool":int, "phase":int }


# 価格更新時に「目標在庫」にバックログを何割足すか（1.0=全量）
@export var backlog_target_weight: float = 1.0

# === Backlog 吸収・蒸発の調整 ===
@export var backlog_absorb_rate: float = 0.50      # 入荷(added)のうち、即時にバックログへ回す比率（0〜1）
@export var backlog_absorb_daily_cap: float = 3.0  # バックログ即時吸収の1日上限（都市×品目）。0で上限なし
@export var backlog_decay_rate: float = 0.03       # バックログの日次自然減（3%/日）。0で減衰なし


# 目標在庫の自動補正（CSV target<=1 のとき、ランク別 safety_days × 平常消費 で補う）
@export var auto_target_fill_enable: bool = true


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
    s = s.replace(" ", "").replace("，", "").replace(",", "")
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
    _normalize_targets_after_load()
    _init_reputation()  # ★追加：評判の入れ物を、都市・プロヴィンス情報から初期化
    build_graph()
    update_prices()
    init_traders()
    init_player()

    _timer = Timer.new()
    _timer.wait_time = day_seconds
    _timer.one_shot = false
    _timer.autostart = false
    add_child(_timer)
    _timer.timeout.connect(_on_day_tick)
    set_speed(1.0)

    _paused = true
    _log("World ready. Cities=%d, Products=%d, Routes=%d" % [cities.size(), products.size(), routes.size()])
    day = _calc_day_index_for_start(start_month, start_dom)
    world_updated.emit()


func set_speed(m: float) -> void:
    _speed_mult = clamp(m, 0.25, 8.0)
    if _timer:
        _timer.wait_time = day_seconds / _speed_mult

func _on_day_tick() -> void:
    if _paused:
        return
    step_one_turn()



func step_one_turn() -> void:
    # 1ターン進める。最終ターンの次は日付を進める。
    turn += 1
    if turn < max(1, turns_per_day):
        turn_advanced.emit(turn, day)
        world_updated.emit()
        return
    # ターンが規定数に達したので翌日に進める
    turn = 0
    step_one_day()
func step_one_day() -> void:
    turn = 0
    # 日付を進め、イベント→（Dice可視化ならHUDへ委譲）→日次処理
    day += 1
    _effects_tick_down()
    if weekly_report_on_morning and ((day - 1) % max(1, weekly_report_interval_days) == 0):
        _generate_weekly_reports()
    if use_event_dice:
        # HUD 側で可視ダイス→resolve→finalize_day() を呼ぶ
        day_advanced.emit(day)
        return
    # 旧式（可視ダイスなし）: World 内で即ロール→解決→日次処理
    _roll_daily_event()
    _roll_travel_event_for_player()
    finalize_day()

func _decay_backlog_daily() -> void:
    if backlog_decay_rate <= 0.0:
        return
    for cid in backlog.keys():
        var d: Dictionary = backlog[cid]
        for pid in d.keys():
            var cur: float = float(d[pid])
            if cur > 0.0:
                var dec: float = cur * backlog_decay_rate
                d[pid] = max(0.0, cur - dec)
        backlog[cid] = d

func finalize_day() -> void:
    # 生産/消費 → 供給 → 価格 → 市・屋台 → NPC → プレイヤー到着 → 劣化 → 通知
    _decay_backlog_daily()  # ← 追加：バックログを日次で少し蒸発させる
    for city_id in stock.keys():
        for pid in stock[city_id].keys():
            var rec: Dictionary = stock[city_id][pid]

            # 需要（Elasticity を含む基礎関数で算出）
            var demand: float = _consumption_for_today(city_id, pid)
            stock[city_id][pid]["cons"] = demand

            # 1) 生産の取り込み: まず backlog の即時吸収、残りのみ在庫へ
            var cal := get_calendar()
            var _m: int = int(cal.get("month", 1))
            var base_prod_today: float = float(rec.get("prod", 0.0))
            _enqueue_prod(city_id, pid, base_prod_today)   # ← バッファへ
            _try_release_batches(city_id, pid)             # ← 条件成立時だけ市場に出す

            # 2) 当日の販売（市場在庫から需要ぶんだけ減る）
            var have: float = float(stock[city_id][pid].get("qty", 0.0))
            var sold: float = min(have, demand)
            have -= sold
            stock[city_id][pid]["qty"] = have

            # 3) 残需要は backlog に積む
            var unmet: float = max(0.0, demand - sold)
            if use_backlog_absorption and unmet > 0.0:
                _ensure_backlog_record(city_id, pid)
                backlog[city_id][pid] = float(backlog[city_id].get(pid, 0.0)) + unmet

    # 追加: ランダム供給（既存機能）
    if enable_auto_supply:
        _apply_supply_events()

    update_prices()

    if enable_fairs:
        _tick_fairs()
    if enable_stalls:
        _process_auto_sales()

    # NPC商人の到着＆出発
    for t in traders:
        var just_arrived: bool = bool(t.get("enroute", false)) and int(t.get("arrival_day", 0)) <= day
        if just_arrived:
            _arrive_and_trade(t)

        if not bool(t.get("enroute", false)) and (depart_same_day or not just_arrived):
            var city_id: String = String(t.get("city", ""))
            if city_id != "":
                var plan: Dictionary = _best_trade_from(city_id, t)
                _plan_and_depart(t, plan)

    if bool(player.get("enroute", false)) and int(player.get("arrival_day", 0)) <= day:
        _player_arrive()

    if enable_player_decay:
        _apply_player_decay()

    day_advanced.emit(day)
    world_updated.emit()
    _log_day_summary()
    if log_daily_supply_count:
        _log_supply_daily_count()



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

# --- UI / System message helper ---
func send_system_message(msg: String) -> void:
    # UI側から呼ぶための公開口。Story側の _world_message と同じ挙動。
    _world_message(msg)

# --- Tutorial API ---
func get_tutorial_state() -> String:
    return tutorial_state

func set_tutorial_state(state: String, apply_profile: bool = false, log_reason: String = "") -> void:
    var prev := tutorial_state
    tutorial_state = state
    if apply_profile:
        apply_tutorial_profile(state)
    if log_reason != "":
        _log("[TUT] state %s -> %s (%s)" % [prev, tutorial_state, log_reason])
    else:
        _log("[TUT] state %s -> %s" % [prev, tutorial_state])
    tutorial_state_changed.emit(prev, tutorial_state)
    # UIが状態変化を拾えるように（MenuPanel が world_updated に繋いでいる）
    world_updated.emit()

func get_tutorial_locks() -> Dictionary:
    return tutorial_locks.duplicate(true)

func is_tutorial_locked(key: String) -> bool:
    return tutorial_locks.has(key)

func get_tutorial_lock_reason(key: String) -> String:
    if not tutorial_locks.has(key):
        return ""
    return String(tutorial_locks.get(key, ""))

func set_tutorial_lock(key: String, locked: bool, reason: String = "") -> void:
    var changed := false
    if locked:
        if not tutorial_locks.has(key) or String(tutorial_locks.get(key, "")) != reason:
            tutorial_locks[key] = reason
            changed = true
    else:
        if tutorial_locks.has(key):
            tutorial_locks.erase(key)
            changed = true
    if changed:
        var flag := "OFF"
        if locked:
            flag = "ON"
        _log("[TUT] lock %s=%s" % [key, flag])
        tutorial_locks_changed.emit(get_tutorial_locks())
        world_updated.emit()
func clear_tutorial_locks() -> void:
    if tutorial_locks.is_empty():
        return
    tutorial_locks.clear()
    _log("[TUT] locks cleared")
    tutorial_locks_changed.emit(get_tutorial_locks())
    world_updated.emit()

func apply_tutorial_profile(state: String) -> void:
    # 状態に応じた“デフォルトロック”を適用（必要になったら拡張）
    # ここは台本に合わせて随時調整していく前提。
    clear_tutorial_locks()
    match state:
        TUT_STATE_PROLOGUE:
            # プロローグ中は操作させない（誤操作で台本が破綻しないように）
            set_tutorial_lock(TUT_LOCK_TRADE, true, "プロローグ中はまだ取引できません。")
            set_tutorial_lock(TUT_LOCK_MAP, true, "プロローグ中はまだ地図を開けません。")
            set_tutorial_lock(TUT_LOCK_MOVE, true, "プロローグ中はまだ移動できません。")
            set_tutorial_lock(TUT_LOCK_INV, true, "プロローグ中はまだ所持品を確認できません。")
            set_tutorial_lock(TUT_LOCK_INFO, true, "プロローグ中はまだ情報を確認できません。")
            set_tutorial_lock(TUT_LOCK_CONTRACT, true, "プロローグ中はまだ契約を確認できません。")
            set_tutorial_lock(TUT_LOCK_TRUST, true, "プロローグ中はまだ信用を確認できません。")
            set_tutorial_lock(TUT_LOCK_STEP, true, "プロローグ中は時間を進められません。")
            set_tutorial_lock(TUT_LOCK_STEP_TURN, true, "プロローグ中は時間を進められません。")
        _:
            pass

func get_day_progress() -> float:
    if _paused or _timer == null or _timer.wait_time <= 0.0:
        return 0.0
    var tl: float = _timer.time_left
    var wt: float = _timer.wait_time
    var prog: float = 1.0 - (tl / wt)
    return clamp(prog, 0.0, 1.0)

func _dice_tier_from_roll(roll: int) -> String:
    # 1..100 を tier にマップ
    var r: int = clamp(roll, 1, 100)
    if r == 1:
        return "marvelous"
    elif r <= 5:
        return "great"
    elif r <= 15:
        return "good"
    elif r <= 85:
        return "normal"
    elif r <= 95:
        return "bad"
    elif r <= 99:
        return "worst"
    else:
        return "critical"


# ---- Event Dice API (d100 可視化前提) ----
func begin_roll(kind: String) -> int:
    var roll: int = randi_range(1, 100)
    _last_roll_kind = kind
    _last_roll_value = roll
    if log_event_dice:
        _dice_debug("BeginRoll kind=%s roll=%02d" % [kind, roll])
    return roll

func resolve_daily_with_roll(roll: int) -> void:
    var tier: String = _dice_tier_from_roll(roll)
    if tier == "normal":
        _world_message("今日は特に何も起こらなかった。")
        return
    var ev: Dictionary = _pick_daily_event_for_tier(tier)
    if ev.is_empty():
        # フォールバック（旧テーブル互換）
        ev = _pick_daily_event()
    if ev.is_empty():
        _world_message("今日は特に何も起こらなかった。")
        return
    _apply_daily_event(ev)

func resolve_travel_with_roll(roll: int, q: float = -1.0) -> void:
    if not bool(player.get("enroute", false)):
        return
    var origin := String(player.get("city", ""))
    var dest := String(player.get("dest", ""))
    var key: String = ""
    if has_method("_route_key"):
        key = _route_key(origin, dest)
    var layers: Dictionary = {}
    if "route_hazard_layers" in self:
        layers = route_hazard_layers.get(key, {}) as Dictionary
    var tier: String = _dice_tier_from_roll(roll)
    if tier == "normal":
        _world_message("道中は平穏そのものだった。")
        return
    var ev: Dictionary = _pick_travel_event_for_tier_layers(tier, layers)
    if ev.is_empty():
        ev = _pick_travel_event_outcome()
    if ev.is_empty():
        _world_message("小さなトラブルはあったが問題なく進めた。")
        return
    _apply_travel_outcome(ev)

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




# ---- Rumor API (情報コマンド用) ----
# 噂エントリの例:
# { "id":"rumor_xxx", "kind":"price_mult", "target_city":"RE0001", "target_pid":"PR03", "value":1.15, "duration":7, "flavor_ja":"Durtonで魚が値上がりしている。（一定期間買値上昇）" }
# { "id":"rumor_y",   "kind":"stock_burst", "target_city":"RE0003", "target_pid":"PR01", "qty":8, "flavor_ja":"Piltonで小麦が多く入荷している。（在庫上昇）" }
func generate_rumors(current_city: String, count: int = 3) -> Array[Dictionary]:
    var res: Array[Dictionary] = []
    if products.is_empty() or cities.is_empty():
        return res
    var cids: Array = []
    for __id in cities.keys():
        var __s := String(__id)
        if is_city_unlocked(__s): cids.append(__s)
        cids.shuffle()
    var pids: Array = products.keys()
    pids.shuffle()
    for i in range(max(1, count)):
        # city: 現在地を優先、次点でランダム
        var cid: String = current_city if current_city != "" else String(cids[i % cids.size()])
        # product: 当該都市に在庫レコードがあればそれを優先
        var pid: String = ""
        if stock.has(cid):
            var keys: Array = (stock[cid] as Dictionary).keys()
            if keys.size() > 0:
                pid = String(keys[randi() % keys.size()])
        if pid == "":
            pid = String(pids[i % pids.size()])
        # effect type
        var kind_roll: int = randi_range(0, 2)
        if kind_roll == 0:
            # 買い・売りともに上昇（中間価格倍率）
            var mult: float = 1.10 + randf() * 0.15 # 1.10〜1.25
            var dur: int = 5 + randi() % 8         # 5〜12日
            var rumor := {
                "id": "rumor_price_%02d" % i,
                "kind": "price_mult",
                "target_city": cid,
                "target_pid": pid,
                "value": mult,
                "duration": dur,
                "flavor_ja": _format_rumor_price(cid, pid, mult, dur)
            }
            res.append(rumor)
        elif kind_roll == 1:
            # 在庫が増える
            var qty: int = 4 + randi() % 12       # +4〜+15
            var rumor2 := {
                "id": "rumor_stock_%02d" % i,
                "kind": "stock_burst",
                "target_city": cid,
                "target_pid": pid,
                "qty": qty,
                "flavor_ja": _format_rumor_stock(cid, pid, qty)
            }
            res.append(rumor2)
        else:
            # 嗜好・流行（価格上昇の別表現）
            var mult2: float = 1.10 + randf() * 0.20 # 1.10〜1.30
            var dur2: int = 6 + randi() % 10        # 6〜15日
            var rumor3 := {
                "id": "rumor_trend_%02d" % i,
                "kind": "price_mult",
                "target_city": cid,
                "target_pid": pid,
                "value": mult2,
                "duration": dur2,
                "flavor_ja": _format_rumor_trend(cid, pid, mult2, dur2)
            }
            res.append(rumor3)
    return res

func apply_rumor(r: Dictionary, truth_prob: float = 1.0, false_mode: String = "none") -> void:
    if randf() > clamp(truth_prob, 0.0, 1.0):
        var msgf := String(r.get("flavor_ja", "噂")) + "…は誤報だった。"
        _world_message(msgf)
        supply_event.emit(String(r.get("target_city","")), String(r.get("target_pid","")), 0, "rumor_false", msgf)
        world_updated.emit()
        return

    var kind := String(r.get("kind", ""))
    if kind == "price_mult":
        var e := {
            "kind":"price_mult",
            "target_city": String(r.get("target_city","*")),
            "target_pid": String(r.get("target_pid","*")),
            "price_mult": float(r.get("value", 1.0)),
            "remain": int(r.get("duration", 7)),
            "src_id": String(r.get("id","rumor"))
        }
        _effects_active.append(e)
        var cid := String(r.get("target_city",""))
        var pid := String(r.get("target_pid",""))
        var msg := String(r.get("flavor_ja", ""))
        if msg != "": _world_message(msg)
        update_prices()
        supply_event.emit(cid, pid, 0, "rumor", msg)
        world_updated.emit()
    elif kind == "stock_burst":
        var cid2 := String(r.get("target_city",""))
        var pid2 := String(r.get("target_pid",""))
        var qty := int(r.get("qty", 0))
        if cid2 != "" and pid2 != "" and qty > 0:
            _ensure_stock_record(cid2, pid2)
            _add_stock_inflow(cid2, pid2, float(qty))
            update_prices()
            var msg2 := String(r.get("flavor_ja", ""))
            if msg2 != "": _world_message(msg2)
            supply_event.emit(cid2, pid2, qty, "rumor", msg2)
            world_updated.emit()

func _format_rumor_price(cid: String, pid: String, mult: float, days: int) -> String:
    var cname: String = String(cities.get(cid, {}).get("name", cid))
    var pname: String = get_product_name(pid)
    return "%sで%sが値上がりしている。（%d日間 価格上昇）" % [cname, pname, days]

func _format_rumor_stock(cid: String, pid: String, q: int) -> String:
    var cname: String = String(cities.get(cid, {}).get("name", cid))
    var pname: String = get_product_name(pid)
    return "%sで%sが多く入荷している。（在庫 +%d）" % [cname, pname, q]

func _format_rumor_trend(cid: String, pid: String, mult: float, days: int) -> String:
    var cname: String = String(cities.get(cid, {}).get("name", cid))
    var pname: String = get_product_name(pid)
    return "%sで%sが流行している。（%d日間 価格上昇）" % [cname, pname, days]

# --- Unlock フラグ（暫定：空なら全都市解放扱い） ---
var unlocked_city_ids: Array = []  # Array[String]
func is_city_unlocked(cid: String) -> bool:
    if unlocked_city_ids.is_empty():
        return true
    return unlocked_city_ids.has(cid)

# --- Rank/Consumption helpers ---
func _rank_consume_mult(rank: int) -> float:
    var r: int = clamp(rank, 1, 10)
    if rank_table and rank_table.has_data:
        return rank_table.get_cons_mult(r, rank_consume_multipliers[r])
    if rank_consume_multipliers.size() >= 11:
        return float(rank_consume_multipliers[r])
    return 1.0 + rank_consume_k * float(r - 5)



func _consume_base_for(pid: String) -> float:
    if consume_base_override.has(pid):
        return float(consume_base_override[pid])
    var cat := String(product_category.get(pid, "general"))
    return float(category_base_consume.get(cat, category_base_consume.get("general", 0.2)))

func _consumption_for_today(cid: String, pid: String) -> float:
    # 基礎: カテゴリ基準 × ランク倍率
    var base: float = _consume_base_for(pid)
    var rank: int = int(cities.get(cid, {}).get("rank", 3))
    var per_day: float = base * _rank_consume_mult(rank)

    # 価格弾力性: cons = per_day * pow(mid/base_price, -ε)
    var eps: float = 0.0
    if elasticity_by_category != null and elasticity_by_category.size() > 0:
        var cat: String = String(product_category.get(pid, "general"))
        if elasticity_by_category.has(cat):
            eps = float(elasticity_by_category.get(cat, 0.0))
    if eps != 0.0:
        var base_price: float = 1.0
        if products.has(pid):
            base_price = max(1.0, float(products[pid].get("base", 1.0)))
        var mid: float = get_mid_price(cid, pid)
        var ratio: float = mid / base_price
        # Godot の pow は pow(a,b)
        per_day = per_day * pow(ratio, -eps)

    # ルール: periodic はバッチ消費
    var rule: Dictionary = consume_rules.get(pid, {})
    var model: String = String(rule.get("consume_model", "per_day"))
    if model == "periodic":
        var period: int = int(rule.get("period_days", _consume_period_cache.get(pid, 1)))
        if period <= 1:
            return per_day
        if (day % period) == 0:
            return per_day * float(period)
        else:
            return 0.0

    return per_day

# 都市別税率（RANK反映）
func get_trade_tax_rate(city_id: String = "") -> float:
    var r: float = trade_tax_rate
    for e_any in _effects_active:
        var e: Dictionary = e_any
        if String(e.get("kind","")) == "tax_offset":
            r += float(e.get("tax_delta", 0.0))
    r = clamp(r, 0.0, 0.5)
    if city_id != "":
        var rank := int(cities.get(city_id, {}).get("rank", 5))
        var mult := 1.0 + rank_tax_k * float(rank - 5)
        r = clamp(r * mult, 0.0, 0.5)
    return r

func _rank_prod_bonus(rank: int) -> float:
    var r : int = clamp(rank, 1, 10)
    if rank_table and rank_table.has_data:
        return rank_table.get_prod_bonus(r, 0.0) # 小数(0.25=+25%)
    return 0.0

func _rank_safety_days(rank: int) -> float:
    var r : int = clamp(rank, 1, 10)
    if rank_table and rank_table.has_data:
        return rank_table.get_safety_days(r, 10.0)
    return 10.0



func _pick_daily_event() -> Dictionary:
    # 現行テーブルから weight>0 の中から "none" を除外して抽選
    var total: float = 0.0
    for r_any in _events_daily:
        if String(r_any.get("kind","none")) == "none":
            continue
        total += float(r_any.get("weight", 0.0))
    if total <= 0.0:
        return {}
    var pick := randf() * total
    var acc := 0.0
    for r_any2 in _events_daily:
        if String(r_any2.get("kind","none")) == "none":
            continue
        acc += float(r_any2.get("weight", 0.0))
        if pick <= acc:
            return r_any2
    return {}

func _apply_daily_event(chosen: Dictionary) -> void:
    var kind := String(chosen.get("kind","none"))
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

func _pick_travel_event_outcome() -> Dictionary:
    # ひとまず既存の events_travel.csv から "none" を除外して抽選
    var total: float = 0.0
    for r_any in _events_travel:
        if String(r_any.get("kind","none")) == "none":
            continue
        total += float(r_any.get("weight", 0.0))
    if total <= 0.0:
        return {}
    var pick := randf() * total
    var acc := 0.0
    for r_any2 in _events_travel:
        if String(r_any2.get("kind","none")) == "none":
            continue
        acc += float(r_any2.get("weight", 0.0))
        if pick <= acc:
            return r_any2
    return {}

func _apply_travel_outcome(chosen: Dictionary) -> void:
    var kind := String(chosen.get("kind","none"))
    var val := float(chosen.get("value", 0.0))
    if kind == "days_delta":
        var arrive := int(player.get("arrival_day", day))
        arrive = max(day + 1, arrive + int(round(val)))
        player["arrival_day"] = arrive
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
    var msg := String(chosen.get("flavor_ja", ""))
    if msg != "":
        _world_message(msg)
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
        ,
            "rank": int(_num(row2.get("CityRANK", row2.get("rank", 3))))
        }

    # routes
    routes.clear()
    var route_rows: Array[Dictionary] = _loader.load_csv_dicts(data_dir + "routes.csv")
    for rr_any in route_rows:
        var rr: Dictionary = rr_any
        routes.append({
            "route_id": String(rr.get("route_id", "")),
            "from": String(rr.get("from", "")),
            "to": String(rr.get("to", "")),
            "days": int(_num(rr.get("days", 1))),
            "toll": float(_num(rr.get("toll", 0.0)))

        })
        var _rid := String(rr.get("route_id", ""))
        if _rid != "":
            route_id_to_key[_rid] = _route_key(String(rr.get("from","")), String(rr.get("to","")))



    # route hazards (optional CSV)
    var rh_path := data_dir + "route_hazards.csv"
    if FileAccess.file_exists(rh_path):
        var rh_rows: Array[Dictionary] = _loader.load_csv_dicts(rh_path)
        route_hazard_layers.clear()
        for rh_any in rh_rows:
            var rdh: Dictionary = rh_any
            var rid: String = String(rdh.get("route_id", ""))
            var key2: String = ""
            if rid != "":
                key2 = _route_key_from_route_id(rid)
            if key2 == "":
                var fa := String(rdh.get("from", ""))
                var tb := String(rdh.get("to", ""))
                if fa != "" and tb != "":
                    key2 = _route_key(fa, tb)
            if key2 == "":
                continue
            var layers: Dictionary = {}
            for k in hazard_layer_weights.keys():
                layers[k] = clamp(float(_num(rdh.get(k, 0.0))), 0.0, 1.0)
            route_hazard_layers[key2] = layers
        # Build base hazard map from layers
        route_hazard_map.clear()
        for r in routes:
            var key3 := _route_key(String(r["from"]), String(r["to"]))
            var bl: Dictionary = route_hazard_layers.get(key3, {})
            route_hazard_map[key3] = _combine_hazard_layers(bl)

    # --- 消費ルール読込（pidごと） ---
    consume_rules.clear()
    _consume_period_cache.clear()
    var cr_path := data_dir + consume_rules_file
    if FileAccess.file_exists(cr_path):
        var cr_rows: Array[Dictionary] = _loader.load_csv_dicts(cr_path)
        for cr_any in cr_rows:
            var cr: Dictionary = cr_any
            var pidc: String = String(cr.get("product_id",""))
            if pidc == "": continue
            var model: String = String(cr.get("consume_model", "per_day")).to_lower()
            var pd: int = int(_num(cr.get("period_days", cr.get("period", 1))))
            var base_override: float = float(_num(cr.get("base_per_day", 0.0)))
            consume_rules[pidc] = {"consume_model": model, "period_days": max(1, pd)}
            if base_override > 0.0:
                consume_base_override[pidc] = base_override
            _consume_period_cache[pidc] = max(1, pd)
        _load_rank_ratio()
        # stock/price
        stock.clear()

    price.clear()
    history.clear()
    for cid in cities.keys():
        stock[cid] = {}
        price[cid] = {}
        history[cid] = {}
    var _stock_path := (data_dir + "city_stock_minimal.csv") if FileAccess.file_exists(data_dir + "city_stock_minimal.csv") else (data_dir + "city_stock.csv")
    var st_rows: Array[Dictionary] = _loader.load_csv_dicts(_stock_path)
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

    # --- 大切なもの（Key Items）定義 ---
    key_items.clear()
    var ki_path := data_dir + key_items_file
    if FileAccess.file_exists(ki_path):
        var ki_rows: Array[Dictionary] = _loader.load_csv_dicts(ki_path)
        for ki_any in ki_rows:
            var ki: Dictionary = ki_any
            var kid: String = String(ki.get("key_id", ki.get("id", "")))
            if kid == "":
                continue
            key_items[kid] = ki

func _init_reputation() -> void:
    # 0〜100に正規化
    rep_global = clamp(rep_global, 0.0, 100.0)

    if rep_by_province == null:
        rep_by_province = {}
    if rep_by_city == null:
        rep_by_city = {}

    # 都市一覧からプロヴィンス名を拾って rep_by_province を初期化
    # 既に値が入っているキーはそのまま温存し、新しいプロヴィンスだけ 0.0 で追加する。
    for cid in cities.keys():
        var info: Dictionary = cities.get(cid, {})
        var prov := String(info.get("province", ""))
        if prov == "":
            continue
        if not rep_by_province.has(prov):
            rep_by_province[prov] = 0.0


func build_graph() -> void:
    adj.clear()
    for cid in cities.keys():
        adj[cid] = []
    for r in routes:
        var a: String = String(r["from"])
        var b: String = String(r["to"])
        if not adj.has(a): adj[a] = []
        if not adj.has(b): adj[b] = []
        var la: Array = adj[a]; if not la.has(b): la.append(b)
        var lb: Array = adj[b]; if not lb.has(a): lb.append(a)

func update_prices() -> void:
    for c in cities.keys():
        for pid in products.keys():
            var base_price: float = float(products[pid]["base"])
            var rec_any: Variant = null
            if stock.has(c):
                rec_any = (stock[c] as Dictionary).get(pid, null)

            if rec_any == null:
                price[c][pid] = base_price
                _update_shortage_ema(c, pid, 0.0)
            else:
                var rd: Dictionary = rec_any
                var target: float = max(1.0, float(rd.get("target", 1.0)))
                var qty: float = max(0.0, float(rd.get("qty", 0.0)))

                var b: float = 0.0
                if use_backlog_absorption and backlog.has(c):
                    var bd: Dictionary = backlog[c]
                    if bd.has(pid):
                        b = float(bd[pid])

                var virt_target: float = max(1.0, target + backlog_target_weight * b)
                var diff: float = virt_target - qty
                var mult: float = 1.0 + price_k * (diff / virt_target)
                mult = clamp(mult, min_mult, max_mult)

                var eff := _price_mult_for(c, pid)
                price[c][pid] = max(1.0, base_price * mult * eff)

                var s_tmp: float = 0.0
                if virt_target > 0.0:
                    s_tmp = max(0.0, 1.0 - (qty / virt_target))
                _update_shortage_ema(c, pid, s_tmp)

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
        _add_stock_inflow(String(t["city"]), String(pid), float(qty))
        _update_price_for(String(t["city"]), String(pid))
        var gross: float = qty * get_bid_price(t["city"], pid)
        var tax: float = gross * get_trade_tax_rate(String(t["city"]))
        var revenue: float = gross - tax
        t["cash"] = float(t["cash"]) + revenue
        t["cargo"][pid] = 0
        cities[t["city"]]["funds"] = float(cities[t["city"]]["funds"]) + tax
        _log("%s sold %s x%d @%.1f in %s (+%.1f, tax %.1f)" % [t["id"], pid, int(qty), get_bid_price(t["city"], pid), t["city"], revenue, tax])


func _plan_and_depart(t: Dictionary, plan: Dictionary) -> void:
    if plan.is_empty():
        return

    var city: String = String(t.get("city", ""))
    var dest: String = String(plan.get("dest", ""))
    var pid: String = String(plan.get("pid", ""))
    var qty: int = int(plan.get("qty", 0))

    if city == "" or dest == "" or pid == "" or qty <= 0:
        return
    if not adj.has(city) or not (dest in (adj[city] as Array)):
        return

    if not t.has("cargo"):
        t["cargo"] = {}

    var cash_now: float = float(t.get("cash", 0.0))

    # 在庫・容量側の上限
    _ensure_stock_record(city, pid)
    var avail: int = int(floor(float(stock[city][pid]["qty"])))
    var unit_size: int = int(products[pid].get("size", 1))
    var cap_free: int = max(0, int(t.get("cap", 0)) - _cargo_used(t))
    var max_by_cap: int = cap_free / max(1, unit_size)
    qty = max(0, min(qty, avail, max_by_cap))
    if qty <= 0:
        return

    var ask_price: float = get_ask_price(city, pid)

    # 候補数量で「購入＋移動コスト」を払えるか確認して調整
    var cap_used_after: int = _cargo_used(t) + qty * unit_size
    var edge_cost: Dictionary = _calc_edge_travel_cost(city, dest, cap_used_after)
    var travel_total: float = float(edge_cost.get("total", 0.0))

    var max_by_cash: int = int(floor((cash_now - travel_total) / max(1.0, ask_price)))
    qty = max(0, min(qty, max_by_cash))
    if qty <= 0:
        return

    # 最終チェック（安全側にもう一度計算）
    cap_used_after = _cargo_used(t) + qty * unit_size
    edge_cost = _calc_edge_travel_cost(city, dest, cap_used_after)
    travel_total = float(edge_cost.get("total", 0.0))

    if cash_now < float(qty) * ask_price + travel_total:
        return

    # 実際の取引
    stock[city][pid]["qty"] = float(stock[city][pid]["qty"]) - float(qty)
    t["cash"] = cash_now - float(qty) * ask_price
    t["cargo"][pid] = int(t["cargo"].get(pid, 0)) + qty
    _update_price_for(city, pid)

    var days_cost: int = int(edge_cost.get("days", _route_days(city, dest)))
    t["dest"] = dest
    t["arrival_day"] = day + days_cost
    t["enroute"] = true

    # 旅費支払い＋到着都市へ反映
    if travel_total > 0.0:
        t["cash"] = max(0.0, float(t["cash"]) - travel_total)
        if cities.has(dest):
            cities[dest]["funds"] = float(cities[dest].get("funds", 0.0)) + travel_total

    _log("%s depart %s -> %s carrying %s x%d (profit≈%.1f)" % [
        t.get("id", "?"),
        city,
        dest,
        pid,
        qty,
        float(plan.get("profit", 0.0))
    ])


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
                _add_stock_inflow(cid, pid, float(q))
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
            return float(r.get("toll", 0.0))
    return 0.0
func _get_mid_with_lag(c: String, pid: String, lag_days: int) -> float:
    # ヒストリからlag_daysだけ遅れたミッドを取得（無ければ現在値/基準）
    if history.has(c) and (history[c] as Dictionary).has(pid):
        var arr: Array = history[c][pid]
        if arr.size() > 0:
            var idx: int = max(0, arr.size() - 1 - max(lag_days, 0))
            return float(arr[idx])
    return float(price.get(c, {}).get(pid, float(products.get(pid, {}).get("base", 1.0))))

func _best_neighbor_mid_with_delay_minus_cost(c: String, pid: String) -> float:
    # 近隣都市の「遅延ミッド − 通行料」の最大値を返す（見つからなければ自都市の現在値）
    var best: float = float(price.get(c, {}).get(pid, float(products.get(pid, {}).get("base", 1.0))))
    if not adj.has(c):
        return best
    for nb_any in (adj[c] as Array):
        var nb: String = String(nb_any)
        var d: int = _route_days(c, nb)
        var toll: float = _route_toll(c, nb)
        var mid_delayed: float = _get_mid_with_lag(nb, pid, d)
        var val: float = mid_delayed - toll
        if val > best:
            best = val
    return best

func _alpha_for(pid: String) -> float:
    var cat: String = String(products.get(pid, {}).get("category", "other")).to_lower()
    match cat:
        "fresh":
            return 0.40
        "grain", "food":
            return 0.15
        "cloth", "textile":
            return 0.08
        "spice", "dye":
            return 0.05
        "metal", "ore":
            return 0.03
        _:
            return 0.10

func _beta_for(pid: String) -> float:
    var cat: String = String(products.get(pid, {}).get("category", "other")).to_lower()
    match cat:
        "fresh":
            return 0.30
        "grain", "food":
            return 0.40
        "cloth", "textile":
            return 0.40
        "spice", "dye":
            return 0.50
        "metal", "ore":
            return 0.60
        _:
            return 0.40
func _update_price_for(c: String, pid: String) -> void:
    if not products.has(pid):
        return
    if not price.has(c):
        price[c] = {}
    var base: float = float(products[pid]["base"])
    var eff_mult: float = _price_mult_for(c, pid)
    var local_target: float = max(1.0, base * eff_mult)
    var s_for_spread: float = 0.0
    var rec: Variant = null
    if stock.has(c):
        rec = (stock[c] as Dictionary).get(pid, null)
    if rec != null:
        var rd: Dictionary = rec
        var target: float = max(1.0, float(rd.get("target", 1.0)))
        var qty: float = max(0.0, float(rd.get("qty", 0.0)))
        var diff: float = target - qty
        var mult: float = clamp(1.0 + price_k * (diff / target), min_mult, max_mult)
        local_target = max(1.0, base * mult * eff_mult)
        s_for_spread = max(0.0, 1.0 - (qty / target))
    # external signal + inertia
    var prev: float = float(price.get(c, {}).get(pid, local_target))
    var target_mid: float = local_target
    if enable_external_signal:
        var best_nb := _best_neighbor_mid_with_delay_minus_cost(c, pid)
        var ext_diff := best_nb - local_target
        target_mid = max(1.0, local_target + _beta_for(pid) * ext_diff)
    if enable_price_inertia:
        var a: float = clamp(_alpha_for(pid), 0.0, 1.0)
        price[c][pid] = prev + (target_mid - prev) * a
    else:
        price[c][pid] = target_mid
    _update_shortage_ema(c, pid, s_for_spread)
    # history append for delayed references
    if not history.has(c):
        history[c] = {}
    var arr: Array = history[c].get(pid, [])
    arr.append(price[c][pid])
    if arr.size() > history_days:
        arr.pop_front()
    history[c][pid] = arr
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

func _world_message(txt: String) -> void:
    if txt == "":
        return
    # 受け渡しID（都市名/商品名など）をローカライズしてから通知
    if has_method("humanize_ids"):
        txt = humanize_ids(txt)
    _log(txt)

    # UI側で「システムメッセージ」として扱えるよう mode を system に統一
    supply_event.emit("", "", 0, "system", txt)

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
        "key_items": {},
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
    contracts_try_auto_deliver_at(String(player.get("city","")))

enum MoveErr { OK, ARRIVED_TODAY, NOT_ADJACENT, LACK_CASH }

func can_player_move_to(dest: String) -> Dictionary:
    var a: String = String(player.get("city", ""))
    if int(player.get("last_arrival_day", -999)) == day:
        return {"ok": false, "err": MoveErr.ARRIVED_TODAY}
    if not adj.has(a) or not (dest in (adj[a] as Array)):
        return {"ok": false, "err": MoveErr.NOT_ADJACENT}
    var cap_used: int = _cargo_used(player)
    var breakdown: Dictionary = _calc_edge_travel_cost(a, dest, cap_used)
    var days: int = int(breakdown.get("days", 1))
    var total_cost: float = float(breakdown.get("total", 0.0))
    if float(player.get("cash", 0.0)) < total_cost:
        return {"ok": false, "err": MoveErr.LACK_CASH, "need": total_cost, "days": days, "breakdown": breakdown}
    return {"ok": true, "need": total_cost, "days": days, "breakdown": breakdown}

func player_move(dest: String) -> bool:
    # 1ステップ移動も player_move_via に統一して扱う
    if bool(player.get("enroute", false)):
        return false
    if int(player.get("last_arrival_day", -999)) == day:
        return false

    var a: String = String(player.get("city", ""))
    if a == "" or dest == "":
        return false
    if not adj.has(a) or not (dest in (adj[a] as Array)):
        return false

    var path: Array[String] = [a, dest]
    return player_move_via(dest, path)


# ---- Path & multi-hop travel (new) ----
func path_exists(a: String, b: String) -> bool:
    if a == b:
        return true
    if not adj.has(a) or not adj.has(b):
        return false
    var q: Array[String] = []
    var visited: Dictionary = {}
    q.append(a); visited[a] = true
    while q.size() > 0:
        var cur: Variant = q.pop_front()
        if String(cur) == b:
            return true
        for nb_any in adj.get(String(cur), []):
            var nb := String(nb_any)
            if not visited.has(nb):
                visited[nb] = true
                q.append(nb)
    return false

func _travel_tax_multiplier_for_city(city_id: String) -> float:
    # 大切なもの key_items.csv の効果による「通行税・関税」倍率
    var mult: float = 1.0
    if player == null:
        return mult
    var inv_any: Variant = player.get("key_items", {})
    if typeof(inv_any) != TYPE_DICTIONARY:
        return mult
    var inv: Dictionary = inv_any as Dictionary
    if inv.is_empty() or key_items.is_empty():
        return mult

    var province: String = ""
    if cities.has(city_id):
        province = String(cities[city_id].get("province", ""))

    for kid_any in inv.keys():
        var kid: String = String(kid_any)
        var count: int = int(inv.get(kid, 0))
        if count <= 0:
            continue
        if not key_items.has(kid):
            continue

        var def: Dictionary = key_items[kid] as Dictionary
        var effect_type: String = String(def.get("effect_type", "")).to_lower()
        if effect_type != "travel_tax_mult":
            continue

        var target: String = String(def.get("effect_target", ""))
        if target != "" and target != city_id and target != province:
            continue

        var value: float = float(_num(def.get("effect_value", 1.0)))
        if value <= 0.0:
            continue

        for i in range(count):
            mult *= value
    return mult

func _calc_edge_travel_cost(u: String, v: String, cap_used: int) -> Dictionary:
    # u→v を移動するときのコストをまとめて計算するヘルパー
    var days: int = _route_days(u, v)
    if days <= 0:
        days = 1

    var rank: int = 5
    if cities.has(v):
        rank = int(cities[v].get("rank", 5))
    var rank_mult: float = _rank_travel_mult(rank)

    # 宿代・馬の餌代みたいな「日数ベースのコスト」をRANKで重くする
    var travel: float = travel_cost_per_day * float(days) * rank_mult

    # 積載容量ベースの通行税・関税（価格ではなく容量）
    var cap_u: int = max(0, cap_used)
    var tax: float = travel_tax_per_cap * float(cap_u) * rank_mult
    var tax_mult: float = _travel_tax_multiplier_for_city(v)
    tax *= tax_mult

    # 既存のルート固有tollもまだ生かしておく
    var toll: float = 0.0
    if pay_toll_on_depart:
        toll = float(_route_toll(u, v))

    var total: float = travel + tax + toll

    return {
        "days": days,
        "travel": travel,
        "tax": tax,
        "toll": toll,
        "total": total,
        "rank_mult": rank_mult,
        "tax_mult": tax_mult,
    }


func _edge_cost(u: String, v: String, weight_type: String) -> float:
    var d: int = _route_days(u, v)
    var t: float = _route_toll(u, v)
    var travel: float = travel_cost_per_day * float(d)
    match weight_type:
        "cheapest":
            return travel + (t if pay_toll_on_depart else 0.0)
        "safest":
            var h: float = _route_hazard(u, v)
            var hazard_coef: float = 1.0
            return float(d) * (1.0 + hazard_coef * h)
        _:
            return float(d)

func compute_path(a: String, b: String, weight_type: String = "fastest") -> Dictionary:
    # Dijkstra
    if not path_exists(a, b):
        return {}
    var dist: Dictionary = {}
    var prev: Dictionary = {}
    var unvisited: Array[String] = []
    for k in adj.keys():
        var id := String(k)
        dist[id] = INF
        unvisited.append(id)
    dist[a] = 0.0

    while unvisited.size() > 0:
        # find u with smallest dist
        var best_idx: int = 0
        var best_val: float = 1e30
        for i in range(unvisited.size()):
            var cid := unvisited[i]
            var dv: float = float(dist.get(cid, 1e30))
            if dv < best_val:
                best_val = dv; best_idx = i
        var u: Variant = unvisited.pop_at(best_idx)
        if u == b:
            break
        for v_any in adj.get(u, []):
            var v := String(v_any)
            var alt: float = float(dist.get(u, 1e30)) + _edge_cost(u, v, weight_type)
            if alt < float(dist.get(v, 1e30)):
                dist[v] = alt
                prev[v] = u

    if not prev.has(b) and a != b:
        return {}

    # Build path from a to b
    var path: Array[String] = []
    var cur := b
    path.append(cur)
    while prev.has(cur):
        cur = String(prev[cur])
        path.append(cur)
    path.reverse()

    # Aggregate stats
    var days: int = 0
    var toll: float = 0.0
    var hazard_sum: float = 0.0
    var edges: int = 0
    for i in range(path.size() - 1):
        var u2 := path[i]
        var v2 := path[i + 1]
        days += _route_days(u2, v2)
        toll += _route_toll(u2, v2)
        hazard_sum += _route_hazard(u2, v2)
        edges += 1
    var travel_cost_total: float = travel_cost_per_day * float(days)
    return {
        "path": path,
        "days": days,
        "toll": (toll if pay_toll_on_depart else 0.0),
        "travel_cost": travel_cost_total,
        "hazard": (hazard_sum / float(max(1, edges))),
        "score": float(dist.get(b, float(days)))
    }

func player_move_via(dest: String, path: Array[String]) -> bool:
    if bool(player.get("enroute", false)):
        return false
    if int(player.get("last_arrival_day", -999)) == day:
        return false
    if path.size() < 2:
        return false
    if String(path.front()) != String(player.get("city", "")) or String(path.back()) != dest:
        return false

    # 現在の積載量をもとに、各辺のコストを集計
    var cap_used: int = _cargo_used(player)

    var days_total: int = 0
    var total_cost: float = 0.0
    var per_city_cost: Dictionary = {}  # city_id -> float

    for i in range(path.size() - 1):
        var u := String(path[i])
        var v := String(path[i + 1])

        var edge_cost: Dictionary = _calc_edge_travel_cost(u, v, cap_used)
        var d_edge: int = int(edge_cost.get("days", 0))
        var c_edge: float = float(edge_cost.get("total", 0.0))

        days_total += d_edge
        total_cost += c_edge
        per_city_cost[v] = float(per_city_cost.get(v, 0.0)) + c_edge

    if days_total <= 0:
        return false

    if float(player.get("cash", 0.0)) < total_cost:
        return false

    # 支払い
    player["cash"] = float(player["cash"]) - total_cost

    # 各ステップの「到着側の都市」にコストを反映
    for cid_any in per_city_cost.keys():
        var cid := String(cid_any)
        if not cities.has(cid):
            continue
        cities[cid]["funds"] = float(cities[cid].get("funds", 0.0)) + float(per_city_cost[cid])

    # 出発
    player["dest"] = dest
    player["arrival_day"] = day + days_total
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

    # 1) 売却単価は在庫反映の前に確定（スリッページを過度にしない）
    var unit_price: float = get_bid_price(city, pid)
    var gross: float = float(qty) * unit_price
    var tax: float = gross * get_trade_tax_rate(city)

    # 2) プレイヤーの手持ちから控除（生鮮はロット整合）
    if _is_perishable(pid):
        _lots_take(pid, qty)
        player["cargo"][pid] = int(_lots_total(pid))
    else:
        player["cargo"][pid] = have - qty

    # 3) 市場側は「流入」として処理（不足分は即時消費＝backlog 吸収）
    _ensure_stock_record(city, pid)
    _add_stock_inflow(city, pid, float(qty))

    # 4) 資金/税・価格更新・通知
    player["cash"] = float(player["cash"]) + (gross - tax)
    cities[city]["funds"] = float(cities[city]["funds"]) + tax
    _update_price_for(city, pid)
    world_updated.emit()
    return true


# === Calendar constants ===
@export var DAYS_PER_MONTH: int = 30
@export var MONTHS_PER_YEAR: int = 12
var DAYS_PER_YEAR: int = DAYS_PER_MONTH * MONTHS_PER_YEAR

@export var start_month: int = 5          # 初期開始「月」（1..12）
@export var start_dom:   int = 1          # 初期開始「日」（1..DAYS_PER_MONTH）

func _calc_day_index_for_start(month: int, dom: int) -> int:
    var m : float = clamp(month, 1, MONTHS_PER_YEAR)
    var d : float = clamp(dom,   1, DAYS_PER_MONTH)
    # 年は常に1年目開始想定：Day0＝1/1
    return (m - 1) * DAYS_PER_MONTH + (d - 1)

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

# 品目×月の生産係数（1.0=平常）。月は1..12
func _prod_month_multiplier(pid: String, month: int) -> float:
    var m : float = clamp(month, 1, 12)

    # 例）要件：
    # - 小麦（PR003）：5–9月に生産大（1.8）、それ以外は備蓄程度（0.15）
    # - タラ（PR005）：冬（12–2月）に漁が立つ（1.6）、他は控えめ（0.6）
    var table := {
        "PR003": [0.05, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0, 1.0, 1.0, 0.2, 0.15, 0.1],
        "PR005": [1.0, 1.0, 0.60, 0.60, 0.50, 0.40, 0.50, 0.60, 0.60, 0.60, 0.60, 1.0],
    }

    if table.has(pid):
        var arr: Array = table[pid]
        return float(arr[m - 1])

    # それ以外は平常
    return 1.0


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
            var tax: float = gross * get_trade_tax_rate(city)
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
    var cfg: Dictionary = product_decay_cfg.get(pid, {}) as Dictionary
    var decay_on: bool = float(cfg.get("rate", 0.0)) > 0.0
    return decay_on or (cat in perishable_categories)

func _lots_add(pid: String, qty: int) -> void:
    if qty <= 0: return
    if not _is_perishable(pid): return
    if not cargo_lots.has(pid): cargo_lots[pid] = []
    var arr: Array = cargo_lots[pid] as Array
    arr.append({"qty": int(qty), "age": 0})
    cargo_lots[pid] = arr

func _lots_take(pid: String, qty: int) -> int:
    if qty <= 0: return 0
    if not cargo_lots.has(pid): return 0
    var arr: Array = cargo_lots[pid] as Array
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

# === Route hazard layering (CSV + dynamics) ===
func _route_key_from_route_id(route_id: String) -> String:
    return String(route_id_to_key.get(route_id, ""))

func _combine_hazard_layers(layers: Dictionary) -> float:
    var num: float = 0.0
    var den: float = 0.0
    for k in hazard_layer_weights.keys():
        var w := float(hazard_layer_weights.get(k, 1.0))
        var v: float = clamp(float(layers.get(k, 0.0)), 0.0, 1.0)
        num += v * w
        den += w
    if den <= 0.0:
        return 0.0
    return clamp(num / den, 0.0, 1.0)

func _collect_dyn_layers(key: String) -> Dictionary:
    var out: Dictionary = {}
    if not route_hazard_deltas.has(key):
        return out
    var byk: Dictionary = route_hazard_deltas[key]
    for k in byk.keys():
        var sum := 0.0
        var arr: Array = byk[k]
        var keep: Array = []
        for e in arr:
            var until_day: int = int(e.get("until", 0))
            if until_day > day:
                sum += float(e.get("val", 0.0))
                keep.append(e)
        byk[k] = keep
        out[k] = sum
    route_hazard_deltas[key] = byk
    return out

func _current_hazard_for_key(key: String) -> float:
    var base_layers: Dictionary = route_hazard_layers.get(key, {})
    var dyn_layers: Dictionary = _collect_dyn_layers(key)
    var merged: Dictionary = {}
    for k in hazard_layer_weights.keys():
        merged[k] = clamp(float(base_layers.get(k, 0.0)) + float(dyn_layers.get(k, 0.0)), 0.0, 1.0)
    return _combine_hazard_layers(merged)

func set_route_layer_by_id(route_id: String, kind: String, value: float) -> void:
    var key := _route_key_from_route_id(route_id)
    if key == "":
        return
    var d: Dictionary = route_hazard_layers.get(key, {})
    d[kind] = clamp(float(value), 0.0, 1.0)
    route_hazard_layers[key] = d
    route_hazard_map[key] = _combine_hazard_layers(d)
    world_updated.emit()

func add_route_layer_delta_by_id(route_id: String, kind: String, delta: float, duration_days: int) -> void:
    var key := _route_key_from_route_id(route_id)
    if key == "":
        return
    if not route_hazard_deltas.has(key):
        route_hazard_deltas[key] = {}
    var arr: Array = route_hazard_deltas[key].get(kind, [])
    arr.append({"val": float(delta), "until": day + max(1, int(duration_days))})
    route_hazard_deltas[key][kind] = arr
    world_updated.emit()

func _route_hazard(a: String, b: String) -> float:
    var key := _route_key(a, b)
    if route_hazard_layers.size() > 0 or route_hazard_deltas.size() > 0:
        return _current_hazard_for_key(key)
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


# ==== Save / Load ==========================================================

func _slot_path(slot: int) -> String:
    return "user://saves/slot%02d.json" % slot

func get_slot_summary(slot: int) -> Dictionary:
    var path := _slot_path(slot)
    var da := DirAccess.open("user://")
    if da and not da.dir_exists("user://saves"):
        return {"exists": false}
    if not FileAccess.file_exists(path):
        return {"exists": false}
    var f := FileAccess.open(path, FileAccess.READ)
    if f == null:
        return {"exists": false}
    var data_any: Variant = JSON.parse_string(f.get_as_text())
    if data_any is Dictionary:
        var data_dict: Dictionary = data_any
        var meta: Dictionary = data_dict.get("meta", {}) as Dictionary
        return {
            "exists": true,
            "date": String(meta.get("date", "")),
            "day": int(meta.get("day", 0)),
            "city": String(meta.get("player_city", "")),
            "cash": float(meta.get("player_cash", 0.0)),
        }
    return {"exists": false}

func save_to_slot(slot: int) -> bool:
    var path := _slot_path(slot)
    DirAccess.make_dir_recursive_absolute("user://saves")
    var f := FileAccess.open(path, FileAccess.WRITE)
    if f == null:
        return false
    var payload := _make_save_payload()
    f.store_string(JSON.stringify(payload))
    f.flush()
    return true

func load_from_slot(slot: int) -> bool:
    var path := _slot_path(slot)
    if not FileAccess.file_exists(path):
        return false
    var f := FileAccess.open(path, FileAccess.READ)
    if f == null:
        return false
    var data_any: Variant = JSON.parse_string(f.get_as_text())
    if not (data_any is Dictionary):
        return false
    _apply_save_payload(data_any as Dictionary)
    if has_signal("world_updated"):
        world_updated.emit()
    return true

func _make_save_payload() -> Dictionary:
    var meta: Dictionary = {
        "ver": 1,
        "date": (format_date() if has_method("format_date") else "Day %d" % day),
        "day": day,
        "player_city": String(player.get("city","")),
        "player_cash": float(player.get("cash",0.0)),
        "saved_at": Time.get_datetime_string_from_system(),
    }
    var state: Dictionary = {
        "day": day,
        "player": player,
        "price": price,
        "stock": stock,
        "_shortage_ema": _shortage_ema,
        "_effects_active": _effects_active,
        "supply_count_today": (supply_count_today if "supply_count_today" in self else 0),
        "supply_count_total": (supply_count_total if "supply_count_total" in self else 0),
        "supply_count_by_month": (supply_count_by_month if "supply_count_by_month" in self else {}),
        "supply_count_by_city": (supply_count_by_city if "supply_count_by_city" in self else {}),
        "supply_count_by_pid": (supply_count_by_pid if "supply_count_by_pid" in self else {}),
        "event_log": (event_log if "event_log" in self else []),
        # --- tutorial ---
        "tutorial": {
            "state": tutorial_state,
            "locks": tutorial_locks,
        },

        # --- contracts ---
        "contracts": {
            "offers": _contract_offers,
            "active": _contracts_active,
            "next_id": _contracts_next_id,
            "last_month": _contracts_last_month_key
        },
    }
    return {"meta": meta, "state": state}


func _apply_save_payload(data: Dictionary) -> void:
    var state: Dictionary = (data.get("state", {}) as Dictionary)
    day = int(state.get("day", day))

    if state.has("player"): player = state.get("player") as Dictionary
    if state.has("price"):  price  = state.get("price")  as Dictionary
    if state.has("stock"):  stock  = state.get("stock")  as Dictionary
    if state.has("_shortage_ema"): _shortage_ema = state.get("_shortage_ema") as Dictionary

    # --- tutorial ---
    if state.has("tutorial"):
        var tut: Dictionary = state.get("tutorial") as Dictionary
        var prev_state := tutorial_state
        tutorial_state = String(tut.get("state", tutorial_state))
        tutorial_locks = (tut.get("locks", {}) as Dictionary)
        # ロード直後にUIが追従できるようシグナル発火
        tutorial_state_changed.emit(prev_state, tutorial_state)
        tutorial_locks_changed.emit(get_tutorial_locks())

    # --- contracts ---
    if state.has("contracts"):
        var cst: Dictionary = state.get("contracts") as Dictionary
        _contract_offers = (cst.get("offers", {}) as Dictionary)
        _contracts_active = (cst.get("active", []) as Array)
        _contracts_next_id = int(cst.get("next_id", 1))
        _contracts_last_month_key = String(cst.get("last_month", ""))


func _pick_daily_event_for_tier(tier: String) -> Dictionary:
    var total: float = 0.0
    for r in _events_daily:
        var tr: String = String(r.get("tier", "")).to_lower()
        if tr != tier:
            continue
        total += float(r.get("weight", 0.0))
    if total <= 0.0:
        return {}
    var pick := randf() * total
    var acc := 0.0
    for r2 in _events_daily:
        var tr2: String = String(r2.get("tier", "")).to_lower()
        if tr2 != tier:
            continue
        acc += float(r2.get("weight", 0.0))
        if pick <= acc:
            return r2
    return {}

func _pick_travel_event_for_tier_layers(tier: String, layers: Dictionary) -> Dictionary:
    var cand: Array[Dictionary] = []
    var weights: Array[float] = []
    var total: float = 0.0
    var threshold: float = 0.05
    for r in _events_travel:
        var tr: String = String(r.get("tier", "")).to_lower()
        if tr != tier:
            continue
        var w: float = float(r.get("weight", 0.0))
        if w <= 0.0:
            continue
        var layer: String = String(r.get("layer", "")).to_lower()
        if layer != "":
            var lv: float = float(layers.get(layer, 0.0))
            if lv <= threshold:
                continue
            w *= lv
        cand.append(r)
        weights.append(w)
        total += w
    if total <= 0.0:
        return {}
    var pick := randf() * total
    var acc := 0.0
    for i in range(cand.size()):
        acc += weights[i]
        if pick <= acc:
            return cand[i]
    return {}


# ---- Weekly Report (価格スナップショット) ----
func _get_current_province() -> String:
    var cid: String = String(player.get("city", ""))
    if cid == "":
        return ""
    return String(cities.get(cid, {}).get("province", ""))
func _get_intel_provinces() -> Array[String]:
    var res: Array[String] = []
    if not intel_provinces.is_empty():
        for p_any in intel_provinces:
            var p := String(p_any)
            if p != "" and not res.has(p):
                res.append(p)
    else:
        var cur := _get_current_province()
        if cur != "" and not res.has(cur):
            res.append(cur)
    if weekly_include_world and not res.has("World (ALL)"):
        res.append("World (ALL)")
    return res
func _city_province(cid: String) -> String:
    return String(cities.get(cid, {}).get("province", ""))

# プレイヤーに可視なプロヴィンス
func _provinces_visible_to_player() -> Array[String]:
    var provs: Array[String] = []
    var cur := String(player.get("city", ""))
    if cur != "" and cities.has(cur):
        var pv := _city_province(cur)
        if pv != "":
            provs.append(pv)
    for p_any in intel_provinces:
        var p := String(p_any)
        if p != "" and not provs.has(p):
            provs.append(p)
    return provs

# ルートごとの最良商品
func _best_product_for_route(a: String, b: String) -> Dictionary:
    var best: Dictionary = {}
    var best_gain: float = -1e20
    
    for pid in products.keys():
        if not stock.has(a) or not (stock[a] as Dictionary).has(pid):
            continue
        
        var ask: float = get_ask_price(a, String(pid))
        var bid: float = get_bid_price(b, String(pid))
        
        if ask <= 0.0:
            continue
        
        var gain_abs: float = bid - ask
        var gain_pct: float = gain_abs / ask
        
        if gain_pct > 0.0 and gain_pct > best_gain:
            best_gain = gain_pct
            best = {
                "pid": String(pid),
                "ask": ask,
                "bid": bid,
                "gain_abs": gain_abs,
                "gain_pct": gain_pct
            }
    
    return best

func _top_onehop_arbitrage_in_prov(prov: String, top_n: int = 3) -> Array[Dictionary]:
    var suggestions: Array[Dictionary] = []
    var treat_all := (prov == "World (ALL)" or prov == "*" or prov == "")
    
    for r in routes:
        var a := String(r["from"])
        var b := String(r["to"])
        
        if not treat_all and (_city_province(a) != prov or _city_province(b) != prov):
            continue
        
        var days := int(r.get("days", _route_days(a, b)))
        var toll := float(r.get("toll", _route_toll(a, b)))
        
        # A→B
        var ba := _best_product_for_route(a, b)
        if not ba.is_empty():
            suggestions.append({
                "from": a,
                "to": b,
                "days": days,
                "toll": toll,
                "pid": String(ba.get("pid", "")),
                "gain_pct": float(ba.get("gain_pct", 0.0)),
                "gain_abs": float(ba.get("gain_abs", 0.0))
            })
        
        # B→A
        var bb := _best_product_for_route(b, a)
        if not bb.is_empty():
            suggestions.append({
                "from": b,
                "to": a,
                "days": days,
                "toll": toll,
                "pid": String(bb.get("pid", "")),
                "gain_pct": float(bb.get("gain_pct", 0.0)),
                "gain_abs": float(bb.get("gain_abs", 0.0))
            })
    
    # 利幅%降順ソート
    suggestions.sort_custom(func(a, b): return float(a["gain_pct"]) > float(b["gain_pct"]))
    
    # TOP-Nのみ返却
    var out: Array[Dictionary] = []
    for i in range(min(top_n, suggestions.size())):
        out.append(suggestions[i])
    
    return out

# --- Weekly report helpers (MVP++) ---
# プロヴィンス内の都市リスト
func _cities_in_province(prov: String) -> Array[String]:
    if prov == "World (ALL)":
        var all: Array[String] = []
        for k in cities.keys():
            all.append(String(k))
        return all
    
    var result: Array[String] = []
    for k in cities.keys():
        var cid := String(k)
        if String(cities.get(cid, {}).get("province", "")) == prov:
            result.append(cid)
    return result

# 価格スナップショット取得
func _snapshot_prices_for(prov: String) -> Dictionary:
    # key="cid:pid" -> {mid, cid, pid}
    var rows: Dictionary = {}
    var cids := _cities_in_province(prov)
    
    for cid in cids:
        if not price.has(cid):
            continue
        
        var pm: Dictionary = price[cid]
        for pid in pm.keys():
            var mid := float(pm[pid])
            var key := "%s:%s" % [cid, String(pid)]
            rows[key] = {
                "mid": mid,
                "cid": cid,
                "pid": String(pid)
            }
    
    return {"day": day, "rows": rows}

func _generate_weekly_reports() -> void:
    var provs := _get_intel_provinces()
    for p in provs:
        var prov := String(p)

        var cur := _make_price_snapshot_for_province(prov)
        var prev: Dictionary = _last_snapshot_by_prov.get(prov, {})
        var payload: Dictionary = {"day": day, "province": prov, "top_n": weekly_report_top_n}

        # ---- 遅延週報（ライブデータは使わない） ----
        if weekly_report_delayed_mode:
            if prev.is_empty():
                var text := "[週報（遅延）] %s （Day %d）
初回スナップショットを記録しました。来週から観測データが届きます。" % [prov, day]
                payload["text"] = text
                payload["delayed"] = true
                payload["basis_allowed"] = false
                weekly_report.emit(prov, payload)
            else:
                payload["delayed"] = true
                payload["basis_allowed"] = true
                payload["obs_day"] = int(prev.get("day", day - 7))
                # basis用データは観測週のスナップショット（先週）
                var __rows_prev__: Array = prev.get("rows", [])
                var __rows_obs__: Array = []
                for __r_any__ in __rows_prev__:
                    var __r__: Dictionary = __r_any__
                    var __copy__ := __r__.duplicate(true)
                    __copy__["mid_obs"] = float(__r__.get("mid", 0.0))
                    __copy__["qty_obs"] = float(__r__.get("qty", 0.0))
                    __copy__["target_obs"] = float(__r__.get("target", 1.0))
                    __rows_obs__.append(__copy__)
                payload["rows_delayed"] = __rows_obs__
                var __watch_obs__ := _compute_watchlist_from_rows(prev.get("rows", []), weekly_report_top_n)
                payload["watch_scarcity"] = __watch_obs__.get("scarcity", [])
                payload["watch_surplus"]  = __watch_obs__.get("surplus", [])
                # 値上がり/値下がりは観測週の差分 prev2 -> prev で作る
                var prev2: Dictionary = _prev_snapshot_by_prov.get(prov, {})
                if not prev2.is_empty():
                    var diffs_obs: Array[Dictionary] = _compute_weekly_changes(prev2, prev)
                    var ups := diffs_obs.duplicate()
                    ups.sort_custom(func(a, b): return float(a["pct"]) > float(b["pct"]))
                    var dns := diffs_obs.duplicate()
                    dns.sort_custom(func(a, b): return float(a["pct"]) < float(b["pct"]))
                    var n2: int = min(weekly_report_top_n, diffs_obs.size())

                    var rise_arr: Array[Dictionary] = []
                    var fall_arr: Array[Dictionary] = []

                    for i in range(min(n2, ups.size())):
                        var e: Dictionary = ups[i]
                        var cid := String(e.get("city",""))
                        var pid := String(e.get("pid",""))
                        rise_arr.append({
                            "city": cid,
                            "city_name": String(cities.get(cid, {}).get("name", cid)),
                            "pid": pid,
                            "product_name": get_product_name(pid),
                            "pct": float(e.get("pct", 0.0)),
                            "mid": float(e.get("mid", 0.0))
                        })
                    for j in range(min(n2, dns.size())):
                        var e2: Dictionary = dns[j]
                        var cid2 := String(e2.get("city",""))
                        var pid2 := String(e2.get("pid",""))
                        fall_arr.append({
                            "city": cid2,
                            "city_name": String(cities.get(cid2, {}).get("name", cid2)),
                            "pid": pid2,
                            "product_name": get_product_name(pid2),
                            "pct": float(e2.get("pct", 0.0)),
                            "mid": float(e2.get("mid", 0.0))
                        })
                    payload["rise"] = rise_arr
                    payload["fall"] = fall_arr

                # 見出しはHUD側で生成するため簡易文言のみ
                payload["text"] = "[週報（遅延）] %s  観測Day %d / 受信Day %d" % [prov, int(payload["obs_day"]), day]
                weekly_report.emit(prov, payload)
        else:
            # ---- 非遅延（通常）週報 ----
            if prev.is_empty():
                var text2 := "[週報] %s （Day %d）
初回スナップショットを記録しました。来週から増減が表示されます。" % [prov, day]
                payload["text"] = text2
                payload["basis_allowed"] = true  # ← 初週でも Basis は閲覧可に統一
                if cur.has("rows"):
                    payload["rows"] = cur["rows"]
                    var __watch_first__ := _compute_watchlist_from_rows(cur.get("rows", []), weekly_report_top_n)
                    payload["watch_scarcity"] = __watch_first__.get("scarcity", [])
                    payload["watch_surplus"]  = __watch_first__.get("surplus", [])
                weekly_report.emit(prov, payload)
            else:
                # 上下トップ（prev→cur の率変化）
                var diffs: Array[Dictionary] = _compute_weekly_changes(prev, cur)
                var ups := diffs.duplicate()
                ups.sort_custom(func(a, b): return float(a["pct"]) > float(b["pct"]))
                var dns := diffs.duplicate()
                dns.sort_custom(func(a, b): return float(a["pct"]) < float(b["pct"]))
                var n2: int = min(weekly_report_top_n, diffs.size())

                var rise_arr: Array[Dictionary] = []
                var fall_arr: Array[Dictionary] = []
                for i in range(min(n2, ups.size())):
                    var e: Dictionary = ups[i]
                    var cid := String(e.get("city",""))
                    var pid := String(e.get("pid",""))
                    rise_arr.append({
                        "city": cid,
                        "city_name": String(cities.get(cid, {}).get("name", cid)),
                        "pid": pid,
                        "product_name": get_product_name(pid),
                        "pct": float(e.get("pct", 0.0)),
                        "mid": float(e.get("mid", 0.0))
                    })
                for j in range(min(n2, dns.size())):
                    var e2: Dictionary = dns[j]
                    var cid2 := String(e2.get("city",""))
                    var pid2 := String(e2.get("pid",""))
                    fall_arr.append({
                        "city": cid2,
                        "city_name": String(cities.get(cid2, {}).get("name", cid2)),
                        "pid": pid2,
                        "product_name": get_product_name(pid2),
                        "pct": float(e2.get("pct", 0.0)),
                        "mid": float(e2.get("mid", 0.0))
                    })

                var text3 := _make_weekly_summary_text(prov, prev, cur)
                payload["text"] = text3
                payload["basis_allowed"] = true
                if cur.has("rows"):
                    payload["rows"] = cur["rows"]
                payload["rise"] = rise_arr
                payload["fall"] = fall_arr
                # 追加:
                var __watch_now__ := _compute_watchlist_from_rows(cur.get("rows", []), weekly_report_top_n)
                payload["watch_scarcity"] = __watch_now__.get("scarcity", [])
                payload["watch_surplus"]  = __watch_now__.get("surplus", [])

                weekly_report.emit(prov, payload)

        # スナップショット更新
        if not prev.is_empty():
            _prev_snapshot_by_prov[prov] = prev
        _last_snapshot_by_prov[prov] = cur

func _make_weekly_summary_text(title: String, prev: Dictionary, cur: Dictionary) -> String:
    # prev / cur は _make_price_snapshot_for_province() の戻り値
    # 既存UIの体裁に揃える：
    #  - 見出し
    #  - 値上がりTOP
    #  - 値下がりTOP
    #  - 逼迫ウォッチTOP（在庫率・EMA・スプレッドを表示）
    var top_n: int = int(weekly_report_top_n)

    # 価格増減（先週→今週）
    var diffs: Array[Dictionary] = _compute_weekly_changes(prev, cur) # pct降順
    var rise_n: float = min(top_n, diffs.size())

    # ヘッダ
    var sb := PackedStringArray()
    sb.append("[週報] %s  (Day %d)" % [title, int(cur.get("day", day))])

    # 値上がりTOP
    sb.append("")
    sb.append("値上がりTOP:")
    for i in range(rise_n):
        var e: Dictionary = diffs[i]
        var cid := String(e.get("city", ""))
        var pid := String(e.get("pid", ""))
        var cname := String(cities.get(cid, {}).get("name", cid))
        var pname := get_product_name(pid)
        var pct := float(e.get("pct", 0.0)) * 100.0
        var mid_now := float(e.get("mid", 0.0))
        sb.append("%s / %s： %+0.1f%%  (mid=%0.1f)" % [cname, pname, pct, mid_now])

    # 値下がりTOP
    sb.append("")
    sb.append("値下がりTOP:")
    var fall_n: float = min(top_n, diffs.size())
    for i in range(fall_n):
        var e2: Dictionary = diffs[diffs.size() - 1 - i]
        var cid2 := String(e2.get("city", ""))
        var pid2 := String(e2.get("pid", ""))
        var cname2 := String(cities.get(cid2, {}).get("name", cid2))
        var pname2 := get_product_name(pid2)
        var pct2 := float(e2.get("pct", 0.0)) * 100.0
        var mid_now2 := float(e2.get("mid", 0.0))
        sb.append("%s / %s： %+0.1f%%  (mid=%0.1f)" % [cname2, pname2, pct2, mid_now2])

    # 逼迫ウォッチTOP（在庫率・ShortageEMA・Spread）
    sb.append("")
    sb.append("逼迫ウォッチTOP:")
    var watch: Dictionary = _compute_watchlist(title, top_n)
    var scarce: Array[Dictionary] = watch.get("scarcity", []) as Array[Dictionary]
    for z in scarce:
        var z_c := String(z.get("city_name", z.get("city", "")))
        var z_p := String(z.get("product_name", z.get("pid", "")))
        var ratio_pct : float = clamp(float(z.get("ratio", 0.0)) * 100.0, 0.0, 999.0)
        var ema := float(z.get("shortage", 0.0))
        var sp : float = clamp(float(z.get("spread", 0.0)) * 100.0, 0.0, 999.0)
        sb.append("%s / %s： 在庫率 %0.0f%%, ShortageEMA %0.2f, Spread ±%0.0f%%" % [z_c, z_p, ratio_pct, ema, sp])

    return "\n".join(sb)


func _compute_watchlist(prov: String, top_n: int = 3) -> Dictionary:
    var scarcity: Array[Dictionary] = []
    var surplus: Array[Dictionary] = []
    var treat_all: bool = (prov == "World (ALL)")
    for c_id in cities.keys():
        var city: Dictionary = cities[c_id] as Dictionary
        if not treat_all and String(city.get("province","")) != prov:
            continue
        if not stock.has(c_id):
            continue
        var sdict: Dictionary = stock[c_id] as Dictionary
        for pid_any in sdict.keys():
            var pid: String = String(pid_any)
            var rec: Dictionary = sdict[pid] as Dictionary
            var target: float = max(1.0, float(rec.get("target", 1.0)))
            var qty: float = max(0.0, float(rec.get("qty", 0.0)))
            var ratio: float = 0.0
            if target > 0.0:
                ratio = qty / target
            var sp: float = _spread_for(c_id, pid)
            var s_lvl: float = max(0.0, 1.0 - ratio)
            if _shortage_ema.has(c_id) and (_shortage_ema[c_id] as Dictionary).has(pid):
                s_lvl = float((_shortage_ema[c_id] as Dictionary)[pid])
            var scarcity_score: float = (1.0 - min(1.0, ratio)) * s_lvl * sp
            var over: float = max(0.0, ratio - 1.0)
            var surplus_score: float = over * max(0.0, (max_spread - sp))
            if scarcity_score > 0.0:
                scarcity.append({
                    "city": c_id,
                    "city_name": String(city.get("name", c_id)),
                    "pid": pid,
                    "product_name": get_product_name(pid),
                    "score": scarcity_score,
                    "ratio": ratio,
                    "shortage": s_lvl,
                    "spread": sp
                })
            if surplus_score > 0.0:
                surplus.append({
                    "city": c_id,
                    "city_name": String(city.get("name", c_id)),
                    "pid": pid,
                    "product_name": get_product_name(pid),
                    "score": surplus_score,
                    "ratio": ratio,
                    "shortage": s_lvl,
                    "spread": sp
                })
    scarcity.sort_custom(func(a,b): return float(a.get("score",0.0)) > float(b.get("score",0.0)))
    surplus.sort_custom(func(a,b): return float(a.get("score",0.0)) > float(b.get("score",0.0)))
    if scarcity.size() > top_n: scarcity.resize(top_n)
    if surplus.size() > top_n: surplus.resize(top_n)
    return {"scarcity": scarcity, "surplus": surplus}

# 関数置換: _make_price_snapshot_for_province(prov: String) -> Dictionary
# 変更点: has_stock を付ける
func _make_price_snapshot_for_province(prov: String) -> Dictionary:
    var rows: Array[Dictionary] = []
    var cids := _cities_in_province(prov)
    for c_any in cids:
        var c_id := String(c_any)
        if not price.has(c_id):
            continue
        var pm: Dictionary = price[c_id]
        for p_any in pm.keys():
            var pid := String(p_any)
            var m: float = float(pm[pid])
            var b: float = get_bid_price(c_id, pid)
            var a: float = get_ask_price(c_id, pid)

            var q: float = 0.0
            var t: float = 1.0
            var se: float = 0.0
            var has_rec: bool = false
            if stock.has(c_id) and (stock[c_id] as Dictionary).has(pid):
                has_rec = true
                var rec: Dictionary = stock[c_id][pid]
                q = float(rec.get("qty", 0.0))
                t = float(rec.get("target", 1.0))
            if _shortage_ema.has(c_id) and (_shortage_ema[c_id] as Dictionary).has(pid):
                se = float((_shortage_ema[c_id] as Dictionary).get(pid, 0.0))
            var sp: float = _spread_for(c_id, pid)

            rows.append({
                "city": c_id,
                "city_name": String(cities.get(c_id, {}).get("name", c_id)),
                "pid": pid,
                "product_name": get_product_name(pid),
                "mid": m, "bid": b, "ask": a,
                "qty": q, "target": t,
                "shortage_ema": se, "spread": sp,
                "has_stock": has_rec   # ← 追加
            })
    return {"day": day, "province": prov, "rows": rows}


func _compute_weekly_changes(prev: Dictionary, cur: Dictionary) -> Array[Dictionary]:
    var diffs: Array[Dictionary] = []
    var cur_map := {}
    for r in cur.get("rows", []):
        cur_map["%s|%s" % [r["city"], r["pid"]]] = r
    for r0 in prev.get("rows", []):
        var key := "%s|%s" % [r0["city"], r0["pid"]]
        if cur_map.has(key):
            var r1: Dictionary = cur_map[key] as Dictionary
            var m0 := float(r0.get("mid", 0.0))
            var m1 := float(r1.get("mid", 0.0))
            if m0 <= 0.0:
                continue
            var pct := (m1 - m0) / m0
            diffs.append({"city": String(r1["city"]), "pid": String(r1["pid"]), "pct": pct, "mid": m1})
    diffs.sort_custom(func(a,b): return float(a["pct"]) > float(b["pct"]))
    return diffs

# ---- Weekly Report (Delayed Mode) ----
# 観測（先週のスナップショット）を今週配信するテキストを生成。
# 併せて“現在値プレビュー”も付与（開発・検証用）
# 観測(prev)を今週配信。上昇/下落は prev2→prev の差分。
# 戻り値: {"text": String, "rows_delayed": Array, "routes": Array}
func _build_weekly_report_text_delayed(prov: String, prev: Dictionary, cur: Dictionary, top_n: int) -> Dictionary:
    # prev: 観測週（1週前）のスナップショット
    # cur : 現在週（受信側）のスナップショット
    # 返り値は HUD 側が新形式として直接描画できるよう rise/fall/rows_delayed 等を含める
    var prev2: Dictionary = _prev_snapshot_by_prov.get(prov, {})
    var basis_allowed: bool = (not prev2.is_empty())
    var sb := PackedStringArray()

    var day_obs: int = int(prev.get("day", 0))
    var day_recv: int = day
    sb.append("[週報（遅延）] %s  観測: Day %d / 受信: Day %d" % [prov, day_obs, day_recv])
    if weekly_report_delayed_include_live:
        sb.append("（注）観測時点の在庫・価格。括弧内は現在値プレビュー）")
    sb.append("")

    # ========== 値上がり/値下がり（観測週の差分：prev2 -> prev） ==========
    var rise: Array[Dictionary] = []
    var fall: Array[Dictionary] = []
    if not prev2.is_empty():
        var diffs_obs: Array[Dictionary] = _compute_weekly_changes(prev2, prev) # pct 降順
        var n: float = min(top_n, diffs_obs.size())

        # 値上がりTOP
        sb.append("値上がりTOP:")
        for i in range(n):
            var e: Dictionary = diffs_obs[i]
            var cid: String = String(e.get("city",""))
            var pid: String = String(e.get("pid",""))
            var cname: String = String(cities.get(cid, {}).get("name", cid))
            var pname: String = get_product_name(pid)
            var pct: float = float(e.get("pct", 0.0)) * 100.0
            var mid_obs: float = float(e.get("mid", 0.0))
            var line: String = "%s / %s： %+0.1f%%  (mid=%.1f)" % [cname, pname, pct, mid_obs]
            if weekly_report_delayed_include_live and price.has(cid) and (price[cid] as Dictionary).has(pid):
                var live_mid: float = float(price[cid][pid])
                line += "  [live:%.1f]" % live_mid
            sb.append(line)
            rise.append({
                "city": cid, "city_name": cname,
                "pid": pid, "product_name": pname,
                "pct": float(e.get("pct", 0.0)),
                "mid": mid_obs
            })

        # 値下がりTOP
        sb.append("")
        sb.append("値下がりTOP:")
        for i in range(n):
            var e2: Dictionary = diffs_obs[diffs_obs.size() - 1 - i]
            var cid2: String = String(e2.get("city",""))
            var pid2: String = String(e2.get("pid",""))
            var cname2: String = String(cities.get(cid2, {}).get("name", cid2))
            var pname2: String = get_product_name(pid2)
            var pct2: float = float(e2.get("pct", 0.0)) * 100.0
            var mid_obs2: float = float(e2.get("mid", 0.0))
            var line2: String = "%s / %s： %+0.1f%%  (mid=%.1f)" % [cname2, pname2, pct2, mid_obs2]
            if weekly_report_delayed_include_live and price.has(cid2) and (price[cid2] as Dictionary).has(pid2):
                var live_mid2: float = float(price[cid2][pid2])
                line2 += "  [live:%.1f]" % live_mid2
            sb.append(line2)
            fall.append({
                "city": cid2, "city_name": cname2,
                "pid": pid2, "product_name": pname2,
                "pct": float(e2.get("pct", 0.0)),
                "mid": mid_obs2
            })

    # ========== 返却（HUDの新形式に対応） ==========
    var out: Dictionary = {}
    out["text"] = "\n".join(sb)
    out["obs_day"] = day_obs
    out["rise"] = rise
    out["fall"] = fall
    out["top_n"] = max(1, int(top_n))
    
    # enrich rows with names for HUD fallback rendering
    var __rows_delayed_src: Array[Dictionary] = (prev.get("rows", []) as Array)
    var __rows_delayed_src_enriched: Array[Dictionary] = []
    for __r_any in __rows_delayed_src:
        var __r: Dictionary = __r_any
        var __cid := String(__r.get("city",""))
        var __pid := String(__r.get("pid",""))
        var __row_copy := __r.duplicate(true)
        __row_copy["city_name"] = String(cities.get(__cid, {}).get("name", __cid))
        __row_copy["product_name"] = get_product_name(__pid)
        __rows_delayed_src_enriched.append(__row_copy)
    out["rows_delayed"] = __rows_delayed_src_enriched
    if weekly_report_delayed_include_live:
        var __rows_live_src: Array[Dictionary] = (cur.get("rows", []) as Array)
        var __rows_live_src_enriched: Array[Dictionary] = []
        for __r_any2 in __rows_live_src:
            var __r2: Dictionary = __r_any2
            var __cid2 := String(__r2.get("city",""))
            var __pid2 := String(__r2.get("pid",""))
            var __row_copy2 := __r2.duplicate(true)
            __row_copy2["city_name"] = String(cities.get(__cid2, {}).get("name", __cid2))
            __row_copy2["product_name"] = get_product_name(__pid2)
            __rows_live_src_enriched.append(__row_copy2)
        out["rows_live"] = __rows_live_src_enriched
    out["basis_allowed"] = basis_allowed
    return out

# === Watchlist computation from rows (shared by delayed/normal weekly) ===
func _compute_watchlist_from_rows(rows: Array, top_n: int=3) -> Dictionary:
    var scarcity: Array[Dictionary] = []
    var surplus: Array[Dictionary] = []

    for any_r in rows:
        var r: Dictionary = any_r
        var cid := String(r.get("city",""))
        var pid := String(r.get("pid",""))

        var q: float = 0.0
        if r.has("qty"):
            q = float(r.get("qty", 0.0))
        else:
            q = float(r.get("qty_obs", 0.0))

        var t: float = 1.0
        if r.has("target"):
            t = float(r.get("target", 1.0))
        else:
            t = float(r.get("target_obs", 1.0))

        var ratio : float = q / max(1.0, t)
        var sp := float(r.get("spread", 0.0))
        var ema := float(r.get("shortage_ema", -1.0))

        var base := {
            "city": cid,
            "city_name": String(cities.get(cid, {}).get("name", cid)),
            "pid": pid,
            "product_name": get_product_name(pid),
            "ratio": ratio,
            "spread": sp,
            "shortage": ema
        }

        var shortage_score : float = max(0.0, 1.0 - ratio) * max(0.0, sp)
        var surplus_score : float = max(0.0, ratio - 1.0) * max(0.0, 1.0 - sp)

        if shortage_score > 0.0:
            var a := base.duplicate()
            a["score"] = shortage_score
            scarcity.append(a)

        if surplus_score > 0.0:
            var b := base.duplicate()
            b["score"] = surplus_score
            surplus.append(b)

    scarcity.sort_custom(func(a, b): return float(a["score"]) > float(b["score"]))
    surplus.sort_custom(func(a, b): return float(a["score"]) > float(b["score"]))

    var nscar: float = min(int(top_n), scarcity.size())
    var nsurp: float = min(int(top_n), surplus.size())
    return {"scarcity": scarcity.slice(0, nscar), "surplus": surplus.slice(0, nsurp)}


func _load_rank_ratio() -> void:
    var rr_path: String = data_dir + rank_ratio_file
    if FileAccess.file_exists(rr_path):
        var rr_rows: Array[Dictionary] = _loader.load_csv_dicts(rr_path)
        rank_table.from_rows(rr_rows)


# === Debug helpers for Watchlist ===

# 1) UI描画だけを確認（世界状態は変更しない）
func debug_emit_watch_test(prov: String = "", delayed: bool=false) -> void:
    var prov_id := prov
    if prov_id == "":
        # 何も指定が無ければ最初の都市の属する地方を使う
        for k in cities.keys():
            var cid := String(k)
            prov_id = String(cities.get(cid, {}).get("province", ""))
            if prov_id != "":
                break

    var cids: Array = []
    for k2 in cities.keys():
        cids.append(String(k2))
        if cids.size() >= 3:
            break

    var pids: Array = []
    for k3 in products.keys():
        pids.append(String(k3))
        if pids.size() >= 3:
            break

    if cids.size() == 0 or pids.size() == 0:
        return

    var payload: Dictionary = {
        "day": day,
        "province": prov_id,
        "delayed": delayed,
        "basis_allowed": false
    }
    if delayed:
        payload["obs_day"] = max(0, day - 1)

    payload["watch_scarcity"] = [
        {
            "city": cids[0],
            "city_name": String(cities.get(cids[0], {}).get("name", cids[0])),
            "pid": pids[0],
            "product_name": get_product_name(pids[0]),
            "score": 0.50,
            "ratio": 0.20
        }
    ]

    payload["watch_surplus"] = [
        {
            "city": cids[min(1, cids.size()-1)],
            "city_name": String(cities.get(cids[min(1, cids.size()-1)], {}).get("name", cids[min(1, cids.size()-1)])),
            "pid": pids[min(1, pids.size()-1)],
            "product_name": get_product_name(pids[min(1, pids.size()-1)]),
            "score": 0.65,
            "ratio": 1.60
        },
        {
            "city": cids[min(2, cids.size()-1)],
            "city_name": String(cities.get(cids[min(2, cids.size()-1)], {}).get("name", cids[min(2, cids.size()-1)])),
            "pid": pids[min(2, pids.size()-1)],
            "product_name": get_product_name(pids[min(2, pids.size()-1)]),
            "score": 0.30,
            "ratio": 1.20
        }
    ]

    weekly_report.emit(prov_id, payload)


# 2) 現在のスナップショットを元に watch_* を計算して発火（副作用なし）
#    kind: "surplus" | "scarcity"
func debug_watch_from_current(prov: String = "", kind: String = "surplus", delayed: bool=false) -> void:
    var prov_id := prov
    if prov_id == "":
        for k in cities.keys():
            var cid := String(k)
            prov_id = String(cities.get(cid, {}).get("province", ""))
            if prov_id != "":
                break

    var cur := _make_price_snapshot_for_province(prov_id)
    var rows := (cur.get("rows", []) as Array).duplicate(true)
    if rows.size() == 0:
        return

    # 1件だけ意図的に在庫率を上下させる（世界状態は変えない）
    var r0: Dictionary = rows[0]
    var tgt := float(r0.get("target", 1.0))
    if tgt <= 0.0:
        tgt = 1.0
    if kind == "surplus":
        r0["qty"] = tgt * 1.60
    else:
        r0["qty"] = tgt * 0.20
    rows[0] = r0

    var w := _compute_watchlist_from_rows(rows, weekly_report_top_n)
    var payload: Dictionary = {
        "day": day,
        "province": prov_id,
        "delayed": delayed,
        "basis_allowed": true,
        "watch_scarcity": w.get("scarcity", []),
        "watch_surplus": w.get("surplus", [])
    }
    if delayed:
        payload["obs_day"] = max(0, day - 1)

    weekly_report.emit(prov_id, payload)

# --- 追加: ヘルパ関数（ファイル末尾などに追加してください） ---

func _ensure_backlog_record(cid: String, pid: String) -> void:
    if not backlog.has(cid):
        backlog[cid] = {}
    var d: Dictionary = backlog[cid]
    if not d.has(pid):
        d[pid] = 0.0
    backlog[cid] = d

func _backlog_absorb_on_inflow(cid: String, pid: String, added: float) -> float:
    # 入荷(added)のうち、未充足需要(backlog)に即時に飲まれる分を返す（部分吸収＋上限）
    if not use_backlog_absorption:
        return 0.0

    _ensure_backlog_record(cid, pid)
    var need: float = float(backlog[cid][pid])
    if need <= 0.0 or added <= 0.0:
        return 0.0

    var rate: float = clamp(backlog_absorb_rate, 0.0, 1.0)
    var allow: float = added * rate

    var cap: float = max(0.0, backlog_absorb_daily_cap)
    if cap > 0.0:
        allow = min(allow, cap)

    var used: float = min(allow, need)
    backlog[cid][pid] = max(0.0, need - used)
    return used


func _add_stock_inflow(cid: String, pid: String, added: float) -> void:
    # 市場に「在庫として」乗る前に backlog を吸収し、残りだけを qty へ加算
    _ensure_stock_record(cid, pid)
    var used_immediate: float = _backlog_absorb_on_inflow(cid, pid, added)
    var remain: float = max(0.0, added - used_immediate)
    stock[cid][pid]["qty"] = float(stock[cid][pid]["qty"]) + remain

func _normalize_targets_after_load() -> void:
    # CSV の target_stock が 1 以下なら、自動で補う（ランク別 safety_days × 平常消費）
    if not auto_target_fill_enable:
        return
    for cid in stock.keys():
        var rk: int = int(cities.get(cid, {}).get("rank", 5))
        var days: float = _rank_safety_days(rk)
        for pid in stock[cid].keys():
            var t0: float = float(stock[cid][pid].get("target", 0.0))
            if t0 <= 1.0:
                var base: float = _consume_base_for(pid)
                var per_day: float = base * _rank_consume_mult(rk)
                stock[cid][pid]["target"] = max(1.0, per_day * days)

func _contracts_month_key() -> String:
    var c := get_calendar()
    return "%04d-%02d" % [int(c.get("year",1)), int(c.get("month",1))]

func _contracts_rng(seed_key: String) -> RandomNumberGenerator:
    var rng := RandomNumberGenerator.new()
    rng.seed = int(abs(hash(seed_key)))
    return rng

func _contracts_city_rank(cid: String) -> int:
    var rk := 1
    if cities.has(cid):
        var v: Variant = (cities[cid] as Dictionary).get("CityRANK", (cities[cid] as Dictionary).get("rank", 1))
        rk = int(_num(v))
    if rk < 1: rk = 1
    return rk

func _contracts_offers_count(cid: String) -> int:
    var rk := _contracts_city_rank(cid)
    var base := 2 + int(floor(float(rk) / 3.0))
    if base < contracts_offer_min: base = contracts_offer_min
    if base > contracts_offer_max: base = contracts_offer_max
    return base

func _contracts_pick_rarity(rng: RandomNumberGenerator) -> String:
    var keys := _contracts_rarity_weights.keys()
    var total := 0.0
    for k in keys: total += float(_contracts_rarity_weights[k])
    var pick := rng.randf() * total
    var acc := 0.0
    for k in keys:
        acc += float(_contracts_rarity_weights[k])
        if pick <= acc:
            return String(k)
    return "common"

func _contracts_make_offer_for_city(cid: String, rng: RandomNumberGenerator) -> Dictionary:
    # 目的地は自都市以外からランダム（v1は単純化）
    var cids := cities.keys()
    if cids.size() <= 1:
        return {}
    var dst := cid
    var guard := 0
    while dst == cid and guard < 16:
        dst = String(cids[rng.randi() % cids.size()])
        guard += 1

    # 需要が高い商品（shortage_emaが大きい）を優先して選ぶ
    var best_pid := ""
    var best_score := -1.0
    for pid_any in products.keys():
        var pid := String(pid_any)
        var s: float = 0.0
        if _shortage_ema.has(dst) and (_shortage_ema[dst] as Dictionary).has(pid):
            s = float((_shortage_ema[dst] as Dictionary).get(pid, 0.0))
        else:
            # 在庫/目標からの不足比（簡易）
            if stock.has(dst) and (stock[dst] as Dictionary).has(pid):
                var rec: Dictionary = stock[dst][pid]
                var target : float = max(1.0, float(rec.get("target", 1.0)))
                var qty : float = max(0.0, float(rec.get("qty", 0.0)))
                s = max(0.0, 1.0 - (qty / target))
        if s > best_score:
            best_score = s
            best_pid = pid
    if best_pid == "":
        best_pid = String(products.keys()[rng.randi() % products.size()])

    # 量・期限・報酬（レア度でスケール）
    var rarity := _contracts_pick_rarity(rng)
    var size_u := int(products[best_pid].get("size", 1))
    var base_qty := 4 + rng.randi_range(0, 6)         # 4〜10
    var qty : float = base_qty * max(1, size_u)               # 担ぎ単位に寄せる簡易策
    if rarity == "uncommon": qty = int(round(float(qty) * 1.25))
    elif rarity == "rare":   qty = int(round(float(qty) * 1.6))
    elif rarity == "epic":   qty = int(round(float(qty) * 2.2))

    var deadline := day + rng.randi_range(contracts_deadline_min, contracts_deadline_max)

    # 市場買い取り価格をベースに報酬を算出（目的地の不足を反映）
    var unit_bid := get_bid_price(dst, best_pid)
    var reward := float(qty) * unit_bid * contracts_reward_k
    if rarity == "uncommon": reward *= 1.2
    elif rarity == "rare":   reward *= 1.5
    elif rarity == "epic":   reward *= 2.0

    var offer_id := _contracts_next_id
    _contracts_next_id += 1
    return {
        "id": offer_id,
        "kind": "deliver",
        "from": cid,
        "to": dst,
        "pid": best_pid,
        "qty": qty,
        "deadline": deadline,
        "rarity": rarity,
        "reward": reward
    }

func _contracts_generate_monthly_offers() -> void:
    if not contracts_enabled:
        return
    var mkey := _contracts_month_key()
    if _contracts_last_month_key == mkey:
        return
    _contract_offers = {}
    # 都市ごとに生成
    for cid_any in cities.keys():
        var cid := String(cid_any)
        var arr: Array[Dictionary] = []
        var rng := _contracts_rng("%s|%s" % [mkey, cid])
        var n := _contracts_offers_count(cid)
        for i in range(n):
            var offer := _contracts_make_offer_for_city(cid, rng)
            if offer.size() > 0:
                arr.append(offer)
        _contract_offers[cid] = arr
    _contracts_last_month_key = mkey

# 受注済み契約を返す（履歴含めたい場合は引数で制御）
func contracts_get_active(include_history: bool = false) -> Array:
    if _contracts_active == null:
        return []
    # 期限切れ→failed への更新を反映
    if has_method("_contracts_sweep_expired"):
        _contracts_sweep_expired()
    var out: Array = []
    for any in _contracts_active:
        var c: Dictionary = any
        if include_history:
            out.append(c)
        else:
            if String(c.get("state", "accepted")) == "accepted":
                out.append(c)
    return out


func contracts_can_accept() -> bool:
    return _contracts_active.size() < contracts_active_limit

func contracts_try_auto_deliver_at(city_id: String) -> void:
    if _contracts_active.is_empty():
        return
    var cargo: Dictionary = player.get("cargo", {}) as Dictionary
    var changed := false
    var done: Array[int] = []

    for i in range(_contracts_active.size()):
        var ct: Dictionary = _contracts_active[i]

        # 互換: "active" / "accepted" のどちらでも稼働中として扱う
        var st := String(ct.get("state",""))
        var is_active := (st == "active") or (st == "accepted")
        if not is_active:
            continue

        # Deliver型のみ（将来の型追加を見越して厳格に）
        if String(ct.get("kind","")) != "deliver":
            continue
        if String(ct.get("to","")) != city_id:
            continue

        var pid := String(ct.get("pid",""))
        var need := int(ct.get("qty",0))

        # 互換: deadline_day / deadline どちらでも
        var deadline_i := int(ct.get("deadline", day))
        if ct.has("deadline_day"):
            deadline_i = int(ct.get("deadline_day"))
        if day > deadline_i:
            continue

        # 在庫チェック：既存仕様（生鮮→lots、非生鮮→cargo）
        var have := int(cargo.get(pid, 0))
        var ok := false
        if _is_perishable(pid):
            ok = (_lots_total(pid) >= need)
        else:
            ok = (have >= need)
        if not ok:
            continue

        # 引き渡し
        # 互換: reward_cash があれば優先。無ければ reward。
        var reward := float(ct.get("reward", 0.0))
        if ct.has("reward_cash"):
            reward = float(ct.get("reward_cash"))

        if _is_perishable(pid):
            _lots_take(pid, need)
            cargo[pid] = int(_lots_total(pid))
        else:
            cargo[pid] = have - need

        player["cash"] = float(player.get("cash",0.0)) + reward
        ct["state"] = "done"
        ct["done_day"] = day
        _contracts_active[i] = ct
        changed = true
        done.append(i)

        _world_message("契約達成: %s を %s に %d 個 納品。報酬 %.0f" % [
            get_product_name(pid), get_city_name(city_id), need, reward
        ])

    # 履歴保持（削除せず state のみ変更）
    for j in range(done.size()-1, -1, -1):
        var idx := int(done[j])
        pass

    if changed:
        player["cargo"] = cargo
        world_updated.emit()

func _contracts_sweep_expired() -> void:
    if _contracts_last_sweep_day == day:
        return
    _contracts_last_sweep_day = day

    var changed := false
    for i in range(_contracts_active.size()):
        var ct: Dictionary = _contracts_active[i]
        # 互換: 稼働中は "active" か "accepted"
        var st := String(ct.get("state",""))
        var is_active := (st == "active") or (st == "accepted")
        if not is_active:
            continue

        # 互換: deadline / deadline_day 両対応
        var dl := int(ct.get("deadline", day))
        if ct.has("deadline_day"):
            dl = int(ct.get("deadline_day"))

        if day > dl:
            ct["state"] = "expired"  # 既存の状態語彙に合わせる
            ct["expired_day"] = day
            _contracts_active[i] = ct
            var pid := String(ct.get("pid",""))
            var qty := int(ct.get("qty",0))
            var to_id := String(ct.get("to",""))
            _world_message("契約失効: %s×%d を %s へ納品（期限切れ）" % [
                get_product_name(pid), qty, get_city_name(to_id)
            ])
            changed = true

    if changed:
        world_updated.emit()


func contracts_accept(offer_id: int) -> bool:

    if not contracts_can_accept():
        return false
    _contracts_generate_monthly_offers()
    # 所在都市から検索（プレイヤー都市のみ受諾できる前提）
    var here := String(player.get("city",""))
    if not _contract_offers.has(here):
        return false
    var arr: Array = _contract_offers[here]
    var found := -1
    var off: Dictionary = {}
    for i in range(arr.size()):
        var o: Dictionary = arr[i]
        if int(o.get("id", -1)) == offer_id:
            found = i
            off = o
            break
    if found < 0:
        return false
    arr.remove_at(found)
    _contract_offers[here] = arr
    off["accepted_day"] = day
    off["state"] = "active"
    _contracts_active.append(off)
    _world_message("契約を受諾: %s を %s に %d 個 (期限 %s)" % [
        get_product_name(String(off.get("pid",""))),
        String(off.get("to","")),
        int(off.get("qty",0)),
        format_date(int(off.get("deadline", day)))
    ])
    return true

func contracts_get_offers_for(city_id: String) -> Array:
    if not contracts_enabled:
        return []
    _contracts_generate_monthly_offers()
    if not _contract_offers.has(city_id):
        return []
    _contracts_sweep_expired()
    return _contract_offers[city_id]

func _ensure_supply_sched(cid: String, pid: String) -> void:
    if not _supply_sched.has(cid):
        _supply_sched[cid] = {}
    if not _supply_sched[cid].has(pid):
        var day_seed: int = int(hash(cid + ":" + pid)) & 0x7fffffff
        var phase: int = day_seed % 7  # 都市×品目の曜日的位相（0〜6）

        var cool_base: int = max(1, int(supply_cooldown_days))
        var jitter: int = 0
        if int(supply_cooldown_jitter) != 0:
            var span: int = 2 * int(supply_cooldown_jitter) + 1
            var r: int = int(day_seed % span)  # 0..span-1
            jitter = r - int(supply_cooldown_jitter)  # -jitter..+jitter

        var cool: int = max(1, cool_base + jitter)

        _supply_sched[cid][pid] = {
            "buf": 0.0,
            "next": _day_serial() + phase,
            "cool": cool,
            "phase": phase
        }

# 暦から単調増加の“日通し番号”を作る（_day_index不在環境向け）
func _day_serial() -> int:
    var cal: Dictionary = get_calendar()
    var y: int = int(cal.get("year", 1))
    var m: int = int(cal.get("month", 1))
    var d: int = int(cal.get("day", 1))
    # 31日固定の簡易直列化：年*372 + (月-1)*31 + 日
    return y * 372 + (m - 1) * 31 + d


func _enqueue_prod(cid: String, pid: String, base_prod_today: float) -> void:
    _ensure_supply_sched(cid, pid)
    var cal: Dictionary = get_calendar()
    var m: int = int(cal.get("month", 1))
    var prod_today: float = base_prod_today * _prod_month_multiplier(pid, m)
    if prod_today <= 0.0:
        return
    var s: Dictionary = _supply_sched[cid][pid]
    var buf: float = float(s.get("buf", 0.0))
    buf += prod_today
    s["buf"] = buf
    _supply_sched[cid][pid] = s


func _try_release_batches(cid: String, pid: String) -> void:
    _ensure_supply_sched(cid, pid)
    var s: Dictionary = _supply_sched[cid][pid]
    var today: int = _day_serial()

    var next_check: int = int(s.get("next", today))
    if today < next_check:
        return

    var buf: float = float(s.get("buf", 0.0))
    if buf < float(supply_min_batch):
        # 閾値未満：次のチェック日だけ更新
        var cool: int = int(s.get("cool", max(1, int(supply_cooldown_days))))
        s["next"] = today + cool
        _supply_sched[cid][pid] = s
        return

    # 放出量決定（ロット化）
    var release: float = floor(buf)
    release = clamp(release, float(supply_min_batch), float(supply_max_batch))

    if release > 0.0:
        _add_stock_inflow(cid, pid, release)
        buf -= release

    # 次回チェック日
    var cool2: int = int(s.get("cool", max(1, int(supply_cooldown_days))))
    if supply_use_poisson:
        var base_gap: int = max(1, cool2)
        # 簡易ゆらぎ：today, cid, pidから擬似乱数を作る
        var seed_str: String = str(today) + ":" + cid + ":" + pid
        var jitter_raw: int = int(hash(seed_str)) & 0x7fffffff
        var jitter: int = int(jitter_raw % (base_gap + 1))
        s["next"] = today + base_gap + jitter
    else:
        s["next"] = today + cool2

    s["buf"] = buf
    _supply_sched[cid][pid] = s

# === Key Items（大切なもの）API =====================================

func give_key_item(id: String, count: int = 1, show_message: bool = true) -> bool:
    if id == "":
        return false
    if count <= 0:
        return false
    if player == null:
        return false

    if not player.has("key_items") or typeof(player.get("key_items")) != TYPE_DICTIONARY:
        player["key_items"] = {}

    var inv: Dictionary = player.get("key_items", {}) as Dictionary

    var def: Dictionary = {}
    if key_items.has(id):
        def = key_items[id] as Dictionary

    var is_unique: bool = int(def.get("unique", 0)) == 1
    var max_stack: int = int(def.get("max_stack", 99))
    if is_unique or max_stack <= 0:
        max_stack = 1

    var cur: int = int(inv.get(id, 0))
    if cur >= max_stack:
        return false

    var add: int = min(count, max_stack - cur)
    inv[id] = cur + add
    player["key_items"] = inv

    if show_message:
        var name_str: String = id
        if not def.is_empty():
            name_str = String(def.get("name_ja", def.get("name", id)))
        var msg: String = ""
        if add <= 1:
            msg = "%sを手に入れた。" % name_str
        else:
            msg = "%s×%dを手に入れた。" % [name_str, add]
        _world_message(msg)

    var auto_apply: bool = int(def.get("auto_apply", 0)) == 1
    if auto_apply:
        _apply_key_item_effect(def, add)

    world_updated.emit()
    return true

func _apply_key_item_effect(def: Dictionary, qty_added: int) -> void:
    if def.is_empty() or player == null:
        return
    var effect_type: String = String(def.get("effect_type", "")).to_lower()
    var target: String = String(def.get("effect_target", ""))
    var value_f: float = float(_num(def.get("effect_value", 0.0)))

    match effect_type:
        "cap_add":
            var delta: int = int(round(value_f)) * max(1, qty_added)
            if delta != 0:
                player["cap"] = int(player.get("cap", 0)) + delta
                _world_message("積載量が%d増えた。" % delta)
        "travel_tax_mult":
            # パッシブ効果だが、チュートリアル向けに変化を見える化
            if target != "" and value_f > 0.0:
                var pct: int = int(round(value_f * 100.0))
                _world_message("%sでの通行税が %d%% になった。" % [target, pct])
        _:
            pass

func has_key_item(id: String) -> bool:
    if player == null:
        return false
    var inv := player.get("key_items", {}) as Dictionary
    return int(inv.get(id, 0)) > 0

func remove_key_item(id: String, count: int = 1) -> void:
    # クエスト消費型のキーアイテム用（使わないものは呼ばなくてよい）
    if count <= 0:
        return
    if player == null:
        return

    var inv := player.get("key_items", {}) as Dictionary
    if not inv.has(id):
        return

    var cur: int = int(inv.get(id, 0))
    cur -= count
    if cur > 0:
        inv[id] = cur
    else:
        inv.erase(id)
    player["key_items"] = inv
