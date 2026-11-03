class_name DataLoader
extends RefCounted
## ============================================================
##  CSV 数据加载器（Step 1）
##  - 读取 card_config.csv / buff_config.csv（UTF-8 BOM 兼容）
##  - 把 effect_param 拆成 key=value 字典（支持 "无"、纯标记 key）
##  - 产出 卡牌模板 / Buff 模板 两个字典，供战斗逻辑与 Buff 系统查询
##
##  用法：
##    DataLoader.load_all()                 # 一次性加载全部
##    DataLoader.cards["C001"]              # 卡牌模板
##    DataLoader.buffs["B003"]              # Buff 模板
##    DataLoader.cards["C001"]["effect_params"]  # {"shot_bonus":"0.2", ...}
## ============================================================

# ---- 数据表（全局只读模板）----
# cards: { card_id : { card_name, cost, card_type, desc, effect_param, effect_params, ... } }
static var cards: Dictionary = {}
# buffs : { buff_id : { buff_name, buff_type, duration, max_stack, base_effect, base_effects, desc } }
static var buffs: Dictionary = {}

# ---- 跨场景比赛结果（战斗结束写入，胜负界面读取）----
static var match_winner := ""      # "player"/"ai"
static var match_player_goals := 0
static var match_ai_goals := 0

# ---- 存档相关（跨场景传递）----
static var active_slot := 0          # 当前比赛所属存档槽位(1/2/3)
static var resume_snapshot: Dictionary = {}   # 读档时待恢复的比赛快照

const PROFILE_PATH := "user://profile.json"

const CARD_CSV_PATH := "res://csv/card_config.csvraw"
const BUFF_CSV_PATH := "res://csv/buff_config.csvraw"

# 比赛单局类 Buff 的时长标记：-1 表示永久，不参与回合倒计时
const DURATION_MATCH := -1


## 加载全部数据表，返回是否全部成功
static func load_all() -> bool:
	var ok := true
	ok = _load_csv_table(CARD_CSV_PATH, cards, _parse_card_row) and ok
	ok = _load_csv_table(BUFF_CSV_PATH, buffs, _parse_buff_row) and ok
	return ok


## 通用：读取一张 CSV（UTF-8，兼容 BOM），逐行交给 row_parser 转成模板
static func _load_csv_table(path: String, table: Dictionary, row_parser: Callable) -> bool:
	if not FileAccess.file_exists(path):
		push_error("[DataLoader] 找不到文件：%s" % path)
		return false
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("[DataLoader] 无法打开：%s，错误码 %d" % [path, FileAccess.get_open_error()])
		return false
	var first_line := true
	while not file.eof_reached():
		var row: PackedStringArray = file.get_csv_line()
		if row.is_empty():
			continue
		if first_line:
			first_line = false
			# 兼容 UTF-8 BOM：去掉首单元格开头的 \uFEFF
			row[0] = row[0].trim_prefix("\uFEFF")
			continue  # 第一行是表头，跳过
		row_parser.call(row, table)
	file.close()
	return true


# ---------- 卡牌行解析 ----------
static func _parse_card_row(row: PackedStringArray, table: Dictionary) -> void:
	if row.size() < 6:
		return
	var card_id := row[0].strip_edges()
	if card_id.is_empty() or card_id.begins_with("#"):
		return
	table[card_id] = {
		"card_id": card_id,
		"card_name": row[1].strip_edges(),
		"cost": _parse_int_or(row[2].strip_edges(), 1),
		"card_type": row[3].strip_edges(),
		"desc": row[4].strip_edges(),
		"effect_param": row[5].strip_edges(),
		"effect_params": _parse_params(row[5].strip_edges()),
		"upgrade_desc": row[6].strip_edges() if row.size() > 6 else "",
		"upgrade_param": row[7].strip_edges() if row.size() > 7 else "",
		"counter_tag": row[8].strip_edges() if row.size() > 8 else "",
		"special_limit": row[9].strip_edges() if row.size() > 9 else "",
	}


# ---------- Buff 行解析 ----------
static func _parse_buff_row(row: PackedStringArray, table: Dictionary) -> void:
	if row.size() < 6:
		return
	var buff_id := row[0].strip_edges()
	if buff_id.is_empty() or buff_id.begins_with("#"):
		return
	var duration_str := row[3].strip_edges()
	var duration := _parse_int_or(duration_str, 1)
	# "比赛单局" 类 Buff：永久生效，不参与回合倒计时
	if duration_str.find("单局") != -1 or duration_str.to_lower().find("game") != -1:
		duration = DURATION_MATCH
	table[buff_id] = {
		"buff_id": buff_id,
		"buff_name": row[1].strip_edges(),
		"buff_type": row[2].strip_edges(),   # 正向 / 负面
		"duration": duration,
		"max_stack": _parse_int_or(row[4].strip_edges(), 3),
		"base_effect": row[5].strip_edges(),
		"base_effects": _parse_params(row[5].strip_edges()),
		"desc": row[6].strip_edges() if row.size() > 6 else "",
	}


## 把 "k1=v1;k2=v2" 解析成字典 {"k1":"v1","k2":"v2"}
## 兼容：空串 / "无" -> {}；纯标记 key（无 "="）-> value 记 ""
static func _parse_params(param_str: String) -> Dictionary:
	var result := {}
	if param_str.is_empty() or param_str == "无":
		return result
	for pair in param_str.split(";", false):
		pair = pair.strip_edges()
		if pair.is_empty():
			continue
		if "=" in pair:
			var kv := pair.split("=", false)
			if kv.size() >= 2:
				result[kv[0].strip_edges()] = kv[1].strip_edges()
		else:
			result[pair] = ""
	return result


# ---------- 工具 ----------
static func _parse_int_or(s: String, default_value: int) -> int:
	if s.is_valid_int():
		return s.to_int()
	return default_value


static func get_card(card_id: String) -> Dictionary:
	return cards.get(card_id, {})


static func get_buff(buff_id: String) -> Dictionary:
	return buffs.get(buff_id, {})


## 按 Buff 名称查模板（卡牌 effect_param 的 buff= 用的是名称，如 "稳固防线"）
static func get_buff_by_name(buff_name: String) -> Dictionary:
	for buff_id in buffs:
		if buffs[buff_id].buff_name == buff_name:
			return buffs[buff_id]
	return {}


## 自检打印：用于 Step1 验收，确认能读到真实卡牌与 effect_param
static func debug_print() -> void:
	print("===== DataLoader 自检 =====")
	print("卡牌模板数：%d | Buff 模板数：%d" % [cards.size(), buffs.size()])
	for card_id in ["C001", "D002", "M002", "S002"]:
		if cards.has(card_id):
			var c: Dictionary = cards[card_id]
			print("  卡[%s] %s | 费用%d | 类型%s" % [card_id, c.card_name, c.cost, c.card_type])
			print("    effect_param = %s" % c.effect_param)
			print("    effect_params = %s" % c.effect_params)
	for buff_id in ["B003", "BD001", "BD004"]:
		if buffs.has(buff_id):
			var b: Dictionary = buffs[buff_id]
			print("  Buff[%s] %s | 类型%s | 持续%d | 上限%d" % [buff_id, b.buff_name, b.buff_type, b.duration, b.max_stack])
			print("    base_effects = %s" % b.base_effects)


# ============================================================
# 存档系统（续玩 + 战绩）
#   - save_{1..3}.json ：单局比赛快照（可退出再进来接着打）
#   - profile.json     ：跨局总战绩（胜/负/平/总进球）
# 读写全部 user://，静态方法，跨场景直接调用 DataLoader.xxx
# ============================================================
static func _slot_path(slot: int) -> String:
	return "user://save_%d.json" % slot


static func has_save(slot: int) -> bool:
	return FileAccess.file_exists(_slot_path(slot))


## 把比赛快照写入指定槽位，成功返回 true
static func save_match(slot: int, data: Dictionary) -> bool:
	var f := FileAccess.open(_slot_path(slot), FileAccess.WRITE)
	if f == null:
		push_error("[存档] 无法写槽位%d：错误码%d" % [slot, FileAccess.get_open_error()])
		return false
	f.store_string(JSON.stringify(data))
	f.close()
	return true


## 读取槽位快照；无存档或损坏返回空字典
static func load_match(slot: int) -> Dictionary:
	if not has_save(slot):
		return {}
	var f := FileAccess.open(_slot_path(slot), FileAccess.READ)
	if f == null:
		return {}
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	return parsed if parsed is Dictionary else {}


static func delete_save(slot: int) -> void:
	if has_save(slot):
		DirAccess.remove_absolute(_slot_path(slot))


## 槽位摘要（供界面显示）：比分/剩余时间/保存时间
static func slot_summary(slot: int) -> Dictionary:
	var s := load_match(slot)
	if s.is_empty():
		return {}
	var p: Dictionary = s.get("player", {})
	var a: Dictionary = s.get("ai", {})
	return {
		"score": "%d:%d" % [int(p.get("goals", 0)), int(a.get("goals", 0))],
		"time_left": float(s.get("match_time_left", 0.0)),
		"saved_at": int(s.get("saved_at", 0)),
		"status": str(s.get("status", "progress")),
	}


# ---------- 战绩统计 ----------
static func load_profile() -> Dictionary:
	var d := {"wins": 0, "losses": 0, "draws": 0, "pg": 0, "ag": 0, "matches": 0}
	if not FileAccess.file_exists(PROFILE_PATH):
		return d
	var f := FileAccess.open(PROFILE_PATH, FileAccess.READ)
	if f == null:
		return d
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed is Dictionary:
		for k in d.keys():
			if parsed.has(k):
				d[k] = int(parsed[k])
	return d


static func save_profile(p: Dictionary) -> void:
	var f := FileAccess.open(PROFILE_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(p))
	f.close()


## 比赛结束记录一局结果（玩家胜/负/平 + 双方进球）
static func record_match(winner: String, pg: int, ag: int) -> void:
	var p := load_profile()
	p.matches += 1
	if winner == "player":
		p.wins += 1
	elif winner == "ai":
		p.losses += 1
	else:
		p.draws += 1
	p.pg += pg
	p.ag += ag
	save_profile(p)


# ============================================================
# 设置系统（音量 / 难度 / 比赛时长），持久化到 user://settings.json
#   DataLoader.load_settings()   读取(幂等，任意场景 _ready 可调用)
#   DataLoader.save_settings()   写回
#   DataLoader.settings          全局设置字典(跨场景读取)
# ============================================================
const SETTINGS_PATH := "user://settings.json"

static var settings: Dictionary = {
	"master_volume": 80.0,   # 主音量 0~100
	"music_volume": 70.0,    # 音乐音量 0~100
	"sfx_volume": 80.0,      # 音效音量 0~100
	"muted": false,          # 总静音
	"difficulty": "normal",  # easy / normal / hard
	"match_duration": 120.0, # 比赛时长(秒) 60/120/180
}

## 读取设置；文件不存在或损坏时用默认值。幂等，可重复调用。
static func load_settings() -> void:
	if not FileAccess.file_exists(SETTINGS_PATH):
		return
	var f := FileAccess.open(SETTINGS_PATH, FileAccess.READ)
	if f == null:
		return
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed is Dictionary:
		for k in settings.keys():
			if parsed.has(k):
				settings[k] = parsed[k]
	# 归一化，防脏数据
	settings["muted"] = bool(settings.get("muted", false))
	settings["master_volume"] = clampf(float(settings.get("master_volume", 80.0)), 0.0, 100.0)
	settings["music_volume"] = clampf(float(settings.get("music_volume", 70.0)), 0.0, 100.0)
	settings["sfx_volume"] = clampf(float(settings.get("sfx_volume", 80.0)), 0.0, 100.0)
	settings["match_duration"] = clampf(float(settings.get("match_duration", 120.0)), 30.0, 600.0)
	var d := str(settings.get("difficulty", "normal"))
	settings["difficulty"] = d if d in ["easy", "normal", "hard"] else "normal"


static func save_settings() -> void:
	var f := FileAccess.open(SETTINGS_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(settings))
	f.close()
