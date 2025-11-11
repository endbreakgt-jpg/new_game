extends Panel
class_name Dialog

signal started
signal finished
signal advanced(index: int)

@export var input_action_next: StringName = &"talk"
@export var chars_per_sec: float = 30.0
@export var debug_skip_delay: bool = false  # 全文即表示（デバッグ）
@export var dimmer_opacity: float = 0.55    # 暗幕の濃さ(0.0–1.0)
@export var portrait_node_path: NodePath    # ポートレート貼り付け先（未指定なら自動探索）

@onready var character_name: Label = $VBoxContainer/Name
@onready var content: RichTextLabel = $VBoxContainer/Content
@onready var next: Control = $Next
@onready var text_delay: Timer = $TextDelay  # 今回は未使用

var is_dialog_mode: bool = false
var text_to_display: Array[String] = []
var current_index: int = 0
var current_text_index: int = 0
var _input_block_until_ms: int = 0
var _char_accum: float = 0.0
var _current_line_text: String = ""

var _blocker: Control = null                # フルスクリーン入力ブロッカー
var _portrait_rect: TextureRect = null      # キャラ絵表示先

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    _setup_layout()
    _resolve_portrait_node()
    if content:
        content.add_theme_color_override("default_color", Color(1, 1, 1))
        content.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
        content.scroll_active = false
        content.text = ""
        content.visible_characters = 0
    visible = false
    next.visible = false
    set_process(false)

# 画面下固定のレイアウト＆見た目
func _setup_layout() -> void:
    set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
    anchor_left = 0.0
    anchor_right = 1.0
    anchor_top = 1.0
    anchor_bottom = 1.0
    offset_left = 16
    offset_right = -16
    var h := 160
    offset_top = -h - 12
    offset_bottom = -12
    custom_minimum_size = Vector2(0, h)
    z_index = 999
    mouse_filter = Control.MOUSE_FILTER_STOP
    var sb := StyleBoxFlat.new()
    sb.bg_color = Color(0, 0, 0, 0.75)
    sb.border_color = Color(0.35, 0.35, 0.35)
    sb.border_width_left = 2
    sb.border_width_top = 2
    sb.border_width_right = 2
    sb.border_width_bottom = 2
    sb.corner_radius_top_left = 8
    sb.corner_radius_top_right = 8
    sb.corner_radius_bottom_left = 8
    sb.corner_radius_bottom_right = 8
    add_theme_stylebox_override("panel", sb)

# --- ポートレート表示先の解決 ---
func _resolve_portrait_node() -> void:
    _portrait_rect = null
    # 1) Inspectorで指定されていれば最優先
    if portrait_node_path != NodePath():
        var n := get_node_or_null(portrait_node_path)
        if n and n is TextureRect:
            _portrait_rect = n
    # 2) 名前で自動探索（どちらかを許容）
    if _portrait_rect == null:
        var cand := find_child("Portrait", true, false)
        if cand and cand is TextureRect:
            _portrait_rect = cand
    if _portrait_rect == null:
        var cand2 := find_child("Character", true, false)
        if cand2 and cand2 is TextureRect:
            _portrait_rect = cand2
    # 3) 最後の手段：子孫の最初の TextureRect
    if _portrait_rect == null:
        _portrait_rect = _find_first_texture_rect(self)
    if _portrait_rect:
        _portrait_rect.visible = _portrait_rect.texture != null

func _find_first_texture_rect(n: Node) -> TextureRect:
    if n is TextureRect:
        return n
    for ch in n.get_children():
        var r := _find_first_texture_rect(ch)
        if r:
            return r
    return null

# --- 入力ブロッカー（暗幕） ---
func _ensure_blocker() -> void:
    if _blocker and is_instance_valid(_blocker):
        return
    var b := Control.new()
    b.name = "InputBlocker"
    b.top_level = true
    b.mouse_filter = Control.MOUSE_FILTER_STOP
    b.focus_mode = Control.FOCUS_ALL
    b.set_anchors_preset(Control.PRESET_FULL_RECT)
    b.z_index = 998
    var dim := ColorRect.new()
    dim.name = "Dimmer"
    dim.color = Color(0, 0, 0, clamp(dimmer_opacity, 0.0, 1.0))
    dim.set_anchors_preset(Control.PRESET_FULL_RECT)
    b.add_child(dim)
    add_child(b)
    _blocker = b
    _blocker.visible = false

func _show_blocker() -> void:
    _ensure_blocker()
    if _blocker: _blocker.visible = true

func _hide_blocker() -> void:
    if _blocker and is_instance_valid(_blocker):
        _blocker.visible = false

# --- ポートレートAPI ---
func set_portrait(tex: Texture2D) -> void:
    if _portrait_rect:
        _portrait_rect.texture = tex
        _portrait_rect.visible = tex != null

func set_portrait_by_path(path: String) -> void:
    var p := _normalize_portrait_path(path)
    if p == "":
        set_portrait(null); return
    var tex := load(p) as Texture2D
    if tex == null:
        push_warning("Dialog: portrait load failed: %s" % p)
    set_portrait(tex)

func _normalize_portrait_path(p: String) -> String:
    var s := p.strip_edges()
    if s == "":
        return ""
    if s.begins_with("res://"):
        return s
    # 拡張子無指定にも対応（例: \"guide_01\" → png と仮定）
    if s.find("/") == -1:
        s = "res://ui/portraits/%s" % s
    if s.get_extension() == "":
        s += ".png"
    return s

# --- ダイアログ制御 ---
func show_lines(lines: Array[String], speaker: String = "") -> void:
    text_to_display = []
    for s in lines:
        text_to_display.append(str(s))
    character_name.text = speaker
    start_dialog()

func start_dialog() -> void:
    if content:
        content.text = ""
        content.visible_characters = 0
    current_text_index = 0
    current_index = 0
    _char_accum = 0.0
    _current_line_text = ""
    is_dialog_mode = true
    _ensure_on_top()
    _show_blocker()
    visible = true
    next.visible = false
    _input_block_until_ms = Time.get_ticks_msec() + 200
    set_process(true)
    started.emit()

func stop_dialog() -> void:
    is_dialog_mode = false
    set_process(false)
    visible = false
    next.visible = false
    _current_line_text = ""
    _hide_blocker()
    finished.emit()

func _process(delta: float) -> void:
    if not is_dialog_mode:
        return
    if debug_skip_delay:
        _show_line_instant()
        return
    if current_index >= text_to_display.size():
        stop_dialog()
        return
    var line := text_to_display[current_index]
    if line.length() == 0:
        _current_line_text = ""
        _apply_line_display("")
        next.visible = true
        return
    if _current_line_text != line:
        _current_line_text = line
        current_text_index = 0
        _char_accum = 0.0
        _apply_line_display(line, current_text_index)
    if current_text_index < line.length():
        _char_accum += delta * max(1.0, chars_per_sec)
        while _char_accum >= 1.0 and current_text_index < line.length():
            current_text_index += 1
            _char_accum -= 1.0
        if _char_accum < 0.0:
            _char_accum = 0.0
        _apply_line_display(line, current_text_index)
    else:
        next.visible = true

func _input(event: InputEvent) -> void:
    if not is_dialog_mode:
        return
    if Time.get_ticks_msec() < _input_block_until_ms:
        get_viewport().set_input_as_handled()
        return
    if event.is_action_pressed(input_action_next):
        if current_index >= text_to_display.size():
            stop_dialog()
        else:
            var line := text_to_display[current_index]
            if current_text_index < line.length() and current_text_index != 0:
                _current_line_text = line
                _apply_line_display(line)
                current_text_index = line.length()
                next.visible = true
            else:
                current_index += 1
                advanced.emit(current_index)
                if current_index < text_to_display.size():
                    current_text_index = 0
                    next.visible = false
                    _current_line_text = ""
                else:
                    stop_dialog()
        get_viewport().set_input_as_handled()
        return
    get_viewport().set_input_as_handled()

func _unhandled_input(event: InputEvent) -> void:
    if is_dialog_mode:
        get_viewport().set_input_as_handled()

func _show_line_instant() -> void:
    if current_index >= text_to_display.size():
        stop_dialog()
        return
    var line := text_to_display[current_index]
    _current_line_text = line
    _apply_line_display(line)
    current_text_index = line.length()
    next.visible = true

func _ensure_on_top() -> void:
    if not top_level:
        top_level = true
    z_index = max(z_index, 999)
    call_deferred("move_to_top")

func _apply_line_display(text: String, visible_chars: int = -1) -> void:
    if content == null:
        return
    if content.text != text:
        content.text = text
    if visible_chars < 0:
        content.visible_characters = -1
    else:
        content.visible_characters = visible_chars
