extends Control
## 设置界面：音量(音乐/音效/主音量+静音) / AI 难度 / 比赛时长
## 改动即时写入 DataLoader.settings，点"保存并返回"持久化到 user://settings.json

@onready var music_slider: HSlider = $Panel/MusicSlider
@onready var sfx_slider: HSlider = $Panel/SfxSlider
@onready var master_slider: HSlider = $Panel/MasterSlider
@onready var music_val: Label = $Panel/MusicVal
@onready var sfx_val: Label = $Panel/SfxVal
@onready var master_val: Label = $Panel/MasterVal
@onready var mute_btn: CheckButton = $Panel/MuteBtn
@onready var easy_btn: Button = $Panel/EasyBtn
@onready var normal_btn: Button = $Panel/NormalBtn
@onready var hard_btn: Button = $Panel/HardBtn
@onready var t60_btn: Button = $Panel/T60Btn
@onready var t120_btn: Button = $Panel/T120Btn
@onready var t180_btn: Button = $Panel/T180Btn
@onready var back_btn: Button = $Panel/BackBtn

func _ready() -> void:
	DataLoader.load_settings()
	AudioMgr.play_music("res://audio/bgm/全局音效.mp3")   # 设置界面沿用全局音效
	var s: Dictionary = DataLoader.settings
	music_slider.value = float(s["music_volume"])
	sfx_slider.value = float(s["sfx_volume"])
	master_slider.value = float(s["master_volume"])
	mute_btn.button_pressed = bool(s["muted"])
	_select_diff(str(s["difficulty"]))
	_select_time(float(s["match_duration"]))

	music_slider.value_changed.connect(func(v: float) -> void: _on_volume("music_volume", music_val, v))
	sfx_slider.value_changed.connect(func(v: float) -> void: _on_volume("sfx_volume", sfx_val, v))
	master_slider.value_changed.connect(func(v: float) -> void: _on_volume("master_volume", master_val, v))
	mute_btn.toggled.connect(func(on: bool) -> void:
		DataLoader.settings["muted"] = on
		AudioMgr.apply_volume())

	easy_btn.pressed.connect(func() -> void: DataLoader.settings["difficulty"] = "easy")
	normal_btn.pressed.connect(func() -> void: DataLoader.settings["difficulty"] = "normal")
	hard_btn.pressed.connect(func() -> void: DataLoader.settings["difficulty"] = "hard")
	t60_btn.pressed.connect(func() -> void: DataLoader.settings["match_duration"] = 60.0)
	t120_btn.pressed.connect(func() -> void: DataLoader.settings["match_duration"] = 120.0)
	t180_btn.pressed.connect(func() -> void: DataLoader.settings["match_duration"] = 180.0)

	back_btn.pressed.connect(_save_and_back)
	_refresh_vol_labels()


func _refresh_vol_labels() -> void:
	music_val.text = "%d" % int(music_slider.value)
	sfx_val.text = "%d" % int(sfx_slider.value)
	master_val.text = "%d" % int(master_slider.value)


func _on_volume(key: String, val_label: Label, v: float) -> void:
	DataLoader.settings[key] = v
	val_label.text = "%d" % int(v)
	AudioMgr.apply_volume()   # 实时生效，改音量立刻能听到


func _select_diff(d: String) -> void:
	easy_btn.button_pressed = (d == "easy")
	normal_btn.button_pressed = (d == "normal")
	hard_btn.button_pressed = (d == "hard")


func _select_time(sec: float) -> void:
	t60_btn.button_pressed = is_equal_approx(sec, 60.0)
	t120_btn.button_pressed = is_equal_approx(sec, 120.0)
	t180_btn.button_pressed = is_equal_approx(sec, 180.0)


func _save_and_back() -> void:
	DataLoader.save_settings()
	get_tree().change_scene_to_file("res://Ui/00_beginning.tscn")
