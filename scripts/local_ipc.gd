extends RefCounted

var directory = ""
var owned = false


static func valid_name(value: String) -> bool:
	if value.is_empty() or value.length() > 80:
		return false
	for character in value:
		if not character in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-":
			return false
	return true


func setup(channel: String) -> Error:
	if OS.get_name() != "Linux" or not valid_name(channel):
		return ERR_INVALID_PARAMETER
	directory = "/dev/shm/rm_aim_sim_" + channel
	var error = DirAccess.make_dir_absolute(directory)
	if error not in [OK, ERR_ALREADY_EXISTS]:
		return error
	# 448 is Unix 0700; only this user can access the mailbox directory.
	if FileAccess.set_unix_permissions(directory, 448) != OK:
		return ERR_UNAUTHORIZED
	var lock_path = directory.path_join("server.lock")
	error = DirAccess.make_dir_absolute(lock_path)
	if error == ERR_ALREADY_EXISTS:
		var owner = read_json("server.lock/owner.json")
		# Never take over a live publisher, or a publisher still creating its owner file.
		var pid = int(owner.get("pid", 0))
		if pid <= 0 or FileAccess.file_exists("/proc/%d/status" % pid):
			return ERR_ALREADY_IN_USE
		DirAccess.remove_absolute(lock_path.path_join("owner.json"))
		DirAccess.remove_absolute(lock_path)
		error = DirAccess.make_dir_absolute(lock_path)
	if error != OK:
		return error
	owned = true
	if write_json("server.lock/owner.json", {"pid": OS.get_process_id()}) != OK:
		close()
		return ERR_CANT_CREATE
	# A crashed process may leave one completed frame. No other publisher owns this channel.
	for filename in DirAccess.get_files_at(directory):
		if filename in ["state.json", "command.json", "request.json", "frame.json"] \
				or filename.ends_with(".tmp") or filename.begins_with("frame-"):
			DirAccess.remove_absolute(directory.path_join(filename))
	return OK


func read_json(filename: String) -> Dictionary:
	var path = directory.path_join(filename)
	if not FileAccess.file_exists(path):
		return {}
	var file = FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() > 65536:
		return {}
	var value = JSON.parse_string(file.get_as_text())
	return value if value is Dictionary else {}


func write_json(filename: String, value: Dictionary) -> Error:
	return write_bytes(filename, JSON.stringify(value).to_utf8_buffer())


func write_bytes(filename: String, value: PackedByteArray) -> Error:
	var path = directory.path_join(filename)
	var file = FileAccess.open(path + ".tmp", FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_buffer(value)
	var error = file.get_error()
	file.close()
	if error != OK:
		DirAccess.remove_absolute(path + ".tmp")
		return error
	# Publish only completed data. Readers holding the previous inode can finish safely.
	return DirAccess.rename_absolute(path + ".tmp", path)


func close() -> void:
	if not owned:
		return
	for filename in DirAccess.get_files_at(directory):
		if filename in ["state.json", "command.json", "request.json", "frame.json"] \
				or filename.ends_with(".tmp") or filename.begins_with("frame-"):
			DirAccess.remove_absolute(directory.path_join(filename))
	DirAccess.remove_absolute(directory.path_join("server.lock/owner.json"))
	DirAccess.remove_absolute(directory.path_join("server.lock"))
	owned = false
