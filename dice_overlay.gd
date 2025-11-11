extends Control
class_name DiceOverlay

signal roll_started(kind: String)
signal roll_revealed(value: int)
signal roll_done(kind: String, value: int)

@export var reel_time: float = 0.20
@export var hold_extreme: float = 0.50
@export var hold_normal: float = 0.00
@export var dimmer_opacity: float = 0.35

var _kind: String = ""
var _value: int = 0
var _label: Label = null
var _dimmer: ColorRect = null

func _ready() -> void:
    top_level = true
    z_index = 1200
    mouse_filter = Control.MOUSE_FILTER_STOP
    set_anchors_preset(Control.PRESET_FULL_RECT)
    _ensure_ui()
    visible = false

func _ensure_ui() -> void:
    if _dimmer == null:
        _dimmer = ColorRect.new()
        _dimmer.name = "Dimmer"
        _dimmer.color = Color(0,0,0,dimmer_opacity)
        _dimmer.set_anchors_preset(Control.PRESET_FULL_RECT)
        add_child(_dimmer)
    var holder := get_node_or_null("Holder") as CenterContainer
    if holder == null:
        holder = CenterContainer.new()
        holder.name = "Holder"
        holder.set_anchors_preset(Control.PRESET_FULL_RECT)
        add_child(holder)
    if _label == null:
        _label = Label.new()
        _label.name = "Face"
        _label.text = "--"
        _label.add_theme_font_size_override("font_size", 72)
        _label.add_theme_color_override("font_color", Color.WHITE)
        holder.add_child(_label)

func show_number(kind: String, value: int) -> void:
    _kind = kind
    _value = clamp(value, 1, 100)
    _ensure_ui()
    visible = true
    roll_started.emit(_kind)
    _label.text = "--"
    # Simple reel: fade in, then reveal number
    var tw := create_tween()
    modulate.a = 0.0
    tw.tween_property(self, "modulate:a", 1.0, reel_time).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
    await tw.finished
    _reveal()

func _reveal() -> void:
    _label.text = ("%02d" % _value) if _value < 100 else "100"
    roll_revealed.emit(_value)
    var hold: float = hold_normal
    if _value == 1 or _value == 100:
        hold = hold_extreme
    await get_tree().create_timer(hold).timeout
    _finish()

func _finish() -> void:
    var tw := create_tween()
    tw.tween_property(self, "modulate:a", 0.0, 0.12).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
    await tw.finished
    visible = false
    roll_done.emit(_kind, _value)
