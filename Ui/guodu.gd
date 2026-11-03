extends Control
## 过渡/存档选择界面：3 个槽位（单选选中式交互）
##  - 点击槽位 → 选中高亮（记录当前槽，不立即跳转）
##  - 顶部「进入游戏」→ 用选中槽进入：有档=读档续玩，无档=开新游戏
##  - 顶部「删除选中存档」→ 只删除当前选中的槽位；底部显示总战绩

func _ready() -> void:
	AudioMgr.play_music("res://audio/bgm/全局音效.mp3")   # 存档/过渡界面沿用全局音效
	var slots := [$Button, $Button2, $Button3]
	# ButtonGroup 保证三个槽位单选（只高亮一个）
	var group := ButtonGroup.new()
	for i in slots.size():
		var b: Button = slots[i]
		b.set_meta("slot", i + 1)
		_update_slot_button(b)
		b.toggle_mode = true
		b.button_group = group
		b.pressed.connect(_on_slot_selected.bind(i + 1))
	$ClearButton.pressed.connect(_on_delete_selected)
	$StartButton.pressed.connect(_on_start)
	# 默认选中槽1
	$Button.button_pressed = true
	DataLoader.active_slot = 1
	_refresh_stats()


func _update_slot_button(b: Button) -> void:
	var slot: int = b.get_meta("slot")
	if DataLoader.has_save(slot):
		var sum := DataLoader.slot_summary(slot)
		var dt := Time.get_datetime_dict_from_unix_time(sum.saved_at)
		# 有存档：字号调小、每条信息单列一行，避免内容溢出遮挡相邻按钮
		b.add_theme_font_size_override("font_size", 26)
		if sum.status == "finished":
			# 比赛结束的存档（胜利）：存档/胜负/比分/时间 各一行
			b.text = "存档%d\n胜利\n比分 %s\n时间 %d-%02d" % [
				slot, sum.score, dt.year, dt.month,
			]
		else:
			# 战斗中途保存：存档/状态/比分/剩余时间/时间 各一行
			b.text = "存档%d\n临时\n比分 %s\n剩余%ds\n时间 %d-%02d" % [
				slot, sum.score, int(sum.time_left), dt.year, dt.month,
			]
	else:
		b.add_theme_font_size_override("font_size", 42)
		b.text = "存档%d\n暂无存档\n点击开始新游戏" % slot


func _on_slot_selected(slot: int) -> void:
	# 仅选中该槽，记录为当前槽（不跳转）；真正进入由「进入游戏」触发
	DataLoader.active_slot = slot


func _on_start() -> void:
	var slot := DataLoader.active_slot
	if slot <= 0:
		return
	AudioMgr.play_music("res://audio/bgm/比赛音效.mp3")   # 进入比赛切比赛音效
	if DataLoader.has_save(slot):
		DataLoader.resume_snapshot = DataLoader.load_match(slot)
	else:
		DataLoader.resume_snapshot = {}
	get_tree().change_scene_to_file("res://Scencs/03_fight.tscn")


func _on_delete_selected() -> void:
	var slot := DataLoader.active_slot
	if slot <= 0 or not DataLoader.has_save(slot):
		print("[存档] 无选中存档可删除")
		return
	DataLoader.delete_save(slot)
	for b in [$Button, $Button2, $Button3]:
		_update_slot_button(b)


func _refresh_stats() -> void:
	var p := DataLoader.load_profile()
	$StatsLabel.text = "总战绩  胜%d 负%d 平%d | 总进球 %d : %d | 场次 %d" % [
		p.wins, p.losses, p.draws, p.pg, p.ag, p.matches,
	]
