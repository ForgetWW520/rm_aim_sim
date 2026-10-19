extends RefCounted

const LocalIPC = preload("res://scripts/local_ipc.gd")
var ipc = LocalIPC.new()
var last_command = ""
var publication = 0
var publisher_id = "%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()]
var model: RefCounted
var enabled = false
var bound = false
var last_sequence = -1
var last_receive_usec = 0
var timeout = 0.25
var status = "本地手动控制"
var received = 0
var rejected = 0
var elapsed = 0.0
var interval = 1.0 / 60.0
var config: Dictionary


func setup(simulation: RefCounted) -> Error:
	model = simulation
	config = model.settings.ipc.duplicate()
	timeout = config.timeout
	interval = 1.0 / config.state_hz
	var error = ipc.setup(config.channel)
	bound = error == OK
	if not bound:
		status = "本机 IPC 启动失败：%d" % error
	return error


func set_enabled(value: bool) -> void:
	var next_enabled = value and bound
	if next_enabled != enabled:
		model.session_id = "%d-%d" % [Time.get_ticks_usec(), randi()]
	enabled = next_enabled
	last_sequence = -1
	last_receive_usec = 0
	model.stop()
	status = "等待外部指令" if enabled else "本地手动控制"


func reset_session() -> void:
	last_sequence = -1
	last_receive_usec = 0
	elapsed = interval
	status = "等待外部指令" if enabled else "本地手动控制"
	last_command = ""


func poll(wall_dt: float) -> void:
	if bound:
		var packet = ipc.read_json("command.json")
		var identity = JSON.stringify(packet)
		if not packet.is_empty() and identity != last_command:
			last_command = identity
			if packet.get("publisher_id") == publisher_id:
				accept_command(packet, Time.get_ticks_usec())
			else:
				rejected += 1
	check_timeout(Time.get_ticks_usec())
	elapsed += wall_dt
	if bound and elapsed >= interval:
		elapsed = fmod(elapsed, interval)
		publication += 1
		var state = model.snapshot()
		state["wall_unix_sec"] = Time.get_unix_time_from_system()
		state["publication"] = publication
		state["publisher_id"] = publisher_id
		state["ipc"] = {"enabled": enabled, "status": status,
			"last_seq": last_sequence, "received": received, "rejected": rejected}
		ipc.write_json("state.json", state)


func accept_command(value: Variant, now_usec: int) -> bool:
	if not enabled or not value is Dictionary or model.paused:
		rejected += 1
		return false
	var valid = value.get("protocol") == "rm_aim_sim/2" and value.get("type") == "command"
	valid = valid and value.get("session_id") == model.session_id
	var sequence = value.get("seq", -1)
	if not (sequence is int or sequence is float):
		valid = false
	elif not is_finite(float(sequence)) or float(sequence) != floor(float(sequence)) \
			or float(sequence) < 0 or float(sequence) > 9007199254740991.0:
		valid = false
	elif int(sequence) <= last_sequence:
		valid = false
	for name in ["control", "fire"]:
		if not value.get(name) is bool:
			valid = false
	for name in ["yaw", "pitch", "yaw_vel", "pitch_vel", "yaw_acc", "pitch_acc"]:
		var number = value.get(name, 0.0)
		if not (number is int or number is float) or not is_finite(float(number)):
			valid = false
		elif absf(float(number)) > 1000.0:
			valid = false
	if not value.has("yaw") or not value.has("pitch"):
		valid = false
	if not valid:
		rejected += 1
		return false
	model.set_command(value)
	last_sequence = int(sequence)
	last_receive_usec = now_usec
	received += 1
	status = "外部控制 · seq %d" % last_sequence
	return true


func check_timeout(now_usec: int) -> void:
	if enabled and last_receive_usec > 0 and (now_usec - last_receive_usec) * 1e-6 > timeout:
		model.stop()
		last_receive_usec = 0
		status = "指令超时 · 已停止控制和发射"


func close() -> void:
	ipc.close()
	bound = false
