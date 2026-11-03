extends Node
## ============================================================
##  全局常驻音频管理器（Autoload "AudioMgr"）
##   - 音乐：跨场景持续循环播放（bgm_begin / bgm_battle / bgm_result），
##     切场景不会中断；同一首已在播则不重播。
##   - 音效：一次性播放（sfx_win 等），播完自动释放。
##   - 音量：读 DataLoader.settings（master_volume / music_volume /
##     sfx_volume / muted），实时换算 dB。
## ============================================================

var _music: AudioStreamPlayer
var _sfx: AudioStreamPlayer

func _ready() -> void:
	_music = AudioStreamPlayer.new()
	_music.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_music)
	_sfx = AudioStreamPlayer.new()
	_sfx.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_sfx)
	_apply_volume()


## 供设置界面实时调用：滑条/静音改动后立即生效
func apply_volume() -> void:
	_apply_volume()


func _apply_volume() -> void:
	var s: Dictionary = DataLoader.settings
	var muted := bool(s.get("muted", false))
	var master := clampf(float(s.get("master_volume", 80.0)), 0.0, 100.0) / 100.0
	var music := clampf(float(s.get("music_volume", 70.0)), 0.0, 100.0) / 100.0
	var sfx := clampf(float(s.get("sfx_volume", 80.0)), 0.0, 100.0) / 100.0
	if muted:
		_music.volume_db = -60.0
		_sfx.volume_db = -60.0
	else:
		_music.volume_db = linear_to_db(maxf(master * music, 0.0001))
		_sfx.volume_db = linear_to_db(maxf(master * sfx, 0.0001))


## 播放（切换）背景音乐；同一首已在播则不重播。
## 音乐始终循环：能设置 loop 的流设无缝循环，播完再兜底自动重播。
func play_music(path: String) -> void:
	_apply_volume()
	var want: AudioStream = load(path)
	if want == null:
		push_error("[AudioMgr] 无法加载音乐：%s" % path)
		return
	if _music.stream == want and _music.playing:
		return
	_music.stream = want
	_enable_loop(want)
	# 兜底循环：任何流播放到结尾后自动重新播放，保证"打开游戏一直循环"
	if not _music.finished.is_connected(_music.play):
		_music.finished.connect(_music.play)
	_music.play()


## 让流的循环属性生效（Ogg 设 loop_mode；支持 loop 的 mp3 设 loop=true）
func _enable_loop(stream: AudioStream) -> void:
	if stream == null:
		return
	if "loop" in stream:
		stream.set("loop", true)
	if "loop_mode" in stream:
		stream.set("loop_mode", AudioStreamWAV.LOOP_FORWARD)


## 播放一次性音效，播完自动释放
func play_sfx(path: String) -> void:
	_apply_volume()
	var p := AudioStreamPlayer.new()
	p.process_mode = Node.PROCESS_MODE_ALWAYS
	p.stream = load(path)
	if p.stream == null:
		push_error("[AudioMgr] 无法加载音效：%s" % path)
		p.queue_free()
		return
	p.volume_db = _sfx.volume_db
	add_child(p)
	p.play()
	p.finished.connect(p.queue_free)
