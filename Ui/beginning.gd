extends Control
## 开始界面：进入过渡/新游戏

func _ready() -> void:
	DataLoader.load_settings()      # 进游戏前先加载设置
	AudioMgr.play_music("res://audio/bgm/全局音效.mp3")   # 打开游戏→全局音效循环
	$Panel/Button.pressed.connect(_on_start)      # 开始游戏
	$Panel/Button4.pressed.connect(_on_quit)      # 退出游戏
	$Panel/Button2.pressed.connect(_on_start)      # 存档 → 存档选择界面
	$Panel/Button3.pressed.connect(_on_settings)   # 设置 → 设置界面

func _on_start() -> void:
	get_tree().change_scene_to_file("res://Ui/01_guodu.tscn")

func _on_quit() -> void:
	get_tree().quit()

func _on_settings() -> void:
	get_tree().change_scene_to_file("res://Ui/02_settings.tscn")
