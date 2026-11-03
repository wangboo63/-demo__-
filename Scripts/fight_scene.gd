extends Control
## ============================================================
##  球场战术足球 · 战斗主控（球员FSM + 球实体FSM版）
##  球员：独立 PlayerUnit，各自状态机（带球/支援/盯防/逼抢/抢球…）。
##  球  ：独立 Ball，自己的状态机（自由/带球/传球/射门），
##        传球与射门走真实飞行轨迹，捡球需球员真跑到脚下。
##  场景：协调 上下文/卡牌订单/射门计分/真实规则(越位·犯规·出界)/手牌。
## ============================================================

const CARD = preload("res://Prefabs/card.tscn")

# ---------- 布局 ----------
# 球场：真实比例 105:68（716x464 ≈ 1.543:1），贴屏幕最左并向上延伸到顶部，右侧留给信息面板
const PITCH := Rect2(16, 16, 716, 464)
const CARD_WIDTH := 120.0
const CARD_GAP := 20.0
const MAX_HAND_SIZE := 4
const UNIT_SIZE := 24.0
const MOVE_MARGIN := 40.0

# ---------- 整场比赛(无回合制，只限时间) ----------
const MAX_TP := 4
const MATCH_DURATION_DEFAULT := 120.0   # 默认整场总时长(秒)；实际由"设置"里的比赛时长决定
const TP_REGEN_CD := 8.0             # 战术点随时间恢复间隔
const BUFF_TICK_CD := 10.0           # Buff 按时间扣时长间隔
const START_CARDS := 2               # 开局手牌数
const DRAW_OPERATE_CD := 5.0
const DRAW_CHANCE_RECOVER_CD := 20.0
const BASE_DRAW_CHANCE := 2
const PLAY_CARD_CD := 3.0

# ---------- 射门 ----------
const SHOOT_CD := 2.0
const AI_SHOOT_INTERVAL_DEFAULT := 4.0
const SHOT_BASE := 0.40
const SHOT_ATTACK_WEIGHT := 0.30
const SHOT_DEFENSE_WEIGHT := 0.20
const GK_SAVE := 0.12
const SHOT_DUR := 0.5          # 射门飞行时长(真实轨迹)
const PASS_DUR := 0.45         # 传球飞行时长
const LONG_PASS_DUR := 0.7

# ---------- 足球节奏 ----------
const PASS_INTERVAL := 2.8
const POSSESSION_SWITCH := 9.0

# 卡牌类型
const TYPE_ATTACK := "进攻"
const TYPE_DEFENSE := "防守"
const TYPE_MID := "中场"

# ---------- 节点引用 ----------
@onready var ui_turn: Label = $TurnLabel
@onready var ui_tp: Label = $TpLabel
@onready var ui_timer: Label = $RoundTimerLabel
@onready var ui_draw: Label = $DrawLabel
@onready var ui_score: Label = $ScoreLabel
@onready var ui_p_buff: Label = $PlayerBuffLabel
@onready var ui_a_buff: Label = $AiBuffLabel
@onready var card_root: Control = $Control
@onready var btn_draw: Button = $DrawCardButton
@onready var btn_shoot: Button = $ShootButton
@onready var btn_save: Button = $SaveExitButton
@onready var ui_slot: Label = $SlotLabel
@onready var btn_giveup: Button = $GiveUpButton

enum State { INIT, ROUND_ACTIVE, ROUND_ENDING, GAME_OVER }
var state: State = State.INIT

var player := {
	"deck": [], "hand": [], "discard": [],
	"tp": MAX_TP, "draw_chance": BASE_DRAW_CHANCE, "draw_cd": 0.0, "play_cd": 0.0,
	"goals": 0, "defense": 0.50, "shot_bonus": 0.0, "shoot_cd": 0.0, "ended_round": false,
}
var ai := {
	"deck": [], "hand": [], "discard": [],
	"tp": MAX_TP, "draw_chance": BASE_DRAW_CHANCE, "draw_cd": 0.0, "play_cd": 0.0,
	"goals": 0, "defense": 0.50, "shot_bonus": 0.0, "shoot_cd": 0.0, "ended_round": false,
}

var buff_system: BuffSystem
# 设置相关(读 DataLoader.settings 覆盖)
var match_duration: float = MATCH_DURATION_DEFAULT   # 比赛时长(由设置决定)
var ai_shoot_interval: float = AI_SHOOT_INTERVAL_DEFAULT  # AI 射门间隔(按难度)
var ai_speed_factor := 1.0     # AI 球员速度系数(难度)：简单慢/困难快
var ai_score_factor := 1.0     # AI 出牌评分系数(难度)：简单保守/困难激进
var ai_shot_bonus := 0.0       # AI 射门成功率加成(难度)：简单负/困难正
var match_time_left: float = MATCH_DURATION_DEFAULT
var draw_chance_timer: float = 0.0
var tp_regen_timer: float = 0.0
var buff_tick_timer: float = 0.0
var ai_think_timer: float = 0.0
var ai_shoot_timer: float = 0.0

# 球员与球实体
var units: Array = []
var unit_root: Node2D
var ball: Ball
var pending_offside := false      # 传球瞬间是否越位（到达时判罚）
var pass_timer := 0.0
var possession_timer := 0.0
var pending_shot := {"side": "", "scored": false, "success": 0.0}
var pass_receiver: Node = null   # 传球真正目标(到点后只传给他)
var pass_wild := false           # 本次是否为传大失误(固定飞向旧点，可出界)
var _role_counts := {"player": {}, "ai": {}}

# 初始阵型（normalized）
const PLAYER_FORM := [
	{"role": "前锋", "nx": 0.42, "ny": 0.18},
	{"role": "前锋", "nx": 0.48, "ny": 0.50},
	{"role": "前锋", "nx": 0.54, "ny": 0.82},
	{"role": "后卫", "nx": 0.20, "ny": 0.28},
	{"role": "后卫", "nx": 0.24, "ny": 0.72},
	{"role": "守门员", "nx": 0.06, "ny": 0.50},
]
const AI_FORM := [
	{"role": "前锋", "nx": 0.58, "ny": 0.18},
	{"role": "前锋", "nx": 0.52, "ny": 0.50},
	{"role": "前锋", "nx": 0.46, "ny": 0.82},
	{"role": "后卫", "nx": 0.80, "ny": 0.28},
	{"role": "后卫", "nx": 0.76, "ny": 0.72},
	{"role": "守门员", "nx": 0.94, "ny": 0.50},
]

# ============================================================
# 每张卡的专属跑位方案
# ============================================================
const TACTICS := {
	"C001": {"name": "快速反击冲刺", "st": 130.0, "drop": 0, "st_y": "wide",    "df": 70.0,  "df_gain": 0.0},
	"C002": {"name": "边锋内切中路", "st": 110.0, "drop": 0, "st_y": "tight",   "df": 30.0,  "df_gain": 0.0},
	"C003": {"name": "边路分散拉扯", "st": 115.0, "drop": 1, "st_y": "wide",    "df": 45.0,  "df_gain": 0.0},
	"C004": {"name": "后点长传前插", "st": 125.0, "drop": 0, "st_y": "wedge",   "df": 35.0,  "df_gain": 0.0},
	"C005": {"name": "前锋换位渗透", "st": 95.0,  "drop": 0, "st_y": "swap_lanes", "df": 20.0, "df_gain": 0.0},
	"C006": {"name": "拉开远射空间", "st": 80.0,  "drop": 1, "st_y": "fan",     "df": 25.0,  "df_gain": 0.0},
	"C007": {"name": "下底包抄抢点", "st": 105.0, "drop": 0, "st_y": "wide",    "df": 30.0,  "df_gain": 0.0},
	"C008": {"name": "全线碾压前压", "st": 150.0, "drop": 0, "st_y": "tight",   "df": 80.0,  "df_gain": 0.0},
	"C009": {"name": "交叉插入禁区", "st": 120.0, "drop": 0, "st_y": "swap_lanes", "df": 40.0, "df_gain": 0.0},
	"C010": {"name": "中路直线前插", "st": 135.0, "drop": 0, "st_y": "wedge",   "df": 30.0,  "df_gain": 0.0},
	"X001": {"name": "回撤重组站位", "st": -40.0, "drop": 0, "st_y": "keep",    "df": -20.0, "df_gain": 0.0},
	"X002": {"name": "集中中路抢点", "st": 100.0, "drop": 0, "st_y": "tight",   "df": 25.0,  "df_gain": 0.0},
	"D001": {"name": "低位收缩", "st": -90.0, "drop": 0, "st_y": "tight",   "df": -110.0, "df_gain": 0.15},
	"D002": {"name": "铁桶阵防守", "st": -70.0, "drop": 0, "st_y": "tight",   "df": -125.0, "df_gain": 0.12},
	"D003": {"name": "造越位前提", "st": 0.0,   "drop": 0, "st_y": "fan",     "df": 50.0,   "df_gain": 0.05},
	"D004": {"name": "贴身盯防", "st": 0.0,     "drop": 0, "st_y": "keep",    "df": -20.0,  "df_gain": 0.10},
	"D005": {"name": "就近上抢", "st": -20.0,   "drop": 0, "st_y": "keep",    "df": 60.0,   "df_gain": 0.05},
	"D006": {"name": "密集站住中路", "st": -50.0, "drop": 0, "st_y": "tight", "df": -60.0,  "df_gain": 0.12},
	"D007": {"name": "门将出击前压", "st": -30.0, "drop": 0, "st_y": "keep",  "df": 70.0,   "df_gain": 0.08},
	"D008": {"name": "防线回撤", "st": -40.0,   "drop": 0, "st_y": "keep",    "df": -90.0,  "df_gain": 0.12},
	"M001": {"name": "全场紧逼绞杀", "st": 70.0, "drop": 0, "st_y": "tight", "df": 60.0,   "df_gain": 0.04},
	"M002": {"name": "高位压迫", "st": 100.0,   "drop": 0, "st_y": "fan",     "df": 60.0,   "df_gain": 0.04},
	"M003": {"name": "前后拉开传导", "st": -30.0, "drop": 0, "st_y": "fan",   "df": -20.0,  "df_gain": 0.04},
	"M004": {"name": "放缓节奏站位", "st": -40.0, "drop": 0, "st_y": "keep",  "df": -10.0,  "df_gain": 0.02},
	"M005": {"name": "前场就地围抢", "st": 20.0,  "drop": 0, "st_y": "tight", "df": 50.0,   "df_gain": 0.03},
	"M006": {"name": "中场横向拉开", "st": 40.0,  "drop": 0, "st_y": "fan",   "df": 20.0,   "df_gain": 0.03},
	"M007": {"name": "中场盯人站位", "st": 30.0,  "drop": 0, "st_y": "keep",  "df": 40.0,   "df_gain": 0.04},
	"M008": {"name": "回撤休整", "st": -50.0,    "drop": 0, "st_y": "keep",   "df": -30.0,  "df_gain": 0.02},
	"M009": {"name": "一对一卡位逼抢", "st": 10.0, "drop": 0, "st_y": "tight", "df": 40.0,  "df_gain": 0.04},
	"S001": {"name": "全队回撤换人", "st": -110.0, "drop": 0, "st_y": "keep", "df": -90.0,  "df_gain": 0.0},
	"S002": {"name": "攻防互换变阵", "st": -80.0, "drop": 0, "st_y": "swap_lanes", "df": 80.0, "df_gain": 0.0},
	"S003": {"name": "极限压上猛攻", "st": 160.0, "drop": 0, "st_y": "wide",   "df": 90.0,   "df_gain": 0.0},
	"S004": {"name": "后卫压上助攻", "st": 60.0,  "drop": 0, "st_y": "fan",    "df": 120.0,  "df_gain": 0.0},
	"F001": {"name": "前锋假动作晃动", "st": 10.0, "drop": 0, "st_y": "keep",  "df": 0.0,    "df_gain": 0.0},
	"F002": {"name": "保持观察站位", "st": 0.0,   "drop": 0, "st_y": "keep",   "df": 0.0,    "df_gain": 0.0},
}


func _ready() -> void:
	if not DataLoader.load_all():
		push_error("[战斗] 数据加载失败")
	DataLoader.load_settings()   # 读取设置(音量/难度/时长)
	_apply_settings()
	AudioMgr.play_music("res://audio/bgm/比赛音效.mp3")   # 进入比赛→比赛音效循环
	buff_system = BuffSystem.new()
	unit_root = Node2D.new()
	add_child(unit_root)
	_init_units()
	_create_ball()
	if DataLoader.resume_snapshot.is_empty():
		# 全新一局
		_init_decks()
		_refresh_hud()
		change_state(State.ROUND_ACTIVE)
	else:
		# 读档：从快照恢复整场（不重新抽牌/重置）
		_restore_from_snapshot(DataLoader.resume_snapshot)
		DataLoader.resume_snapshot = {}


# ============================================================
# 应用设置：比赛时长 / AI 难度(射门间隔·球员速度·出牌评分·射门成功率)
# ============================================================
func _apply_settings() -> void:
	var s: Dictionary = DataLoader.settings
	match_duration = float(s.get("match_duration", MATCH_DURATION_DEFAULT))
	var diff := str(s.get("difficulty", "normal"))
	match diff:
		"easy":
			ai_shoot_interval = 5.5
			ai_speed_factor = 0.88
			ai_score_factor = 0.80
			ai_shot_bonus = -0.06
		"hard":
			ai_shoot_interval = 3.0
			ai_speed_factor = 1.12
			ai_score_factor = 1.18
			ai_shot_bonus = 0.06
		_: # normal
			ai_shoot_interval = AI_SHOOT_INTERVAL_DEFAULT
			ai_speed_factor = 1.0
			ai_score_factor = 1.0
			ai_shot_bonus = 0.0


# ============================================================
# 球场绘制（草皮/线/禁区/球门）
# ============================================================
func _draw() -> void:
	draw_rect(PITCH, Color(0.12, 0.55, 0.25, 1.0))
	var wl := Color(1, 1, 1, 0.55)
	draw_rect(PITCH, Color(1, 1, 1, 0.8), false, 2.0)
	draw_line(Vector2(PITCH.position.x + PITCH.size.x * 0.5, PITCH.position.y),
		Vector2(PITCH.position.x + PITCH.size.x * 0.5, PITCH.position.y + PITCH.size.y), wl, 2.0)
	draw_arc(PITCH.position + Vector2(PITCH.size.x * 0.5, PITCH.size.y * 0.5), 50.0, 0, TAU, 64, wl, 2.0)
	var cy := PITCH.position.y + PITCH.size.y * 0.5
	var box_w := 110.0
	var box_h := 250.0
	draw_rect(Rect2(PITCH.position.x, cy - box_h * 0.5, box_w, box_h), Color(1, 1, 1, 0), false, 2.0)
	draw_rect(Rect2(PITCH.position.x + PITCH.size.x - box_w, cy - box_h * 0.5, box_w, box_h), Color(1, 1, 1, 0), false, 2.0)
	_draw_goal(PITCH.position.x, cy)
	_draw_goal(PITCH.position.x + PITCH.size.x, cy)
	draw_string(ThemeDB.fallback_font, PITCH.position + Vector2(16, 24), "← AI 进攻方向", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(1, 1, 1, 0.7))
	draw_string(ThemeDB.fallback_font, PITCH.position + Vector2(PITCH.size.x - 150, 24), "玩家进攻方向 →", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(1, 1, 1, 0.7))


func _draw_goal(gx: float, cy: float) -> void:
	var w := 30.0   # 门框宽度（以门线为中心左右对称）
	var h := 110.0  # 门框高度（明显可见）
	# 球门以门线为中心，一半在场内一半在场外，左右完全对称，贴边也不出屏
	var box := Rect2(gx - w * 0.5, cy - h * 0.5, w, h)
	draw_rect(box, Color(1, 1, 1, 0.9), false, 3.0)
	draw_rect(box, Color(1, 1, 1, 0.12))
	for i in range(1, 4):
		var t := i / 4.0
		draw_line(Vector2(box.position.x, box.position.y + box.size.y * t),
			Vector2(box.position.x + box.size.x, box.position.y + box.size.y * t), Color(1, 1, 1, 0.35), 1.0)
	# 后柱线固定落在门线 gx 上
	draw_line(Vector2(gx, box.position.y), Vector2(gx, box.position.y + box.size.y), Color(1, 1, 1, 0.35), 1.0)


# ============================================================
# 球员 / 球 初始化
# ============================================================
func _init_units() -> void:
	units.clear()
	for t in PLAYER_FORM:
		units.append(_spawn_unit("player", t.role, t.nx, t.ny))
	for t in AI_FORM:
		units.append(_spawn_unit("ai", t.role, t.nx, t.ny))


func _spawn_unit(side: String, role: String, nx: float, ny: float) -> PlayerUnit:
	var u := PlayerUnit.new()
	u.side = side
	u.role = role
	var idx: int = _role_counts[side].get(role, 0)
	_role_counts[side][role] = idx + 1
	u.lane_idx = idx
	u.pitch = PITCH
	u.xmin = _xmin()
	u.xmax = _xmax()
	u.my_goal_x = PITCH.position.x if side == "player" else PITCH.position.x + PITCH.size.x
	u.opp_goal_x = PITCH.position.x + PITCH.size.x if side == "player" else PITCH.position.x
	u.home = _pixel(nx, ny)
	u.position = u.home
	unit_root.add_child(u)
	if side == "ai":
		u.speed_base *= ai_speed_factor   # 按难度调 AI 球员速度
	return u


func _create_ball() -> void:
	ball = Ball.new()
	ball.pitch = PITCH
	ball.position = PITCH.position + Vector2(PITCH.size.x * 0.5, PITCH.size.y * 0.5)
	add_child(ball)          # 在 unit_root 之后加入 → 渲染在最上，不闪烁


func _respawn_ball(pos: Vector2, owner: String) -> void:
	# 球出界/进球后销毁旧球，在指定点新建一个，彻底重置不留旧节点
	if ball != null and is_instance_valid(ball):
		ball.queue_free()
	_create_ball()
	ball.position = pos
	ball.pos_owner = owner
	ball.last_touch = owner
	ball.pinned_carrier = null
	ball.chase_target = null
	ball.near_forward = null
	ball.state = Ball.B.DRIBBLE
	pass_receiver = null
	pass_timer = 0.0
	possession_timer = 0.0


func _pixel(nx: float, ny: float) -> Vector2:
	return PITCH.position + Vector2(nx * PITCH.size.x, ny * PITCH.size.y)


func _norm_x(px: float) -> float:
	return (px - PITCH.position.x) / PITCH.size.x


func _xmin() -> float:
	return PITCH.position.x + MOVE_MARGIN


func _xmax() -> float:
	return PITCH.position.x + PITCH.size.x - MOVE_MARGIN


func _units_of(side: String, role: String) -> Array:
	var out: Array = []
	for u in units:
		if u.side == side and u.role == role:
			out.append(u)
	return out


func _reset_to_formation() -> void:
	var form := {"player": PLAYER_FORM, "ai": AI_FORM}
	var counts := {"player": {}, "ai": {}}
	for u in units:
		var flist: Array = form[u.side]
		var role_idx: int = counts[u.side].get(u.role, 0)
		counts[u.side][u.role] = role_idx + 1
		var idx := 0
		for t in flist:
			if t.role != u.role:
				continue
			if idx == role_idx:
				u.position = _pixel(t.nx, t.ny)
				u.clear_order()
				break
			idx += 1


# ============================================================
# 每帧上下文刷新 → 球员FSM / 球FSM
# ============================================================
func _refresh_unit_context() -> void:
	var pcar: PlayerUnit = _carrier("player")
	var acar: PlayerUnit = _carrier("ai")
	var pay: float = _avg_attacker_y("player")
	var aay: float = _avg_attacker_y("ai")
	var pnf: PlayerUnit = _nearest_fwd(ball.position)
	for u in units:
		u.ball_pos = ball.position
		u.ball_owner = ball.pos_owner
		u.carrier_node = pcar if u.side == "player" else acar
		u.ctx_opp_fwd_y = aay if u.side == "player" else pay
		u.nearest_fwd = (u == pnf)
		# 后卫盯防：每帧指向距自己最近的对方前锋（盯人不盯球点，防漏人）
		if u.role == "后卫":
			u.mark_pos = _nearest_opp_fwd(u)


func _nearest_opp_fwd(u: PlayerUnit) -> Vector2:
	var oside := "ai" if u.side == "player" else "player"
	var best: PlayerUnit = null
	var bd := 1e9
	for v in units:
		if v.side == oside and v.role == "前锋":
			var d: float = v.position.distance_to(u.position)
			if d < bd:
				bd = d
				best = v
	if best == null:
		return Vector2.ZERO
	return best.position


func _carrier(side: String) -> PlayerUnit:
	var best: PlayerUnit = null
	var bd := 1e9
	for u in units:
		if u.side == side and u.role == "前锋":
			var d: float = u.position.distance_to(ball.position)
			if d < bd:
				bd = d
				best = u
	return best


func _nearest_fwd(pos: Vector2) -> PlayerUnit:
	var best: PlayerUnit = null
	var bd := 1e9
	for u in units:
		if u.role == "前锋":
			var d: float = u.position.distance_to(pos)
			if d < bd:
				bd = d
				best = u
	return best


func _forward_within(pos: Vector2, r: float) -> PlayerUnit:
	# 传球锁定接球者优先吸附（传球可能给中场/后卫，不只前锋能接），
	# 否则找最近前锋接自由球
	if pass_receiver != null and is_instance_valid(pass_receiver) \
			and pass_receiver.position.distance_to(pos) <= r:
		return pass_receiver
	var best: PlayerUnit = null
	var bd := r
	for u in units:
		if u.role != "前锋":
			continue
		var d: float = u.position.distance_to(pos)
		if d <= bd:
			bd = d
			best = u
	return best


func _avg_attacker_y(side: String) -> float:
	var ys: Array = []
	for u in units:
		if u.side == side and u.role == "前锋":
			ys.append(u.position.y)
	if ys.is_empty():
		return PITCH.position.y + PITCH.size.y * 0.5
	var s := 0.0
	for y in ys:
		s += y
	return s / ys.size()


# ============================================================
# 飘字提示：在屏幕某点弹出一行文字，上浮淡出后自动消失
# ============================================================
func _float_text(txt: String, world_pos: Vector2, color: Color) -> void:
	var lab := Label.new()
	lab.text = txt
	lab.add_theme_font_size_override("font_size", 30)
	lab.add_theme_color_override("font_color", color)
	lab.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	lab.add_theme_constant_override("outline_size", 6)
	lab.z_index = 100
	lab.position = world_pos - Vector2(txt.length() * 8.0, 0)
	add_child(lab)
	var tw := create_tween()
	tw.tween_property(lab, "position:y", lab.position.y - 70.0, 0.9).set_trans(Tween.TRANS_QUAD)
	tw.parallel().tween_property(lab, "modulate:a", 1.0, 0.12)
	tw.tween_property(lab, "modulate:a", 0.0, 0.5).set_delay(0.5)
	tw.tween_callback(lab.queue_free)


# ============================================================
# 球FSM推进（场景设置上下文 → 球自己跑）
# ============================================================
func _update_ball_fsm(delta: float) -> void:
	if ball.state == Ball.B.DRIBBLE:
		# 带球：球已由 FREE 吸附时绑定到具体 carrier_node(可能中场/后卫)。
		# 仅当该单位失效时才用 _carrier(side) 保底，不要覆盖，否则球会闪现到队内离球最近的前锋脚下。
		if ball.carrier_node == null or not is_instance_valid(ball.carrier_node):
			ball.carrier_node = ball.pinned_carrier if ball.pinned_carrier != null else _carrier(ball.pos_owner)
	else:
		ball.carrier_node = null
	if ball.state == Ball.B.FREE:
		ball.near_forward = _forward_within(ball.position, ball.attach_radius)
	else:
		ball.near_forward = null
	# 接球者只跑向固定落点(_do_pass 已 order SEEK 到落点)，不每帧追球实时位置，
	# 避免角色被滚动的球持续重定向、来回拉扯。球凭惯性滚到落点停下，球停后球员自然追球吸附。
	ball.update_ball(delta)
	if ball.flight_done:
		_on_ball_arrived()
		return
	# 自由球被球员追到吸附 → 接球完成，清理追球订单与接球者引用
	if ball.state == Ball.B.DRIBBLE and ball.pos_owner != "" and ball.pos_owner != "free":
		if pass_receiver != null:
			pass_receiver.clear_order()
			pass_receiver = null
	# 带球推进的传球/转换节奏
	if ball.state == Ball.B.DRIBBLE and ball.carrier_node != null:
		pass_timer += delta
		if pass_timer >= PASS_INTERVAL:
			pass_timer = 0.0
			_do_pass(ball.pos_owner)
		possession_timer += delta
		if possession_timer >= POSSESSION_SWITCH:
			possession_timer = 0.0
			_do_possession_switch()


func _on_ball_arrived() -> void:
	if ball.flight_kind == "pass":
		if pending_offside:
			ball.pos_owner = "ai" if ball.pos_owner == "player" else "player"
			ball.last_touch = ball.pos_owner
			ball.pinned_carrier = null
			ball.chase_target = null
			ball.state = Ball.B.FREE
			pass_timer = 0.0
			possession_timer = 0.0
			print("[越位] 传球方越位，球权交 %s" % ball.pos_owner)
		else:
			# 传球到点：球凭惯性停在落点附近进入自由状态；球停后让锁定接球者
			# 一次性追到球停点吸附带球(固定订单，不每帧追踪，避免被球来回拉扯)
			ball.pos_owner = "free"
			ball.pinned_carrier = null
			ball.chase_target = null
			ball.state = Ball.B.FREE
			pass_timer = 0.0
			if pass_receiver != null:
				pass_receiver.order(PlayerUnit.S.SEEK, ball.position)
	elif ball.flight_kind == "shot":
		_resolve_shot_arrival()


func _pass_aim(target: PlayerUnit, side: String) -> Vector2:
	var sg := 1.0 if side == "player" else -1.0
	if randf() < 0.08:
		# 传大/失误：朝进攻方向远端送，可能出边线或底线 → 触发界外球/角球/门球
		pass_wild = true
		return Vector2(target.position.x + sg * randf_range(90.0, 220.0),
			target.position.y + randf_range(-150.0, 150.0))
	pass_wild = false
	return target.position + Vector2(randf_range(-25.0, 25.0), randf_range(-45.0, 45.0))


func _do_pass(side: String) -> void:
	var c := _carrier(side)
	if c == null:
		pass_timer = PASS_INTERVAL * 0.5
		return
	# 智能选点：优先传给 空位大 / 朝进攻方向 / 距离适中 / 不越位 的队友
	var target: PlayerUnit = _pick_best_receiver(side, false)
	if target == null:
		pass_timer = PASS_INTERVAL * 0.5
		return
	ball.pinned_carrier = null
	ball.last_touch = side
	pass_receiver = target
	pending_offside = _check_offside(side, target)
	var aim := _pass_aim(target, side)
	# 球固定飞向落点（不追踪、不瞬移）；接球者被命令跑向落点，追到球附近才吸附
	ball.chase_target = null
	ball.start_pass(aim, PASS_DUR)
	target.order(PlayerUnit.S.SEEK, aim)
	print("[传球] %s 传球 → %s" % [side, target.role])


# 选择最佳接球点：遍历同队可接球球员，用 _pass_target_score 打分取最高
func _pick_best_receiver(side: String, only_forwards: bool) -> PlayerUnit:
	var c := _carrier(side)
	var best: PlayerUnit = null
	var best_score := -INF
	for u in units:
		if u.side != side or u.role == "守门员" or u == c:
			continue
		if only_forwards and u.role != "前锋":
			continue
		var s := _pass_target_score(side, c, u)
		if s > best_score:
			best_score = s
			best = u
	return best


# 给某个接球候选打分：空位大/朝前/距离适中 加分，越位 重罚
func _pass_target_score(side: String, c: PlayerUnit, t: PlayerUnit) -> float:
	var score := 0.0
	# 越位目标直接放弃（重罚）
	if _check_offside(side, t):
		return -100.0
	# 空位：目标距最近对方球员越远越好（有接球空间，不易被断）
	var opp := "ai" if side == "player" else "player"
	var bd := 1e9
	for u in units:
		if u.side == opp:
			bd = minf(bd, u.position.distance_to(t.position))
	if bd < 1e8:
		score += clampf((bd - 20.0) / 120.0, -0.5, 1.0)
	# 朝前推进：目标越靠进攻方向越有价值
	var sg := 1.0 if side == "player" else -1.0
	score += clampf((t.position.x - c.position.x) * sg / 300.0, -0.5, 0.8)
	# 距离适中：太近没有推进意义，太远容易传丢
	var dist := c.position.distance_to(t.position)
	if dist < 60.0:
		score -= 0.3
	elif dist > 400.0:
		score -= 0.4
	else:
		score += 0.2
	return score


func _do_possession_switch() -> void:
	var other := "ai" if ball.pos_owner == "player" else "player"
	# 长传转移：给对方最好的前锋接球点（同样按空位/越位评分）
	var target: PlayerUnit = _pick_best_receiver(other, true)
	if target == null:
		return
	ball.pinned_carrier = null
	ball.last_touch = other
	pass_receiver = target
	pending_offside = _check_offside(other, target)
	var aim := _pass_aim(target, other)
	ball.chase_target = null
	ball.start_pass(aim, LONG_PASS_DUR)
	target.order(PlayerUnit.S.SEEK, aim)
	print("[转换] 持球权 → %s（长传转移）" % other)


# ============================================================
# 真实足球规则限制：越位 / 犯规 / 出界
# ============================================================
func _check_offside(side: String, recv: PlayerUnit) -> bool:
	var mid := PITCH.position.x + PITCH.size.x * 0.5
	if side == "player":
		if recv.position.x <= mid:
			return false
		var cnt := 0
		for u in units:
			if u.side == "ai" and u.role != "守门员" and u.position.x > recv.position.x:
				cnt += 1
		return cnt < 2 and recv.position.x > ball.position.x
	else:
		if recv.position.x >= mid:
			return false
		var cnt := 0
		for u in units:
			if u.side == "player" and u.role != "守门员" and u.position.x < recv.position.x:
				cnt += 1
		return cnt < 2 and recv.position.x < ball.position.x


func _check_foul(delta: float) -> void:
	if ball.state != Ball.B.DRIBBLE:
		return
	var c := ball.carrier_node
	if c == null:
		return
	var foul_side := ""
	for u in units:
		if u.side == ball.pos_owner or u.role == "守门员":
			continue
		var d: float = u.position.distance_to(c.position)
		if d < 26.0 and randf() < delta * 0.12:
			foul_side = u.side
			break
	if foul_side == "":
		return
	ball.state = Ball.B.FREE
	ball.last_touch = ball.pos_owner
	ball.pinned_carrier = null
	ball.chase_target = null
	pass_timer = 0.0
	possession_timer = 0.0
	print("[犯规] %s 铲倒带球者，%s 获得任意球" % [foul_side, ball.pos_owner])


func _handle_out_of_bounds() -> void:
	if ball.state == Ball.B.SHOT:
		return  # 射门飞行到门线由到达判定处理(进球/球门球)，不按出界判
	var p := PITCH.position
	var s := PITCH.size
	const TOL := 6.0
	if ball.position.x < p.x - TOL:
		_endline_out("left")
	elif ball.position.x > p.x + s.x + TOL:
		_endline_out("right")
	elif ball.position.y < p.y - TOL:
		_throw_in(true)
	elif ball.position.y > p.y + s.y + TOL:
		_throw_in(false)


func _endline_out(which: String) -> void:
	if which == "left":
		if ball.last_touch == "ai":
			_award_kick("player", _goal_kick_pos("player"), "球门球(门将开球)", "守门员")
		else:
			_award_kick("ai", _corner_pos("left", ball.position.y), "角球(AI)", "前锋")
	else:
		if ball.last_touch == "player":
			_award_kick("ai", _goal_kick_pos("ai"), "球门球(AI门将开球)", "守门员")
		else:
			_award_kick("player", _corner_pos("right", ball.position.y), "角球(玩家)", "前锋")


func _throw_in(top: bool) -> void:
	var other := "ai" if ball.last_touch == "player" else "player"
	var y := PITCH.position.y + 6.0 if top else PITCH.position.y + PITCH.size.y - 6.0
	_award_kick(other, Vector2(clampf(ball.position.x, _xmin(), _xmax()), y), "边线球(掷界外球)", "前锋")


func _goal_kick_pos(side: String) -> Vector2:
	var gx := PITCH.position.x if side == "player" else PITCH.position.x + PITCH.size.x
	var dx := 40.0 if side == "player" else -40.0
	return Vector2(gx + dx, PITCH.position.y + PITCH.size.y * 0.5)


func _corner_pos(which: String, y: float) -> Vector2:
	# 四个角：按端线(左/右) + 球出界处靠上/下
	var x := PITCH.position.x + 24.0 if which == "left" else PITCH.position.x + PITCH.size.x - 24.0
	var yy := PITCH.position.y + 24.0 \
		if y < PITCH.position.y + PITCH.size.y * 0.5 \
		else PITCH.position.y + PITCH.size.y - 24.0
	return Vector2(x, yy)


func _award_kick(side: String, pos: Vector2, label: String, role_hint: String = "前锋") -> void:
	# 把最近合适球员放到球旁，让定位球真正由人执行
	var best: PlayerUnit = null
	var bd := INF
	for u in units:
		if u.side != side:
			continue
		if role_hint == "守门员":
			if u.role != "守门员":
				continue
		elif u.role == "守门员":
			continue
		var d: float = u.position.distance_to(pos)
		if d < bd:
			bd = d
			best = u
	if best != null:
		best.position = pos
		best.clear_order()
	# 出界/定位球：销毁旧球并在指定点新建，由 best 执行开球
	_respawn_ball(pos, side)
	if best != null:
		ball.pinned_carrier = best
	_float_text(label, pos, Color(1.0, 0.72, 0.25, 1.0))   # 出界/角球/边线球/球门球 飘字
	print("[%s] %s" % [label, side])


# ============================================================
# 单位间最小间距推挤
# ============================================================
func _separate_units() -> void:
	const MIN_SEP := UNIT_SIZE + 3.0
	for i in range(units.size()):
		for j in range(i + 1, units.size()):
			var a: PlayerUnit = units[i]
			var b: PlayerUnit = units[j]
			var d: Vector2 = a.position - b.position
			var dist := d.length()
			if dist < MIN_SEP and dist > 0.001:
				var push := (MIN_SEP - dist) * 0.5
				var nd := d / dist
				a.position += nd * push
				b.position -= nd * push
				a.position.x = clampf(a.position.x, _xmin(), _xmax())
				b.position.x = clampf(b.position.x, _xmin(), _xmax())
				a.position.y = clampf(a.position.y, PITCH.position.y + 8.0, PITCH.position.y + PITCH.size.y - 8.0)
				b.position.y = clampf(b.position.y, PITCH.position.y + 8.0, PITCH.position.y + PITCH.size.y - 8.0)


# ============================================================
# 卡牌订单（每张卡专属跑位，方向按 side 取反）
# ============================================================
func _st_y_frac(mode: String, i: int, n: int) -> float:
	match mode:
		"fan":
			var arr := [0.15, 0.5, 0.85]
			return arr[mini(i, n - 1)]
		"wedge":
			var arr := [0.30, 0.5, 0.70]
			return arr[mini(i, n - 1)]
		"wide":
			var arr := [0.12, 0.5, 0.88]
			return arr[mini(i, n - 1)]
		"tight":
			var arr := [0.38, 0.5, 0.62]
			return arr[mini(i, n - 1)]
		"swap_lanes":
			var arr := [0.82, 0.5, 0.18]
			return arr[mini(i, n - 1)]
		_:
			return -1.0


func _apply_strikers(side: String, st: float, drop: int, st_y: String) -> void:
	var sg := 1.0 if side == "player" else -1.0
	var strikers := _units_of(side, "前锋")
	var n := strikers.size()
	for i in range(n):
		var u: PlayerUnit = strikers[i]
		if i < drop:
			u.order(PlayerUnit.S.RETREAT, Vector2(clampf(u.position.x - 80.0 * sg, _xmin(), _xmax()), u.position.y))
		else:
			var tx := clampf(u.position.x + st * sg, _xmin(), _xmax())
			var ty := u.position.y
			var yf := _st_y_frac(st_y, i, n)
			if yf >= 0.0:
				ty = PITCH.position.y + PITCH.size.y * yf
			u.order(PlayerUnit.S.ADVANCE, Vector2(tx, ty))


func _apply_defenders(side: String, df: float) -> void:
	var sg := 1.0 if side == "player" else -1.0
	for u in _units_of(side, "后卫"):
		u.order(PlayerUnit.S.RETREAT if df * sg < 0 else PlayerUnit.S.ADVANCE,
			Vector2(clampf(u.position.x + df * sg, _xmin(), _xmax()), u.position.y))


func _apply_tactic(side: String, card) -> void:
	var spec: Dictionary = TACTICS.get(card.card_id, {})
	if spec.is_empty():
		if card.card_type == TYPE_DEFENSE:
			_apply_strikers(side, -70.0, 0, "tight")
			_apply_defenders(side, -90.0)
		else:
			_apply_strikers(side, 100.0, 0, "fan")
			_apply_defenders(side, 40.0)
		return
	var sd: Dictionary = player if side == "player" else ai
	var st: float = spec.get("st", 100.0)
	var drop: int = spec.get("drop", 0)
	var st_y: String = spec.get("st_y", "keep")
	var df: float = spec.get("df", 40.0)
	var df_gain: float = spec.get("df_gain", 0.0)
	if df_gain != 0.0:
		sd.defense = clampf(sd.defense + df_gain, 0.05, 0.90)
	_apply_strikers(side, st, drop, st_y)
	_apply_defenders(side, df)


# ============================================================
# 牌库 / 回合状态机
# ============================================================
func _init_decks() -> void:
	if DataLoader.cards.is_empty():
		return
	# 牌库只存卡牌 ID 字符串，抽到手里时才实例化节点（避免弃牌堆出现已释放节点）
	var pool: Array = DataLoader.cards.keys()
	pool.shuffle()
	for i in 20:
		player.deck.append(pool[i])
	player.deck.shuffle()
	pool.shuffle()
	for i in 20:
		ai.deck.append(pool[i])
	ai.deck.shuffle()
	print("牌库初始化完成：玩家%d张，AI%d张" % [player.deck.size(), ai.deck.size()])


func change_state(s: State) -> void:
	match state:
		State.ROUND_ACTIVE:
			_on_round_active_exit()
	state = s
	match state:
		State.ROUND_ACTIVE:
			_on_round_active_enter()
		State.GAME_OVER:
			print("===== 比赛结束 =====")


func _process(delta: float) -> void:
	match state:
		State.ROUND_ACTIVE:
			_on_round_active_process(delta)
			_refresh_unit_context()
			for u in units:
				u.update_unit(delta)
			_separate_units()
			_update_ball_fsm(delta)
			_check_foul(delta)
			_handle_out_of_bounds()


func _on_round_active_enter() -> void:
	match_time_left = match_duration
	draw_chance_timer = 0.0
	tp_regen_timer = 0.0
	buff_tick_timer = 0.0
	for side in [player, ai]:
		side.tp = MAX_TP
		side.draw_cd = 0.0
		side.play_cd = 0.0
		side.shoot_cd = 0.0
		side.ended_round = false
	player.draw_chance = BASE_DRAW_CHANCE
	ai.draw_chance = BASE_DRAW_CHANCE
	btn_draw.disabled = false
	for i in START_CARDS:
		_draw_card("player")
		_draw_card("ai")
	_refresh_hud()


func _on_round_active_process(delta: float) -> void:
	match_time_left = maxf(0.0, match_time_left - delta)
	for side in [player, ai]:
		side.draw_cd = maxf(0, side.draw_cd - delta)
		side.play_cd = maxf(0, side.play_cd - delta)
		side.shoot_cd = maxf(0, side.shoot_cd - delta)
	draw_chance_timer += delta
	if draw_chance_timer >= DRAW_CHANCE_RECOVER_CD:
		draw_chance_timer = 0.0
		player.draw_chance += 1
		ai.draw_chance += 1
	# 战术点随时间恢复（不再靠回合重置）
	tp_regen_timer += delta
	if tp_regen_timer >= TP_REGEN_CD:
		tp_regen_timer = 0.0
		player.tp = mini(MAX_TP, player.tp + 1)
		ai.tp = mini(MAX_TP, ai.tp + 1)
	# Buff 按时间扣时长
	buff_tick_timer += delta
	if buff_tick_timer >= BUFF_TICK_CD:
		buff_tick_timer = 0.0
		buff_system.tick_round_end_all()
	_ai_think(delta)
	_refresh_playable()
	_refresh_hud()
	btn_shoot.disabled = player.shoot_cd > 0 or ball.state != Ball.B.DRIBBLE or ball.pos_owner != "player"
	if match_time_left <= 0.0:
		_end_match_by_time()


func _on_round_active_exit() -> void:
	for card in player.hand:
		card.queue_free()
	player.hand.clear()
	for card in ai.hand:
		card.queue_free()
	ai.hand.clear()


func _end_match_by_time() -> void:
	var w := "player"
	if ai.goals > player.goals:
		w = "ai"
	elif ai.goals == player.goals:
		w = "draw"
	_end_match(w)


# ============================================================
# AI：出牌 + 自动射门
# ============================================================
func _ai_think(delta: float) -> void:
	if ai.ended_round:
		return
	if ai.shoot_cd <= 0:
		ai_shoot_timer += delta
		if ai_shoot_timer >= ai_shoot_interval:
			ai_shoot_timer = 0.0
			# AI 也需持球才射门（球在己方球员脚下），避免无球乱射
			if ball.state == Ball.B.DRIBBLE and ball.pos_owner == "ai":
				_resolve_shot("ai")
				ai.shoot_cd = ai_shoot_interval
	if ai.play_cd > 0:
		return
	ai_think_timer += delta
	if ai_think_timer < 1.0:
		return
	ai_think_timer = 0.0
	if ai.draw_cd <= 0 and ai.draw_chance > 0 and ai.hand.size() < MAX_HAND_SIZE:
		_draw_card("ai")
		ai.draw_chance -= 1
		ai.draw_cd = DRAW_OPERATE_CD
	var playable: Array = []
	for card in ai.hand:
		if card.cost <= ai.tp:
			playable.append(card)
	if playable.is_empty():
		ai.ended_round = true
		return
	# 智能出牌：对每张可出牌按当前局势打分，选分数最高的（不再纯随机）
	var target = _pick_best_card(playable)
	ai.tp -= target.cost
	ai.hand.erase(target)
	ai.discard.append(target.card_id)
	target.queue_free()
	ai.play_cd = PLAY_CARD_CD
	print("[AI] 出牌 %s（%s），球员按方案跑位" % [target.card_name, _tactic_name(target.card_id)])
	_apply_card_effect("ai", target)
	_refresh_hud()


# ============================================================
# 智能出牌评分：根据比分/时间/球权/卡牌性价比给每张牌打分，AI 选最高分
# ============================================================
func _pick_best_card(cards: Array) -> Node:
	var best: Node = cards[0]
	var best_score := -INF
	for c in cards:
		var s := _ai_score_card(c)
		if s > best_score:
			best_score = s
			best = c
	return best


func _ai_score_card(card) -> float:
	var score := 1.0
	var tp: Dictionary = TACTICS.get(card.card_id, {})
	var st := float(tp.get("st", 0.0))   # 进攻前压值（越大越偏攻击）
	var df := float(tp.get("df", 0.0))   # 防守回收值（越负越偏防守）
	var is_attack: bool = card.card_type == "进攻" or st > 60.0
	var is_defense: bool = card.card_type == "防守" or df < -20.0

	# 1) 比分心态：落后强攻、领先控场
	if ai.goals < player.goals:
		if is_attack:
			score *= 1.6
		elif is_defense:
			score *= 0.7
	elif ai.goals > player.goals:
		if is_defense:
			score *= 1.4
		elif is_attack:
			score *= 0.8

	# 2) 持球权：己方持球多出进攻组织，对方持球多出防守/逼抢
	if ball.state == Ball.B.DRIBBLE and ball.pos_owner == "ai":
		if is_attack:
			score *= 1.3
	else:
		if is_defense:
			score *= 1.3

	# 3) 末段落后搏命：剩余时间少且落后时拼进攻
	if match_time_left < 20.0 and ai.goals < player.goals:
		if is_attack:
			score *= 1.8

	# 4) 性价比：效果量/费用，高性价比优先
	score *= _effect_value(card) / maxf(float(card.cost), 0.5)
	return score * ai_score_factor   # 难度：简单更保守/困难更激进


# 估算一张卡的效果量（射门加成 + 战术跑位强度 + 附加效果）
func _effect_value(card) -> float:
	var p: Dictionary = card.effect_params
	var val := 0.0
	val += float(p.get("shot_bonus", 0))
	val += float(p.get("next_attack_bonus", 0))
	val += float(p.get("shot_effect_bonus", 0))
	val += float(p.get("next_shot_bonus", 0))
	if p.has("buff"):
		val += 3.0
	if p.has("fatigue_add"):
		val += 1.0
	var tp: Dictionary = TACTICS.get(card.card_id, {})
	val += absf(float(tp.get("st", 0.0))) * 0.01
	val += absf(float(tp.get("df", 0.0))) * 0.01
	return maxf(val, 1.0)


func _tactic_name(card_id: String) -> String:
	var spec: Dictionary = TACTICS.get(card_id, {})
	return str(spec.get("name", "通用跑位"))


# ============================================================
# 玩家交互
# ============================================================
func _on_draw_card_pressed() -> void:
	var bp: Vector2 = btn_draw.global_position + Vector2(0, 50)
	if player.ended_round:
		_float_text("回合已结束", bp, Color(0.9, 0.9, 0.9, 1.0))
		return
	if player.hand.size() >= MAX_HAND_SIZE:
		_float_text("手牌已满", bp, Color(0.9, 0.9, 0.9, 1.0))
		return
	if player.draw_cd > 0:
		_float_text("摸牌冷却中 %.0fs" % player.draw_cd, bp, Color(0.9, 0.75, 0.3, 1.0))
		return
	if player.draw_chance <= 0:
		_float_text("摸牌次数用完", bp, Color(0.9, 0.75, 0.3, 1.0))
		return
	_draw_card("player")
	player.draw_chance -= 1
	player.draw_cd = DRAW_OPERATE_CD
	_refresh_hud()


func _on_shoot_pressed() -> void:
	if player.ended_round or player.shoot_cd > 0:
		return
	# 射门需本方持球：球必须正在己方某球员脚下带球，否则无效
	if ball.state != Ball.B.DRIBBLE or ball.pos_owner != "player":
		print("[射门] 未持球，无法射门（需球在己方球员脚下）")
		return
	player.shoot_cd = SHOOT_CD
	_resolve_shot("player")


func _on_card_played(card) -> void:
	if player.ended_round:
		return
	if card.cost > player.tp:
		print("[拦截] 战术点不足，需要%d" % card.cost)
		_float_text("战术点不足(需%d)" % card.cost, card.global_position + Vector2(0, -30), Color(0.95, 0.4, 0.35, 1.0))
		player.hand.erase(card)
		player.discard.append(card.card_id)
		card.queue_free()
		_layout_hand()
		return
	player.tp -= card.cost
	player.hand.erase(card)
	card.played.disconnect(_on_card_played)
	player.discard.append(card.card_id)
	card.queue_free()
	player.play_cd = PLAY_CARD_CD
	print("[玩家] 出牌 %s（%s），球员按方案跑位" % [card.card_name, _tactic_name(card.card_id)])
	_apply_card_effect("player", card)
	_layout_hand()
	_refresh_hud()


# 卡牌拖拽被拦截时的飘字提示(冷却/点数不足/回合结束)
func _on_card_block_tried(card) -> void:
	var cp: Vector2 = card.global_position + Vector2(0, -30)
	var msg := ""
	if player.play_cd > 0:
		msg = "出牌冷却中 %.0fs" % player.play_cd
		_float_text(msg, cp, Color(0.9, 0.75, 0.3, 1.0))
	elif player.ended_round:
		msg = "回合已结束"
		_float_text(msg, cp, Color(0.9, 0.9, 0.9, 1.0))
	elif card.cost > player.tp:
		msg = "战术点不足(需%d)" % card.cost
		_float_text(msg, cp, Color(0.95, 0.4, 0.35, 1.0))


# ============================================================
# 卡牌效果 → 专属跑位订单 + Buff + 射门加成
# ============================================================
func _apply_card_effect(side: String, card) -> void:
	var p: Dictionary = card.effect_params
	var sd: Dictionary = player if side == "player" else ai

	_apply_tactic(side, card)

	if p.has("buff"):
		var dur := int(p.get("duration", "0"))
		var tmpl := DataLoader.get_buff_by_name(str(p["buff"]))
		if not tmpl.is_empty():
			if dur > 0:
				buff_system.add_buff(side, tmpl.buff_id, 1, dur)
			else:
				buff_system.add_buff(side, tmpl.buff_id, 1)
			print("[Buff] %s 获得 %s" % [side, tmpl.buff_name])
	if p.has("fatigue_add"):
		buff_system.add_buff(side, "BD001", int(p["fatigue_add"]))

	if card.card_type == TYPE_ATTACK or card.card_type == TYPE_MID:
		if p.has("shot_bonus"):
			sd.shot_bonus += float(p["shot_bonus"])
		if p.has("next_attack_bonus"):
			sd.shot_bonus += float(p["next_attack_bonus"])
		if p.has("shot_effect_bonus"):
			sd.shot_bonus += float(p["shot_effect_bonus"])
		if p.has("next_shot_bonus"):
			sd.shot_bonus += float(p["next_shot_bonus"])
	_refresh_hud()


# ============================================================
# 射门：起脚(真实飞行) → 到达后判定
# ============================================================
func _resolve_shot(side: String) -> void:
	var sd: Dictionary = player if side == "player" else ai
	var opp: String = "ai" if side == "player" else "player"
	var oppd: Dictionary = player if opp == "player" else ai

	var carrier := _carrier(side)
	var attack: float = _attack_power(side)
	var success: float = SHOT_BASE \
		+ attack * SHOT_ATTACK_WEIGHT \
		+ float(sd.shot_bonus) \
		- float(oppd.defense) * SHOT_DEFENSE_WEIGHT \
		- GK_SAVE \
		- buff_system.get_effect_sum(opp, "enemy_goal_reduce")
	# 位置因子：射手距门越近/越正对门，成功率越高；被对方防守贴得越近越低
	if carrier != null:
		success += _position_shot_bonus(side, carrier)
	if side == "ai":
		success += ai_shot_bonus   # 难度：简单 AI 更易射偏/困难更准
	success = clampf(success, 0.05, 0.95)
	sd.shot_bonus = 0.0

	var scored: bool = randf() < success
	# 射门终点：始终朝对方球门方向飞。落点与判定一致——
	# 进球时落在门框内，偏出/被扑时偏出门框上/下沿，视觉与结果匹配
	var gx := PITCH.position.x + PITCH.size.x if side == "player" else PITCH.position.x
	var cy := PITCH.position.y + PITCH.size.y * 0.5
	var gate_h := 110.0   # 与 _draw_goal 的门高一致
	var gy: float
	if scored:
		gy = cy + randf_range(-gate_h * 0.35, gate_h * 0.35)   # 门框内 → 命中球门
	else:
		var outside := gate_h * 0.5 + randf_range(15.0, 45.0)  # 偏出门框上/下沿
		gy = cy + outside * (1.0 if randf() < 0.5 else -1.0)
	gy = clampf(gy, PITCH.position.y + 20.0, PITCH.position.y + PITCH.size.y - 20.0)
	pending_shot = {"side": side, "scored": scored, "success": success}
	ball.last_touch = side
	ball.start_shot(Vector2(gx, gy), SHOT_DUR)
	print("[射门] %s 起脚，成功率%.0f%%" % [side, success * 100.0])


# 射手位置对成功率的加成：距离(0~+0.18)、角度(0~+0.10)、防守压迫(0~-0.15)
func _position_shot_bonus(side: String, shooter: Node) -> float:
	var cy := PITCH.position.y + PITCH.size.y * 0.5
	var gx := PITCH.position.x + PITCH.size.x if side == "player" else PITCH.position.x
	# 距门水平距离：越近越高
	var dx: float = absf(shooter.position.x - gx)
	var range_factor := clampf(1.0 - dx / (PITCH.size.x * 0.6), 0.0, 1.0)
	# 射门角度：越正对门中心越高，边路/底线角度差
	var angle := clampf(1.0 - absf(shooter.position.y - cy) / (PITCH.size.y * 0.5), 0.2, 1.0)
	# 防守压迫：距射手最近的对方非门将球员越近，成功率越低
	var opp := "ai" if side == "player" else "player"
	var bd := 1e9
	for u in units:
		if u.side == opp and u.role != "守门员":
			bd = minf(bd, u.position.distance_to(shooter.position))
	var press := 0.0
	if bd < 1e8:
		press = clampf((60.0 - bd) / 60.0, 0.0, 1.0)
	return 0.18 * range_factor + 0.10 * angle - 0.15 * press


func _resolve_shot_arrival() -> void:
	var ps: Dictionary = pending_shot
	pending_shot = {"side": "", "scored": false, "success": 0.0}
	var side: String = ps["side"]
	var sd: Dictionary = player if side == "player" else ai
	var opp: String = "ai" if side == "player" else "player"
	if ps["scored"]:
		sd.goals += 1
		print("[射门] %s 进球！成功率%.0f%% 比分 %d:%d" % [side, float(ps["success"]) * 100.0, player.goals, ai.goals])
		var gtxt := "进球！ %d : %d" % [player.goals, ai.goals]
		_float_text(gtxt, PITCH.position + Vector2(PITCH.size.x * 0.5, PITCH.size.y * 0.3), Color(1.0, 0.84, 0.2, 1.0))
		_reset_to_formation()
		# 进球：销毁旧球，在中圈新建一个由对方开球
		_respawn_ball(PITCH.position + Vector2(PITCH.size.x * 0.5, PITCH.size.y * 0.5), opp)
	else:
		# 射门越过门线未进 → 对方门将开球(球门球)
		_award_kick(opp, _goal_kick_pos(opp), "球门球(射偏门将开球)", "守门员")
		print("[射门] %s 偏出（成功率%.0f%%）" % [side, float(ps["success"]) * 100.0])
	_refresh_hud()
	# 不再"先进3球即终场"：整场打满时间，结束时按比分定胜负（见 _end_match_by_time）


func _attack_power(side: String) -> float:
	var xs: Array = []
	for u in units:
		if u.side == side and u.role == "前锋":
			xs.append(_norm_x(u.position.x))
	if xs.is_empty():
		return 0.0
	var avg := 0.0
	for x in xs:
		avg += x
	avg /= xs.size()
	var dist := (avg - 0.5) if side == "player" else (0.5 - avg)
	return clampf(dist / 0.45, 0.0, 1.0)


func _end_match(winner: String) -> void:
	change_state(State.GAME_OVER)
	DataLoader.match_winner = winner
	DataLoader.match_player_goals = player.goals
	DataLoader.match_ai_goals = ai.goals
	# 比赛结束：记入总战绩；胜利把当前结果写入该槽位存档供主界面查看，失败/平局清空槽位
	DataLoader.record_match(winner, player.goals, ai.goals)
	AudioMgr.play_music("res://audio/bgm/全局音效.mp3")   # 比赛结束换回全局音效
	if winner == "player":
		AudioMgr.play_sfx("res://audio/bgm/胜利音效.mp3")   # 胜利音效
	elif winner == "ai":
		AudioMgr.play_sfx("res://audio/bgm/失败音效.mp3")   # 失败音效
	if winner == "player":
		var snap := _build_snapshot()
		DataLoader.save_match(DataLoader.active_slot, snap)
		print("[存档] 胜利结果已存入槽位%d（比分 %d:%d）" % [DataLoader.active_slot, player.goals, ai.goals])
	else:
		DataLoader.delete_save(DataLoader.active_slot)
	if winner == "player":
		print("🏆 玩家获胜！比分 %d:%d" % [player.goals, ai.goals])
		get_tree().change_scene_to_file("res://Ui/03_win.tscn")
	elif winner == "ai":
		print("🏆 AI 获胜！比分 %d:%d" % [player.goals, ai.goals])
		get_tree().change_scene_to_file("res://Ui/04_failure.tscn")
	else:
		print("🤝 平局！比分 %d:%d" % [player.goals, ai.goals])
		get_tree().change_scene_to_file("res://Ui/03_win.tscn")


# ============================================================
# 抽卡 / 手牌 / HUD
# ============================================================
func _draw_card(side: String) -> void:
	var sd: Dictionary = player if side == "player" else ai
	if sd.deck.is_empty():
		sd.deck = sd.discard.duplicate()
		sd.discard.clear()
		sd.deck.shuffle()
		print("[%s] 牌库耗尽，洗弃牌堆" % side)
	if sd.deck.is_empty():
		return
	# 牌库/弃牌堆都是卡牌 ID；抽到手里才实例化卡牌节点
	var cid: String = sd.deck.pop_back()
	var card = CARD.instantiate()
	card.side = side
	card.set_card(DataLoader.get_card(cid))
	card_root.add_child(card)
	# 只有玩家手牌显示在场上；AI 卡必须隐藏，否则会叠在左上角
	card.visible = (side == "player")
	sd.hand.append(card)
	if side == "player":
		if not card.played.is_connected(_on_card_played):
			card.played.connect(_on_card_played)
		if not card.block_tried.is_connected(_on_card_block_tried):
			card.block_tried.connect(_on_card_block_tried)
		card.position = Vector2(DisplayServer.window_get_size().x - 100, DisplayServer.window_get_size().y - 100) - card_root.global_position
		card.modulate.a = 0.0
		var tw := create_tween()
		tw.tween_property(card, "modulate:a", 1.0, 0.2)
		_layout_hand()


func _refresh_playable() -> void:
	for card in player.hand:
		card.can_play = card.cost <= player.tp and not player.ended_round and player.play_cd <= 0


func _refresh_hud() -> void:
	ui_turn.text = "战斗中"
	ui_tp.text = "玩家战术点 %d/%d | AI %d/%d" % [player.tp, MAX_TP, ai.tp, MAX_TP]
	ui_timer.text = "剩余 %.0fs | 射门CD %.0fs" % [match_time_left, maxf(0, player.shoot_cd)]
	ui_draw.text = "手牌 %d/%d | 牌库 %d | 弃牌 %d | 摸牌 %d | 摸牌CD %.0fs | 出牌CD %.0fs" % [player.hand.size(), MAX_HAND_SIZE, player.deck.size(), player.discard.size(), player.draw_chance, maxf(0, player.draw_cd), maxf(0, player.play_cd)]
	ui_score.text = "%d  :  %d" % [player.goals, ai.goals]
	ui_p_buff.text = "玩家Buff %s" % buff_system.get_active_summary("player")
	ui_a_buff.text = "AI Buff %s" % buff_system.get_active_summary("ai")
	# 摸牌按钮不禁用：点击时在 _on_draw_card_pressed 里飘字提示冷却/次数/手牌满
	btn_draw.disabled = false
	btn_shoot.disabled = player.shoot_cd > 0 or ball.state != Ball.B.DRIBBLE or ball.pos_owner != "player"
	if ui_slot:
		ui_slot.text = "存档槽位 %d" % DataLoader.active_slot


func _layout_hand() -> void:
	var win_size = DisplayServer.window_get_size()
	var center_pos = Vector2(win_size.x * 0.5, win_size.y - 100.0)
	var hand_count = player.hand.size()
	if hand_count == 0:
		return
	var total_width = CARD_WIDTH * hand_count + CARD_GAP * (hand_count - 1)
	var start_x = center_pos.x - total_width * 0.5
	for i in hand_count:
		var card = player.hand[i]
		var target = Vector2(start_x + i * (CARD_WIDTH + CARD_GAP), center_pos.y - 100.0) - card_root.global_position
		var tw := create_tween()
		tw.tween_property(card, "position", target, 0.3)


# ============================================================
# 存档：生成比赛快照 / 从快照恢复整场 / 保存并退出
# ============================================================
func _build_snapshot() -> Dictionary:
	return {
		"v": 1,
		"saved_at": int(Time.get_unix_time_from_system()),
		"status": "finished" if DataLoader.match_winner != "" else "progress",
		"match_time_left": match_time_left,
		"draw_chance_timer": draw_chance_timer,
		"tp_regen_timer": tp_regen_timer,
		"buff_tick_timer": buff_tick_timer,
		"ai_think_timer": ai_think_timer,
		"ai_shoot_timer": ai_shoot_timer,
		"pass_timer": pass_timer,
		"possession_timer": possession_timer,
		"pending_offside": pending_offside,
		"pending_shot": {"side": pending_shot.side, "scored": pending_shot.scored, "success": pending_shot.success},
		"player": _side_snapshot(player),
		"ai": _side_snapshot(ai),
		"buffs": {
			"player": _buffs_snapshot("player"),
			"ai": _buffs_snapshot("ai"),
		},
		"units": _units_snapshot(),
		"ball": _ball_snapshot(),
		"pass_receiver": _unit_index(pass_receiver),
	}


func _side_snapshot(sd: Dictionary) -> Dictionary:
	# 牌库/弃牌堆存的是卡牌 ID 字符串；手牌存卡牌节点，需取出 ID
	return {
		"deck": sd.deck.duplicate(),
		"hand": _card_ids(sd.hand),
		"discard": sd.discard.duplicate(),
		"tp": sd.tp, "draw_chance": sd.draw_chance, "draw_cd": sd.draw_cd,
		"play_cd": sd.play_cd, "goals": sd.goals, "defense": sd.defense,
		"shot_bonus": sd.shot_bonus, "shoot_cd": sd.shoot_cd, "ended_round": sd.ended_round,
	}


func _card_ids(list: Array) -> Array:
	var out: Array = []
	for c in list:
		out.append(c.card_id)
	return out


func _buffs_snapshot(side: String) -> Array:
	var out: Array = []
	for rec in buff_system.get_buffs(side).values():
		out.append({"id": rec.id, "stacks": rec.stacks, "duration_left": rec.duration_left})
	return out


func _units_snapshot() -> Array:
	var out: Array = []
	for u in units:
		out.append({
			"side": u.side, "role": u.role, "lane_idx": u.lane_idx,
			"home": [u.home.x, u.home.y], "pos": [u.position.x, u.position.y],
			"order_state": u.order_state, "order_target": [u.order_target.x, u.order_target.y],
		})
	return out


func _unit_index(n: Node) -> int:
	if n == null:
		return -1
	for i in units.size():
		if units[i] == n:
			return i
	return -1


func _unit_by_index(i: int) -> Node:
	if i < 0 or i >= units.size():
		return null
	return units[i]


func _ball_snapshot() -> Dictionary:
	return {
		"state": int(ball.state), "pos_owner": ball.pos_owner, "last_touch": ball.last_touch,
		"pos": [ball.position.x, ball.position.y],
		"f_from": [ball.f_from.x, ball.f_from.y], "f_to": [ball.f_to.x, ball.f_to.y],
		"f_t": ball.f_t, "f_dur": ball.f_dur, "flight_kind": ball.flight_kind,
		"pinned": _unit_index(ball.pinned_carrier),
		"chase": _unit_index(ball.chase_target),
		"near": _unit_index(ball.near_forward),
	}


func _restore_from_snapshot(s: Dictionary) -> void:
	# 清掉 _ready 里初始化的默认球员与默认卡牌，避免与恢复出的实体重复叠加
	for c in card_root.get_children():
		c.queue_free()
	for u in unit_root.get_children():
		u.queue_free()
	match_time_left = float(s.get("match_time_left", match_duration))
	draw_chance_timer = float(s.get("draw_chance_timer", 0.0))
	tp_regen_timer = float(s.get("tp_regen_timer", 0.0))
	buff_tick_timer = float(s.get("buff_tick_timer", 0.0))
	ai_think_timer = float(s.get("ai_think_timer", 0.0))
	ai_shoot_timer = float(s.get("ai_shoot_timer", 0.0))
	pass_timer = float(s.get("pass_timer", 0.0))
	possession_timer = float(s.get("possession_timer", 0.0))
	pending_offside = bool(s.get("pending_offside", false))
	var ps: Dictionary = s.get("pending_shot", {})
	pending_shot = {
		"side": str(ps.get("side", "")),
		"scored": bool(ps.get("scored", false)),
		"success": float(ps.get("success", 0.0)),
	}
	_restore_side(player, s.get("player", {}), "player")
	_restore_side(ai, s.get("ai", {}), "ai")
	buff_system.restore_all(s.get("buffs", {}))
	_restore_units(s.get("units", []))
	_restore_ball(s.get("ball", {}))
	pass_receiver = _unit_by_index(int(s.get("pass_receiver", -1)))
	state = State.ROUND_ACTIVE
	_refresh_playable()
	_refresh_hud()
	_layout_hand()


func _restore_side(sd: Dictionary, data: Dictionary, side: String) -> void:
	# 牌库/弃牌堆恢复为卡牌 ID 字符串；仅手牌重建为存活节点
	sd.deck = data.get("deck", [])
	sd.hand = _rebuild_cards(data.get("hand", []), side, true)
	sd.discard = data.get("discard", [])
	sd.tp = float(data.get("tp", MAX_TP))
	sd.draw_chance = int(data.get("draw_chance", BASE_DRAW_CHANCE))
	sd.draw_cd = float(data.get("draw_cd", 0.0))
	sd.play_cd = float(data.get("play_cd", 0.0))
	sd.goals = int(data.get("goals", 0))
	sd.defense = float(data.get("defense", 0.50))
	sd.shot_bonus = float(data.get("shot_bonus", 0.0))
	sd.shoot_cd = float(data.get("shoot_cd", 0.0))
	sd.ended_round = bool(data.get("ended_round", false))


func _rebuild_cards(ids: Array, side: String, in_hand: bool) -> Array:
	var out: Array = []
	for cid in ids:
		var tmpl: Dictionary = DataLoader.get_card(str(cid))
		if tmpl.is_empty():
			continue
		var card = CARD.instantiate()
		card.side = side
		card.visible = in_hand and side == "player"
		card.set_card(tmpl)
		card_root.add_child(card)
		if in_hand and side == "player":
			if not card.played.is_connected(_on_card_played):
				card.played.connect(_on_card_played)
			if not card.block_tried.is_connected(_on_card_block_tried):
				card.block_tried.connect(_on_card_block_tried)
			card.position = Vector2(DisplayServer.window_get_size().x - 100, DisplayServer.window_get_size().y - 100) - card_root.global_position
		out.append(card)
	return out


func _restore_units(data: Array) -> void:
	units.clear()
	for d in data:
		var u := PlayerUnit.new()
		u.side = d.side
		u.role = d.role
		u.lane_idx = int(d.lane_idx)
		u.pitch = PITCH
		u.xmin = _xmin()
		u.xmax = _xmax()
		u.my_goal_x = PITCH.position.x if u.side == "player" else PITCH.position.x + PITCH.size.x
		u.opp_goal_x = PITCH.position.x + PITCH.size.x if u.side == "player" else PITCH.position.x
		u.home = Vector2(d.home[0], d.home[1])
		u.position = Vector2(d.pos[0], d.pos[1])
		u.order_state = int(d.order_state)
		u.order_target = Vector2(d.order_target[0], d.order_target[1])
		u.state = u.order_state if u.order_state != -1 else PlayerUnit.S.IDLE
		unit_root.add_child(u)
		units.append(u)


func _restore_ball(d: Dictionary) -> void:
	if d.is_empty():
		return
	ball.state = int(d.get("state", 0))
	ball.pos_owner = str(d.get("pos_owner", "free"))
	ball.last_touch = str(d.get("last_touch", "free"))
	var pos: Array = d.get("pos", [])
	if pos.size() >= 2:
		ball.position = Vector2(float(pos[0]), float(pos[1]))
	var ff: Array = d.get("f_from", [])
	var ft: Array = d.get("f_to", [])
	if ff.size() >= 2:
		ball.f_from = Vector2(float(ff[0]), float(ff[1]))
	if ft.size() >= 2:
		ball.f_to = Vector2(float(ft[0]), float(ft[1]))
	ball.f_t = float(d.get("f_t", 0.0))
	ball.f_dur = float(d.get("f_dur", 0.5))
	ball.flight_kind = str(d.get("flight_kind", ""))
	ball.pinned_carrier = _unit_by_index(int(d.get("pinned", -1)))
	ball.chase_target = _unit_by_index(int(d.get("chase", -1)))
	ball.near_forward = _unit_by_index(int(d.get("near", -1)))


## 保存当前比赛到 DataLoader.active_slot 并返回主菜单
func _on_save_exit_pressed() -> void:
	var snap := _build_snapshot()
	if DataLoader.save_match(DataLoader.active_slot, snap):
		print("[存档] 已保存到槽位%d（比分 %d:%d）" % [DataLoader.active_slot, player.goals, ai.goals])
	get_tree().change_scene_to_file("res://Ui/00_beginning.tscn")


## 结束比赛：按当前比分判断胜负（领先进胜利、落后进失败、打平平局），记战绩并清槽
func _on_end_match_pressed() -> void:
	print("[结束] 结束比赛，按比分结算 %d:%d" % [player.goals, ai.goals])
	_end_match_by_time()
