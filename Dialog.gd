extends Panel
class_name Dialog

signal started
signal finished
signal advanced(index: int)

@export var input_action_next: StringName = &"talk"
@export var chars_per_sec: float = 30.0
@export var debug_skip_delay: bool = false  # 全文即表示（デバッグ）

@onready var character_name: Label = $VBoxContainer/Name
@onready var content: RichTextLabel = $VBoxContainer/Content
@onready var next: Control = $Next
@onready var text_delay: Timer = $TextDelay  # ← 残しておくが、今回は使わない

var is_dialog_mode: bool = false
var text_to_display: Array[String] = []
var current_index: int = 0
var current_text_index: int = 0
var _input_block_until_ms: int = 0
var _char_accum: float = 0.0  # 文字送りの積算（Timerの代わり）

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_WHEN_PAUSED
	_setup_layout()
	# 読みやすさ（黒背景に白文字、自動折返し）
	if content:
		content.add_theme_color_override("default_color", Color(1, 1, 1))
		content.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		content.scroll_active = false
		content.text = ""
	visible = false
	next.visible = false
	set_process(false) # 初期は止めておく

# 画面下に固定するレイアウト
func _setup_layout() -> void:
	set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	anchor_left = 0.0; anchor_right = 1.0
	anchor_top  = 1.0; anchor_bottom = 1.0
	offset_left = 16;  offset_right = -16
	var h := 160
	offset_top = -h - 12; offset_bottom = -12
	custom_minimum_size = Vector2(0, h)
	z_index = 999
	mouse_filter = Control.MOUSE_FILTER_STOP
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0.75)
	sb.border_color = Color(0.35, 0.35, 0.35)
	sb.border_width_left = sb.border_width_top ==2
	sb.border_width_right = sb.border_width_bottom == 2
	sb.corner_radius_top_left = sb.corner_radius_top_right == 8
	sb.corner_radius_bottom_left = sb.corner_radius_bottom_right == 8
	add_theme_stylebox_override("panel", sb)

func show_lines(lines: Array[String], speaker: String = "") -> void:
	text_to_display = []
	for s in lines: text_to_display.append(str(s))
	character_name.text = speaker
	start_dialog()

func start_dialog() -> void:
	if content: content.text = ""
	current_text_index = 0
	current_index = 0
	_char_accum = 0.0
	is_dialog_mode = true
	_ensure_on_top()
	visible = true
	next.visible = false
	_input_block_until_ms = Time.get_ticks_msec() + 200
	set_process(true) # ← Timerの代わりに_processで駆動
	started.emit()

func stop_dialog() -> void:
	is_dialog_mode = false
	set_process(false)
	visible = false
	next.visible = false
	finished.emit()

func _process(delta: float) -> void:
	if not is_dialog_mode: return
	# 全文即表示モード
	if debug_skip_delay:
		_show_line_instant()
		return
	# 文字送り（Timerの代わりにフレームで進める）
	if current_index >= text_to_display.size():
		stop_dialog()
		return
	var line := text_to_display[current_index]
	if line.length() == 0:
		# 空行扱い
		content.text = ""
		next.visible = true
		return
	if current_text_index < line.length():
		_char_accum += delta * max(1.0, chars_per_sec)
		while _char_accum >= 1.0 and current_text_index < line.length():
			current_text_index += 1
			_char_accum -= 1.0
		content.text = line.substr(0, current_text_index)
	else:
		# 行末まで描画済み → 次へ入力待ち
		next.visible = true

func _input(event: InputEvent) -> void:
	if not is_dialog_mode: return
	if Time.get_ticks_msec() < _input_block_until_ms: return
	if event.is_action_just_pressed(input_action_next):
		if current_index >= text_to_display.size():
			stop_dialog()
			return
		var line := text_to_display[current_index]
		# 途中なら即全文、描画済みなら次の行へ
		if current_text_index < line.length() and current_text_index != 0:
			content.text = line
			current_text_index = line.length()
			next.visible = true
		else:
			current_index += 1
			advanced.emit(current_index)
			if current_index < text_to_display.size():
				current_text_index = 0
				next.visible = false
			else:
				stop_dialog()

func _show_line_instant() -> void:
	if current_index >= text_to_display.size():
		stop_dialog()
		return
	var line := text_to_display[current_index]
	content.text = line
	current_text_index = line.length()
	next.visible = true

func _ensure_on_top() -> void:
	if not top_level: top_level = true
	z_index = max(z_index, 999)
	call_deferred("raise")
