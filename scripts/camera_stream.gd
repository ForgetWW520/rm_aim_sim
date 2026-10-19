extends RefCounted

const LocalIPC = preload("res://scripts/local_ipc.gd")

var model: RefCounted
var bridge: RefCounted
var viewport: SubViewport
var capturing = false
var closed = false
var last_request = ""
var previous_file = ""


func setup(simulation: RefCounted, control_bridge: RefCounted, sensor: SubViewport) -> void:
	model = simulation
	bridge = control_bridge
	viewport = sensor


func poll() -> void:
	if capturing or closed or not bridge.bound:
		return
	var request = bridge.ipc.read_json("request.json")
	var identity = str(request.get("request_id", ""))
	if not LocalIPC.valid_name(identity) or identity == last_request \
			or request.get("publisher_id") != bridge.publisher_id:
		return
	last_request = identity
	_capture(identity)


func _capture(identity: String) -> void:
	capturing = true
	var started = Time.get_ticks_usec()
	# Capture metadata before draw, while it still matches the world's transforms.
	var metadata = model.snapshot()
	metadata.erase("truth")
	metadata.erase("events")
	metadata.type = "frame"
	metadata["publisher_id"] = bridge.publisher_id
	metadata["request_id"] = identity
	metadata["ipc"] = {"enabled": bridge.enabled, "last_seq": bridge.last_sequence}
	await RenderingServer.frame_post_draw
	if closed:
		capturing = false
		return
	var rendered = Time.get_ticks_usec()
	var image = viewport.get_texture().get_image()
	var read_back = Time.get_ticks_usec()
	if image.get_format() not in [Image.FORMAT_RGB8, Image.FORMAT_RGBA8]:
		image.convert(Image.FORMAT_RGB8)
	metadata["encoding"] = "rgba8" if image.get_format() == Image.FORMAT_RGBA8 else "rgb8"
	var pixels = image.get_data()
	var filename = "frame-" + identity + ".raw"
	if bridge.ipc.write_bytes(filename, pixels) != OK:
		capturing = false
		return
	metadata["frame_file"] = filename
	metadata["image_bytes"] = pixels.size()
	metadata["capture_timing"] = {"render_ms": (rendered - started) * 0.001,
		"readback_ms": (read_back - rendered) * 0.001,
		"publish_ms": (Time.get_ticks_usec() - read_back) * 0.001, "raw_bytes": pixels.size()}
	if bridge.ipc.write_json("frame.json", metadata) == OK:
		# A request acknowledges the preceding frame has been copied. Unique filenames
		# also let a reader finish safely across reconnects, resolution changes and resets.
		if not previous_file.is_empty():
			DirAccess.remove_absolute(bridge.ipc.directory.path_join(previous_file))
		previous_file = filename
	else:
		DirAccess.remove_absolute(bridge.ipc.directory.path_join(filename))
	capturing = false


func close() -> void:
	closed = true
