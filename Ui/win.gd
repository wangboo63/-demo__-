extends Control
## 胜利界面：显示比分，重新开始回到战斗 / 回到主界面

func _ready() -> void:
	AudioMgr.play_music("res://audio/bgm/全局音效.mp3")   # 比赛结束换回全局音效
	$Panel/Button.pressed.connect(_on_restart)
	$Panel/BackButton.pressed.connect(_on_back)
	var lbl := $Panel/Label
	if DataLoader.match_winner == "draw":
		lbl.text = "平局\n比分 %d : %d" % [DataLoader.match_player_goals, DataLoader.match_ai_goals]
	elif DataLoader.match_player_goals > 0 or DataLoader.match_ai_goals > 0:
		lbl.text = "我们是冠军!!!\n比分 %d : %d" % [DataLoader.match_player_goals, DataLoader.match_ai_goals]

func _on_restart() -> void:
	AudioMgr.play_music("res://audio/bgm/比赛音效.mp3")   # 重开比赛切比赛音效
	get_tree().change_scene_to_file("res://Scencs/03_fight.tscn")

func _on_back() -> void:
	AudioMgr.play_music("res://audio/bgm/全局音效.mp3")   # 回主界面沿用全局音效
	get_tree().change_scene_to_file("res://Ui/00_beginning.tscn")
