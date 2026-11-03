extends Control
signal played(card)
signal block_tried(card)   # 卡牌不可出(冷却/点数不足/已结束)时用户尝试拖拽 → 飘字提示
# 卡牌数据字段
var card_id: String = ""
var card_name: String = "测试卡"
var cost: int = 1
var card_type: String = ""
var desc: String = "测试描述"
var effect_param: String = ""            # 原始 effect_param 文本
var effect_params: Dictionary = {}       # 解析后的 {键:值}
var side: String = "" # 卡牌所属方："player" / "ai"

# ===== 三种卡牌款式（按效果/类型配色）=====
# attack=进攻(红) / defense=防守(蓝) / control=控制·特殊·辅助(绿)
const STYLE_COLORS := {
	"attack": {"bg": Color(0.93, 0.42, 0.42, 1.0), "border": Color(0.6, 0.16, 0.2, 1.0)},
	"defense": {"bg": Color(0.42, 0.62, 0.94, 1.0), "border": Color(0.16, 0.28, 0.6, 1.0)},
	"control": {"bg": Color(0.46, 0.86, 0.58, 1.0), "border": Color(0.16, 0.5, 0.25, 1.0)},
}
# 卡牌类型 → 款式：进攻(红) / 防守(蓝) / 中场·稀有指令·0费辅助(绿)
const TYPE_TO_STYLE := {
	"进攻": "attack",
	"防守": "defense",
	"中场": "control",
	"稀有指令": "control",
	"0费辅助": "control",
}
# UI节点引用
@onready var panel: Panel = $Panel
@onready var cost_label: Label = $Label
@onready var name_label: Label = $Label2
@onready var desc_label: Label = $Label3
@onready var _ui_font: Font = load("res://font/simhei.ttf")
# 拖拽状态
var tween: Tween
var home_pos: Vector2 = Vector2.ZERO
var drag_start: Vector2 = Vector2.ZERO
var is_dragging: bool = false
# 是否可出牌（由外部状态机控制，点数不足/非我方回合时禁用拖拽）
var can_play: bool = false

func _ready() -> void:
	# 将数据绑定到UI文本
	_apply_ui()
	# 按卡牌类型上色
	_apply_style()

# 用模板数据填充卡牌并刷新UI（由牌库构建时调用）
func set_card(tmpl: Dictionary) -> void:
	card_id = tmpl.get("card_id", "")
	card_name = tmpl.get("card_name", "未知卡")
	cost = int(tmpl.get("cost", 1))
	card_type = tmpl.get("card_type", "")
	desc = tmpl.get("desc", "")
	effect_param = tmpl.get("effect_param", "")
	effect_params = tmpl.get("effect_params", {})
	_apply_ui()
	_apply_style()

func _apply_ui() -> void:
	# 防御式更新：@onready 标签在节点进入场景树后才初始化，
	# AI 卡牌不进场景树、或 set_card 早于 add_child 调用时，标签为 nil，需跳过
	if cost_label:
		cost_label.text = str(cost)
		if _ui_font:
			cost_label.add_theme_font_override("font", _ui_font)
	if name_label:
		name_label.text = card_name
		if _ui_font:
			name_label.add_theme_font_override("font", _ui_font)
	if desc_label:
		desc_label.text = desc
		desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		if _ui_font:
			desc_label.add_theme_font_override("font", _ui_font)

# 按卡牌类型给卡面换上对应款式的底色/边框
func _apply_style() -> void:
	if panel == null:
		return
	var style: String = TYPE_TO_STYLE.get(card_type, "control")
	var palette: Dictionary = STYLE_COLORS[style]
	var sb := StyleBoxFlat.new()
	sb.bg_color = palette["bg"]
	sb.border_color = palette["border"]
	sb.border_width_left = 3
	sb.border_width_top = 3
	sb.border_width_right = 3
	sb.border_width_bottom = 3
	sb.set_corner_radius_all(10)
	panel.add_theme_stylebox_override("panel", sb)

func _on_panel_mouse_entered() -> void:
	if tween and not is_dragging and can_play:
		tween.kill()
		tween = create_tween()
		tween.tween_property(panel,"position",Vector2(0,-25),0.1)

func _on_panel_mouse_exited() -> void:
	if tween and not is_dragging:
		tween.kill()
		tween = create_tween()
		tween.tween_property(panel,"position",Vector2.ZERO,0.1)

func _get_play_zone() -> Panel:
	return get_parent().get_parent().get_node("PlayZone")

func _input(event):
	# 不可出牌时：拦截拖拽，但用户试图点这张牌时发提示(飘字"冷却中/点数不足")
	if not can_play:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			if get_global_rect().has_point(get_global_mouse_position()):
				block_tried.emit(self)
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			var mouse_pos = get_global_mouse_position()
			if get_global_rect().has_point(mouse_pos):
				is_dragging = true
				home_pos = position
				drag_start = mouse_pos
				_get_play_zone().visible = true
		else:
			if is_dragging:
				is_dragging = false
				var mouse_up = get_global_mouse_position()
				var pz = _get_play_zone()
				if pz.get_global_rect().has_point(mouse_up):
					play_card()
				else:
					var t = create_tween()
					t.tween_property(self, "position", home_pos, 0.2).set_trans(Tween.TRANS_BACK)
				pz.visible = false
	elif event is InputEventMouseMotion and is_dragging:
		var mouse_pos = get_global_mouse_position()
		position = home_pos + (mouse_pos - drag_start)

func play_card():
	var t = create_tween()
	t.tween_property(self, "modulate:a", 0.0, 0.2)
	t.tween_callback(emit_signal.bind("played", self))
