class_name BuffSystem
extends RefCounted
## ============================================================
##  Buff/Debuff 系统（Step 2）
##  - 添加 / 移除 Buff，层数上限取自 buff_config.max_stack（默认 3）
##  - 回合倒计时：tick_round_end 扣减持续时长，到期自动移除
##  - "比赛单局" 类 Buff（duration = -1）不参与倒计时，永久生效
##  - 正向 / 负面分类，可按类型批量移除
##  - 聚合效果查询：get_effect_sum 累加 Σ(值 × 层数)
##
##  用法：
##    var bs := BuffSystem.new()
##    bs.add_buff("player", "B003", 1)       # 加一层"稳固防线"
##    bs.tick_round_end("player")            # 回合结束扣减
##    bs.get_effect_sum("player", "enemy_goal_reduce")
## ============================================================

const DURATION_MATCH := -1

# 每侧活跃 Buff：side -> { buff_id : 记录字典 }
var _buffs: Dictionary = {
	"player": {},
	"ai": {},
}


# 确保某侧的记录表存在并返回引用
func _side_map(side: String) -> Dictionary:
	if not _buffs.has(side):
		_buffs[side] = {}
	return _buffs[side]


## 添加 Buff。返回该 buff 叠加后的总层数（已被 max_stack 截断）
## duration_override >= 0 时以它为准（卡牌自带的 duration 优先于 buff 模板默认）
func add_buff(side: String, buff_id: String, stacks: int = 1, duration_override: int = -1) -> int:
	var tmpl := DataLoader.get_buff(buff_id)
	if tmpl.is_empty():
		push_warning("[BuffSystem] 未知 Buff：%s" % buff_id)
		return 0
	var side_map := _side_map(side)
	var max_stack: int = tmpl.max_stack
	var dur := _resolve_duration(tmpl, duration_override)
	if side_map.has(buff_id):
		# 已存在：层数累加并截断到上限
		var rec: Dictionary = side_map[buff_id]
		rec.stacks = mini(rec.stacks + stacks, max_stack)
		# 重新施加刷新持续时长（比赛单局保持 -1）
		if dur != DURATION_MATCH:
			rec.duration_left = dur
		return rec.stacks
	# 新建记录
	var record := {
		"id": buff_id,
		"name": tmpl.buff_name,
		"type": tmpl.buff_type,          # 正向 / 负面
		"duration_left": dur,            # -1 表示比赛单局永久
		"max_stack": max_stack,
		"stacks": mini(stacks, max_stack),
		"base_effects": tmpl.base_effects,
		"desc": tmpl.desc,
	}
	side_map[buff_id] = record
	return record.stacks


## 决定持续时长：override 优先，其次模板默认
func _resolve_duration(tmpl: Dictionary, override: int) -> int:
	if override >= 0:
		return override
	return tmpl.duration


## 移除单个 Buff
func remove_buff(side: String, buff_id: String) -> void:
	_side_map(side).erase(buff_id)


## 移除指定类型的全部 Buff（buff_type: "正向" / "负面"），返回移除数量
func remove_type(side: String, buff_type: String) -> int:
	var side_map := _side_map(side)
	var removed := 0
	for buff_id in side_map.keys():
		if side_map[buff_id].type == buff_type:
			side_map.erase(buff_id)
			removed += 1
	return removed


## 清空某侧全部 Buff
func clear_all(side: String) -> void:
	_side_map(side).clear()


func has_buff(side: String, buff_id: String) -> bool:
	return _side_map(side).has(buff_id)


func get_stacks(side: String, buff_id: String) -> int:
	var side_map := _side_map(side)
	if side_map.has(buff_id):
		return side_map[buff_id].stacks
	return 0


## 返回某侧全部活跃 Buff 记录（字典引用，key 为 buff_id）
func get_buffs(side: String) -> Dictionary:
	return _side_map(side)


## 从存档快照整体恢复双方 Buff（覆盖当前全部）
## side_records: { "player": [ {id, stacks, duration_left}, ... ], "ai": [...] }
func restore_all(side_records: Dictionary) -> void:
	_buffs = {"player": {}, "ai": {}}
	for side in ["player", "ai"]:
		var arr: Array = side_records.get(side, [])
		for rec in arr:
			_restore_one(side, rec)


func _restore_one(side: String, rec) -> void:
	var tmpl := DataLoader.get_buff(str(rec.id))
	if tmpl.is_empty():
		push_warning("[BuffSystem] 恢复未知 Buff：%s" % str(rec.id))
		return
	var side_map := _side_map(side)
	side_map[rec.id] = {
		"id": str(rec.id),
		"name": tmpl.buff_name,
		"type": tmpl.buff_type,
		"duration_left": int(rec.duration_left),
		"max_stack": tmpl.max_stack,
		"stacks": int(rec.stacks),
		"base_effects": tmpl.base_effects,
		"desc": tmpl.desc,
	}


## 聚合某效果键的数值：对每个活跃 Buff 累加 值 × 层数
func get_effect_sum(side: String, effect_key: String) -> float:
	var total := 0.0
	for rec in _side_map(side).values():
		if not rec.has("base_effects"):
			continue
		for k in rec.base_effects:
			if k == effect_key:
				total += _value_as_float(rec.base_effects[k]) * rec.stacks
	return total


## 回合结束：扣减非永久 Buff 的持续时长，到期移除
func tick_round_end(side: String) -> void:
	var side_map := _side_map(side)
	var to_remove: Array = []
	for buff_id in side_map.keys():
		var rec: Dictionary = side_map[buff_id]
		if rec.duration_left == DURATION_MATCH:
			continue
		rec.duration_left -= 1
		if rec.duration_left <= 0:
			to_remove.append(buff_id)
	for buff_id in to_remove:
		side_map.erase(buff_id)


## 双方同时执行回合结束扣减
func tick_round_end_all() -> void:
	tick_round_end("player")
	tick_round_end("ai")


## UI 摘要：如 "稳固防线×2(1回)"；比赛单局显示 "单局"
func get_active_summary(side: String) -> String:
	var side_map := _side_map(side)
	if side_map.is_empty():
		return "无"
	var parts: Array = []
	for buff_id in side_map.keys():
		var rec: Dictionary = side_map[buff_id]
		var dur: String = "单局" if rec.duration_left == DURATION_MATCH else "%d回" % rec.duration_left
		parts.append("%s×%d(%s)" % [rec.name, rec.stacks, dur])
	return "，".join(parts)


# ---------- 工具 ----------
func _value_as_float(v: Variant) -> float:
	if v is String:
		if v.is_valid_float():
			return v.to_float()
		return 0.0
	if v is float:
		return v
	if v is int:
		return float(v)
	return 0.0


## Step2 自检打印：验证层数上限、倒计时、比赛单局、聚合效果
func debug_self_test() -> void:
	var bs := BuffSystem.new()
	print("===== BuffSystem 自检 =====")
	print("[1] 连加 5 次 B003(稳固防线, 上限3, 持续2回)：")
	var last := 0
	for i in 5:
		last = bs.add_buff("player", "B003")
	print("    最终层数 = %d（期望 3，被上限截断）" % last)
	print("    enemy_goal_reduce 聚合 = %.2f（期望 0.90 = 0.3×3）" % bs.get_effect_sum("player", "enemy_goal_reduce"))
	print("[2] 回合倒计时：")
	bs.tick_round_end("player")
	print("    第1次扣减后: %s" % bs.get_active_summary("player"))
	bs.tick_round_end("player")
	print("    第2次扣减后: %s（期望 无，已到期移除）" % bs.get_active_summary("player"))
	print("[3] 比赛单局 Buff：")
	bs.add_buff("player", "BD001")  # 体能下滑, 持续1
	bs.add_buff("player", "BD004")  # 体能透支, 比赛单局
	bs.add_buff("player", "BD004")
	print("    当前: %s" % bs.get_active_summary("player"))
	bs.tick_round_end_all()
	print("    tick_round_end_all 后: %s（期望只剩 体能透支×1(单局)，BD004 上限=1）" % bs.get_active_summary("player"))
	print("[4] 按类型移除：")
	bs.remove_type("player", "负面")
	print("    移除全部负面后: %s（期望 无）" % bs.get_active_summary("player"))
