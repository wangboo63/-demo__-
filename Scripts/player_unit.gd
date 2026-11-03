class_name PlayerUnit
extends Node2D
## ============================================================
##  单个球员实体：每个角色拥有自己的状态机（FSM）。
##  状态：待命/前压/回撤/支援/盯防/逼抢/抢球/带球/回位。
##  每个单位根据 球权/自身角色/持球者/阵营 自行决策状态转移，
##  并在 update_unit() 里自己积分运动（非场景统一操控）。
##  场景仅负责：设置上下文(ball/carrier/对方进攻线)、下发卡牌订单(order)。
## ============================================================

enum S { IDLE, ADVANCE, RETREAT, SUPPORT, TRACK, PRESS, SEEK, DRIBBLE, RETURN }

const UNIT_SIZE := 24.0
const GK_SPEED := 120.0
const CARRIER_SPEED := 70.0
const BASE_SPEED := 95.0      # 默认速度；_ready 里按角色差异化覆盖 speed_base
const MARK_KEEP_DIST := 34.0  # 盯人时保持的安全距离（约1.4倍身位），避免贴身挤堆
const ACCEL := 260.0          # 加速度(质量感)：起步、转向、停下的过渡快慢，越高越"轻快"

# ---- 个体差异参数（角色/随机，让每个球员行为不一样）----
var speed_base := BASE_SPEED   # 实际速度：前锋快/后卫慢/门将最快
var aggression := 1.0          # 进攻倾向(0~1)：越高逼抢越凶、前压越深
var move_vel := Vector2.ZERO   # 当前速度(惯性)：每帧经加速度逼近目标速度，有质量

# ---- 身份 ----
var side := "player"
var role := "前锋"
var lane_idx := 0              # 同角色内的序号，用于站位分散
var home := Vector2.ZERO       # 初始站位(用于回位/阵型) 

# ---- FSM 当前状态 ----
var state: int = S.IDLE

# ---- 订单（来自卡牌战术），高优先，完成后回自主 ----
var order_state: int = -1
var order_target := Vector2.ZERO
var order_reach := 8.0

# ---- 上下文（场景每帧刷新） ----
var ball_pos := Vector2.ZERO
var ball_owner := "free"
var carrier_node: Node = null
var nearest_fwd := false        # 是否是距球最近的前锋
var ctx_opp_fwd_y := 200.0      # 对方前锋平均横位（守门员追踪用）
var mark_pos := Vector2.ZERO    # 盯防目标位置（后卫用，场景每帧刷成对方某前锋）
var pitch := Rect2(60, 60, 1160, 400)
var my_goal_x := 60.0
var opp_goal_x := 1220.0
var xmin := 100.0
var xmax := 1180.0

var _color := Color.RED
var _state_names := {
	S.IDLE: "待命", S.ADVANCE: "前压", S.RETREAT: "回撤",
	S.SUPPORT: "支援", S.TRACK: "盯防", S.PRESS: "逼抢",
	S.SEEK: "抢球", S.DRIBBLE: "带球", S.RETURN: "回位",
}


func _ready() -> void:
	_color = _pick_color()
	# 角色差异化速度：前锋最快、后卫最慢、门将最快（GK_SPEED）
	if role == "前锋":
		speed_base = 100.0
	elif role == "后卫":
		speed_base = 88.0
	# 每个球员随机进攻倾向，制造个体差异（0.75~1.0）
	aggression = randf_range(0.75, 1.0)
	queue_redraw()


func _pick_color() -> Color:
	if role == "守门员":
		return Color(0.95, 0.78, 0.20)
	return Color(0.95, 0.28, 0.28) if side == "player" else Color(0.30, 0.50, 0.95)


func _draw() -> void:
	draw_circle(Vector2.ZERO, UNIT_SIZE * 0.5, _color)
	draw_arc(Vector2.ZERO, UNIT_SIZE * 0.5 - 1.0, 0, TAU, 32, Color(1, 1, 1, 0.85), 2.0)
	var tag := ("我·门" if role == "守门员" else "我") if side == "player" else ("敌·门" if role == "守门员" else "敌")
	draw_string(ThemeDB.fallback_font, Vector2(-26, -18), tag, HORIZONTAL_ALIGNMENT_CENTER, 52, 12, Color(1, 1, 1, 0.95))
	var sname: String = _state_names.get(state, "")
	draw_string(ThemeDB.fallback_font, Vector2(-26, UNIT_SIZE * 0.5 + 14), sname, HORIZONTAL_ALIGNMENT_CENTER, 52, 10, Color(1, 1, 1, 0.75))


func is_carrier() -> bool:
	return carrier_node != null and carrier_node == self


# 卡牌订单：把球员推进到某状态+目标
func order(kind: int, target: Vector2) -> void:
	order_state = kind
	order_target = target
	state = kind
	queue_redraw()


func clear_order() -> void:
	order_state = -1
	state = S.IDLE


# 每帧状态机推进
func update_unit(delta: float) -> void:
	if order_state != -1:
		_process_order(delta)
	else:
		_process_fsm(delta)
	queue_redraw()


func _process_order(delta: float) -> void:
	var dirv := order_target - position
	if dirv.length() < order_reach:
		clear_order()
		return
	position += dirv.normalized() * speed_base * delta
	_clamp()


func _process_fsm(delta: float) -> void:
	# 守门员：固定门线，实时追踪对方进攻横位
	if role == "守门员":
		state = S.TRACK
		position += _step(Vector2(my_goal_x, ctx_opp_fwd_y), GK_SPEED, delta)
		_clamp()
		return

	# 球权状态机
	if ball_owner == "free":
		if role == "前锋" and nearest_fwd:
			state = S.SEEK
			position += _step(ball_pos, speed_base, delta)
		elif role == "前锋":
			# 非最近前锋：回位到自己站位，保持阵型不挤堆
			state = S.RETURN
			position += _step(_home_target(), _speed(0.7), delta)
		else:
			state = S.TRACK
			position += _step(_defender_track(), _speed(0.6), delta)
		_clamp()
		return

	if ball_owner == side:
		if is_carrier():
			state = S.DRIBBLE
			var sg := 1.0 if side == "player" else -1.0
			var shot_line := opp_goal_x - 110.0 * sg   # 射门区边界
			# 未到射门区：向前带；已到射门区：停球小幅横移找角度，不再盲目冲底线
			var tx: float
			if (side == "player" and position.x >= shot_line) or (side == "ai" and position.x <= shot_line):
				tx = position.x + (14.0 if lane_idx % 2 == 0 else -14.0) * sg
			else:
				tx = position.x + 22.0 * sg
			position += _step(Vector2(clampf(tx, xmin, xmax), _lane_y()), CARRIER_SPEED, delta)
		elif role == "前锋":
			state = S.SUPPORT
			position += _step(_support_target(), _speed(0.75), delta)
		else:
			state = S.TRACK
			position += _step(_defender_track(), _speed(0.6), delta)
		_clamp()
		return

	# 对方持球：我方攻防
	if role == "前锋":
		state = S.PRESS
		if nearest_fwd:
			# 最近前锋逼近球：aggression 越高逼抢越快越凶
			position += _step(_press_target(), _speed(0.80 + 0.20 * aggression), delta)
		else:
			# 区域逼抢：贴近球但保持自己纵位，避免全扑到一点
			var tx := clampf(ball_pos.x + (20.0 if side == "player" else -20.0), xmin, xmax)
			position += _step(Vector2(tx, _lane_y()), _speed(0.7), delta)
	else:
		state = S.TRACK
		position += _step(_defender_track(), _speed(0.7), delta)
	_clamp()


func _lane_y() -> float:
	if home.y != 0.0:
		return home.y
	return pitch.position.y + pitch.size.y * 0.5


func _home_target() -> Vector2:
	return Vector2(clampf(home.x, xmin, xmax), _lane_y())


func _support_target() -> Vector2:
	# 支援跑位：分层——1个前插抢点 / 1个中路衔接 / 1个回撤拉开，避免全队堵在对方门前
	var cp := _carrier_pos()
	var sg := 1.0 if side == "player" else -1.0
	var li := mini(lane_idx, 2)
	var sy := [-90.0, 0.0, 90.0]
	var shot_line := opp_goal_x - 110.0 * sg   # 射门区边界
	var near_goal: bool = (side == "player" and cp.x >= shot_line) or (side == "ai" and cp.x <= shot_line)
	if near_goal:
		# 带球者已在射门区：
		#  - 中路前锋(lane1)留在禁区前沿抢点，准备射门/补射，门前有人
		#  - 其余前锋退到禁区外拉开接应，作被围时的回传出球点，避免全员堵门
		if lane_idx == 1:
			return Vector2(
				clampf(cp.x + sg * 20.0, xmin, xmax),
				clampf(cp.y, pitch.position.y + 8.0, pitch.position.y + pitch.size.y - 8.0))
		return Vector2(
			clampf(cp.x - sg * 45.0, xmin, xmax),
			clampf(_lane_y() + sy[li] * 0.4, pitch.position.y + 8.0, pitch.position.y + pitch.size.y - 8.0))
	# 一般推进：lane0 边路插上 / lane1 中路衔接略后 / lane2 回撤拉开接应
	var ahead: float
	var lat: float
	match li:
		0: ahead = 70.0;  lat = 0.0
		1: ahead = 10.0;  lat = 40.0
		_: ahead = -30.0; lat = -80.0
	return Vector2(
		clampf(cp.x + sg * ahead, xmin, xmax),
		clampf(_lane_y() + lat, pitch.position.y + 8.0, pitch.position.y + pitch.size.y - 8.0))


func _defender_track() -> Vector2:
	# 有盯防目标时：逼近对方前锋，但保持安全距离(MARK_KEEP_DIST)，不贴身挤堆
	if mark_pos != Vector2.ZERO:
		var to_mark := position.direction_to(mark_pos)
		return (mark_pos - to_mark * MARK_KEEP_DIST).clamp(
			Vector2(xmin, pitch.position.y + 8.0),
			Vector2(xmax, pitch.position.y + pitch.size.y - 8.0))
	# 无盯防目标时：退化为盯球点，横向上按 lane 错开，纵向上保持自己的站位
	var xo := [-70.0, 0.0, 70.0]
	var li := mini(lane_idx, 2)
	return Vector2(clampf(ball_pos.x + xo[li], xmin, xmax), _lane_y())


func _press_target() -> Vector2:
	return Vector2(clampf(ball_pos.x, xmin, xmax), ball_pos.y)


func _carrier_pos() -> Vector2:
	if carrier_node != null:
		return carrier_node.position
	return ball_pos


func _speed(f: float) -> float:
	return speed_base * f


func _step(target: Vector2, spd: float, delta: float) -> Vector2:
	# 带质量的移动：不是瞬间满速，而是经加速度逼近目标速度。
	# 起步慢、转向平滑、接近目标时降速滑停——角色有惯性，不再被"拉着瞬移"。
	var dirv := target - position
	var dist := dirv.length()
	# 已到达(或极近)：减速滑停，停在原地附近，不瞬跳
	if dist <= 1.0:
		move_vel = move_vel.move_toward(Vector2.ZERO, ACCEL * delta)
		return move_vel * delta
	# 期望速度：接近目标最后一段逐渐降速，避免冲过头
	var desired_speed := spd
	if dist < spd * 0.4:
		desired_speed = spd * (dist / (spd * 0.4))
	var desired := dirv.normalized() * desired_speed
	move_vel = move_vel.move_toward(desired, ACCEL * delta)
	# 防止这一步越出目标：会越就停在目标上并清零速度
	var step := move_vel * delta
	if step.length() > dist:
		position = target
		move_vel = Vector2.ZERO
		return Vector2.ZERO
	return step


func _clamp() -> void:
	position.x = clampf(position.x, xmin, xmax)
	position.y = clampf(position.y, pitch.position.y + 8.0, pitch.position.y + pitch.size.y - 8.0)
