class_name Ball
extends Node2D
## ============================================================
##  足球实体：球自己拥有状态机。
##  状态：自由(等球员跑到位吸附) / 带球(贴脚) / 传球(飞行) / 射门(飞行)。
##  传球与射门是"真实球体"：以初速度朝目标踢出，飞行中受摩擦(空气阻力)
##  减速、凭惯性滑行——不再是"预设落点匀速瞬移"。球停住后由球员追到吸附。
##  场景负责设置上下文(持球者/可捡球前锋)与触发传球、射门。
## ============================================================

enum B { FREE, DRIBBLE, PASS, SHOT }

const R := 7.0
const FEET_OFFSET_X := 9.0
const FEET_OFFSET_Y := 14.0
const STOP_SPEED := 15.0      # 速度低于此值视为球停住(兜底)
const MAX_FLIGHT_TIME := 6.0  # 飞行时间上限(防止异常卡死)
const PASS_SPEED := 260.0     # 传球最大球速：球以较快速度滚向目标(全程快)
const PASS_SLOWDOWN := 90.0   # 距落点小于该距离开始平滑减速，接近落点自然停下
const PASS_FRICTION := 0.80   # 传球摩擦：叠加的轻微减速，让末端更自然
const SHOT_FRICTION := 0.97   # 射门更冲、摩擦更小，能快速打到门前
const SHOT_STOP_DIST := 8.0   # 射门球到门线附近即停(判定进门/偏出)

var state: int = B.FREE
var pos_owner := "free"       # 持球方（避开 Node2D 原生 owner 属性）
var last_touch := "free"

# 飞行（传球/射门共用）
var f_from := Vector2.ZERO
var f_to := Vector2.ZERO
var f_t := 0.0                # 已飞行实际秒数
var f_dur := 0.5              # 意图飞行时长(仅用于初速计算，非计时)
var velocity := Vector2.ZERO  # 球当前速度(惯性积分)
var flight_kind := ""         # "pass"/"shot"
var flight_done := false

# 上下文（场景每帧设置）
var carrier_node: Node = null
var pinned_carrier: Node = null   # 锁定的接球者(传球到点后传给真正目标，不就近抢)
var chase_target: Node = null     # 传球飞行时实时追踪的接球者(非null则球追着他跑)
var near_forward: Node = null
var attach_radius := 34.0   # 拾球吸附半径(约1.4倍身位)：球员追到球附近即吸附带球。
							# 设大一档避免角色有惯性时停在半径边缘漏吸(第一次拾球拾不到)

var pitch := Rect2(60, 60, 1160, 400)


func _draw() -> void:
	draw_circle(Vector2.ZERO, R, Color(1, 1, 1, 1))
	draw_arc(Vector2.ZERO, R - 0.5, 0, TAU, 24, Color(0.05, 0.05, 0.05, 0.9), 1.5)


func start_pass(to_pos: Vector2, dur: float) -> void:
	state = B.PASS
	f_from = position
	f_to = to_pos
	f_t = 0.0
	f_dur = dur
	flight_kind = "pass"
	flight_done = false
	# 固定较快球速滚向落点，接近落点时平滑减速停下(全程快、末端自然停，不硬切)
	var dirv := to_pos - position
	velocity = dirv.normalized() * PASS_SPEED if dirv.length() > 1.0 else Vector2.ZERO


func start_shot(to_pos: Vector2, dur: float) -> void:
	state = B.SHOT
	f_from = position
	f_to = to_pos
	f_t = 0.0
	f_dur = dur
	flight_kind = "shot"
	flight_done = false
	# 射门更冲：高初速快速打向门线
	var dirv := to_pos - position
	var dist := maxf(dirv.length(), 1.0)
	velocity = dirv.normalized() * (dist / maxf(dur, 0.1)) * 1.15


# 传球初速：由"目标距离 D 和摩擦"反推，使球在摩擦作用下正好滚到 D 处停下
# 注：传球初速不用"停点反推"公式(那会把球速压得太慢)，改为固定球速 + 接近落点平滑减速。

func update_ball(delta: float) -> void:
	flight_done = false
	match state:
		B.FREE:
			# 等球员真跑到脚下(近到 attach_radius)才吸附，不隔空抢球
			if near_forward != null:
				pos_owner = near_forward.side
				last_touch = pos_owner
				carrier_node = near_forward   # 记住具体被吸附的单位(可能是中场/后卫)，避免 DRIBBLE 时被重新解析成别的球员
				state = B.DRIBBLE
				queue_redraw()
		B.DRIBBLE:
			if carrier_node == null:
				state = B.FREE
				return
			var dx := FEET_OFFSET_X if pos_owner == "player" else -FEET_OFFSET_X
			var foot := Vector2(carrier_node.position.x + dx, carrier_node.position.y + FEET_OFFSET_Y)
			# 平滑贴近脚位(lerp)，消除 FREE→DRIBBLE 吸附瞬间的硬贴跳变(球"闪现")
			position = position.lerp(foot, minf(1.0, delta * 12.0))
		B.PASS:
			# 快速滚向落点；接近落点(PASS_SLOWDOWN 内)速度上限随距离平滑下降，自然停下
			f_t += delta
			var to_goal := f_to - position
			var dist := to_goal.length()
			var max_speed := PASS_SPEED * clampf(dist / PASS_SLOWDOWN, 0.0, 1.0)
			if max_speed < STOP_SPEED:
				velocity = Vector2.ZERO
				flight_done = true
			else:
				if velocity.length() > max_speed:
					velocity = velocity.normalized() * max_speed
				position += velocity * delta
				velocity *= pow(PASS_FRICTION, delta)
				if f_t > MAX_FLIGHT_TIME:
					velocity = Vector2.ZERO
					flight_done = true
		B.SHOT:
			# 射门：快速冲向门线，到门线附近即停(判定进门/偏出)
			f_t += delta
			position += velocity * delta
			velocity *= pow(SHOT_FRICTION, delta)
			if position.distance_to(f_to) < SHOT_STOP_DIST or velocity.length() < STOP_SPEED or f_t > MAX_FLIGHT_TIME:
				velocity = Vector2.ZERO
				flight_done = true
	queue_redraw()
