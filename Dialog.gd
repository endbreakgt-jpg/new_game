extends Panel
class_name Dialog

signal started
signal finished
signal advanced(index: int)

@export var input_action_next: StringName = &"talk"
@export var chars_per_sec: float = 30.0

@onready var character_name: Label = $VBoxContainer/Name
@onready var content: RichTextLabel = $VBoxContainer/Content
@onready var next: Control = $Next
@onready var text_delay: Timer = $TextDelay

var is_dialog_mode: bool = false
var text_to_display: Array[String] = []
var current_index: int = 0
var current_text_index: int = 0

func _ready() -> void:
    _setup_layout()
    visible = false
    next.visible = false
    _apply_timer_wait_time()
    if not text_delay.timeout.is_connected(_on_text_delay_timeout):
        text_delay.timeout.connect(_on_text_delay_timeout)

# --- NEW: place message window at the bottom of the screen ---
func _setup_layout() -> void:
    # Anchor to screen bottom, with margins. Works even when added under HUD.
    set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
    anchor_left = 0.0
    anchor_right = 1.0
    anchor_top = 1.0
    anchor_bottom = 1.0
    offset_left = 16
    offset_right = -16
    var h := 160  # height of the message window
    offset_top = -h - 12   # distance from bottom
    offset_bottom = -12
    custom_minimum_size = Vector2(0, h)
    z_index = 999  # bring to front
    mouse_filter = Control.MOUSE_FILTER_STOP

    # simple dark style (optional - safe if using theme)
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

func _apply_timer_wait_time() -> void:
    if chars_per_sec <= 0.0:
        chars_per_sec = 30.0
    text_delay.wait_time = 1.0 / chars_per_sec

func show_lines(lines: Array[String], speaker: String = "") -> void:
    text_to_display = []
    for s in lines:
        text_to_display.append(str(s))
    character_name.text = speaker
    start_dialog()

func start_dialog() -> void:
    content.text = ""
    current_text_index = 0
    current_index = 0
    is_dialog_mode = true
    visible = true
    next.visible = false
    text_delay.start()
    started.emit()

func stop_dialog() -> void:
    is_dialog_mode = false
    visible = false
    text_delay.stop()
    next.visible = false
    finished.emit()

func _on_text_delay_timeout() -> void:
    if current_index < text_to_display.size():
        var line := text_to_display[current_index]
        if current_text_index < line.length():
            content.text = line.substr(0, current_text_index + 1)
            current_text_index += 1
        else:
            text_delay.stop()
            next.visible = true
    else:
        stop_dialog()

func _input(event: InputEvent) -> void:
    if not is_dialog_mode:
        return
    if event.is_action_pressed(input_action_next):
        # 1) まだ行が残っている
        if current_index < text_to_display.size():
            var line := text_to_display[current_index]
            # 1a) 途中なら即表示
            if current_text_index < line.length() and current_text_index != 0:
                content.text = line
                current_text_index = line.length()
                text_delay.stop()
                next.visible = true
            else:
                # 1b) 次の行へ
                current_index += 1
                advanced.emit(current_index)
                if current_index < text_to_display.size():
                    current_text_index = 0
                    next.visible = false
                    text_delay.start()
                else:
                    stop_dialog()

func is_busy() -> bool:
    return is_dialog_mode and current_index < text_to_display.size()

func set_speed(new_chars_per_sec: float) -> void:
    chars_per_sec = max(1.0, new_chars_per_sec)
    _apply_timer_wait_time()
