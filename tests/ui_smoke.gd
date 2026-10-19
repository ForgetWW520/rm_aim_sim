extends SceneTree

const Presets = preload("res://scripts/presets.gd")
const Settings = preload("res://scripts/settings.gd")
const WorldView = preload("res://scripts/world_view.gd")
var failures: Array[String] = []
var checks = 0


func _initialize() -> void:
	call_deferred("_run")


func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)


func wait_sim(main: Node, duration: float) -> void:
	var until: float = main.model.time + duration
	for _frame in range(120):
		await process_frame
		if main.model.time >= until:
			return
	check(false, "simulation advances within graphical test deadline")


func send_key(code: Key, pressed: bool) -> void:
	root.grab_focus()
	var event = InputEventKey.new()
	event.physical_keycode = code
	event.keycode = code
	event.pressed = pressed
	Input.parse_input_event(event)
	Input.flush_buffered_events()


func click_hold(button: Button, pressed: bool) -> void:
	root.grab_focus()
	var event = InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.position = button.get_global_rect().get_center()
	event.pressed = pressed
	Input.parse_input_event(event)
	Input.flush_buffered_events()


func check_rendered_extent(main: Node, diameter: float) -> void:
	var center: Vector3 = WorldView.to_engine(main.model.target_pose(main.model.time).center)
	var furthest = 0.0
	for plate in main.world.plates:
		for child in plate.get_children():
			if child is MeshInstance3D:
				var bounds: AABB = child.get_aabb()
				for corner in range(8):
					var point: Vector3 = child.global_transform * bounds.get_endpoint(corner) - center
					furthest = maxf(furthest, Vector2(point.x, point.z).length())
	check(absf(furthest * 2.0 - diameter) < 2e-6, "actual rendered board and lamp corners match rotation envelope")


func region_peak(image: Image, center: Vector2, half_size: Vector2i) -> float:
	var peak = 0.0
	var point = Vector2i(center)
	for y in range(maxi(0, point.y - half_size.y), mini(image.get_height(), point.y + half_size.y + 1)):
		for x in range(maxi(0, point.x - half_size.x), mini(image.get_width(), point.x + half_size.x + 1)):
			var pixel = image.get_pixel(x, y)
			peak = maxf(peak, maxf(pixel.r, maxf(pixel.g, pixel.b)))
	return peak


func capture_flash_frame(main: Node, stream: RefCounted, transport: RefCounted, name: String) -> Dictionary:
	main.world.update_world()
	var request_id = "flash_%d_%s" % [OS.get_process_id(), name]
	transport.ipc.write_json("request.json", {"publisher_id": transport.publisher_id, "request_id": request_id})
	stream.poll()
	await RenderingServer.frame_post_draw
	var metadata: Dictionary = transport.ipc.read_json("frame.json")
	check(metadata.get("request_id") == request_id, "flash frame is actually published")
	var image: Image = main.world.sensor_viewport.get_texture().get_image()
	var bytes = FileAccess.get_file_as_bytes(transport.ipc.directory.path_join(metadata.frame_file))
	check(image.get_data() == bytes, "flashing preview matches actual shared-memory pixels")
	return {"main": main.world.raw_sensor_viewport.get_texture().get_image(), "sensor": image, "metadata": metadata}


func check_hit_flash(main: Node, stream: RefCounted, transport: RefCounted) -> void:
	var saved_settings: Dictionary = main.model.settings.duplicate(true)
	var saved_paused: bool = main.model.paused
	for team in ["blue", "red"]:
		var settings = saved_settings.duplicate(true)
		settings.appearance.team = team
		settings.target.translate = false
		settings.target.rotate = false
		settings.target.max_health = 350
		settings.weapon.gravity = 0.0
		main.model.reset(settings)
		main.model.paused = true
		main.world.rebuild_target()
		var solution: Dictionary = preload("res://scripts/aim_assist.gd").solve(main.model, false)
		check(not solution.is_empty(), "flash test can aim a real projectile")
		if solution.is_empty():
			continue
		main.model.yaw = solution.yaw
		main.model.pitch = solution.pitch
		var armor_id: int = solution.armor_id
		var lit: Dictionary = await capture_flash_frame(main, stream, transport, team + "_lit")
		var corners: Array = lit.metadata.camera.armors[0].corners
		var top_left = Vector2(corners[0][0], corners[0][1])
		var bottom_left = Vector2(corners[3][0], corners[3][1])
		var bottom_right = Vector2(corners[2][0], corners[2][1])
		var lamp_center = (top_left + bottom_left) * 0.5
		# Sample the LED's center column; adjacent pixels may contain the ground grid behind it.
		var lamp_region = Vector2i(0, 4)
		var digit_center = (top_left + bottom_right) * 0.5
		var sticker: Sprite3D = main.world.plates[armor_id].get_node("ArmorSticker")
		check(main.world.plate_materials[armor_id].albedo_color == Presets.team_color(team), "flash starts at team color")
		main.model._spawn(main.model.time, solution.yaw, solution.pitch)
		main.model.paused = false
		for _i in range(1000):
			main.model.step(0.001)
			if main.model.stats.hit > 0:
				break
		main.model.paused = true
		check(main.model.stats.hit == 1 and main.model.health > 0, "rendered flash follows a real nonlethal collision")
		var dark: Dictionary = await capture_flash_frame(main, stream, transport, team + "_dark")
		check(not main.world.plate_materials[armor_id].emission_enabled
			and not main.world.lamp_glows[armor_id].visible, "hit disables both the LED mesh and optical glare")
		for index in range(4):
			if index != armor_id:
				check(main.world.plate_materials[index].emission_enabled and main.world.lamp_glows[index].visible,
					"unhit armor retains independent lit material and glare")
		check(main.world.brightness_material.get_shader_parameter("lamp_count") == 0
			and dark.metadata.camera.armors.is_empty(), "hit disables reconstructed sensor emission and ideal observations")
		for view in ["main", "sensor"]:
			check(region_peak(dark[view], lamp_center, lamp_region)
				< region_peak(lit[view], lamp_center, lamp_region) * 0.5,
				team + " lamp actually darkens in " + view + " pixels")
			check(region_peak(dark[view], digit_center, Vector2i(8, 12)) > 0.4,
				"printed number remains visible while LEDs are off")
		check(sticker.visible and is_instance_valid(sticker), "hit does not remove the board or sticker")
		main.world.rebuild_target()
		main.world.update_world()
		check(not main.world.plate_materials[armor_id].emission_enabled, "visual rebuild preserves active flash")
		main.model.paused = false
		main.model.step(0.051)
		main.model.paused = true
		var restored: Dictionary = await capture_flash_frame(main, stream, transport, team + "_restored")
		check(main.world.plate_materials[armor_id].emission_enabled
			and main.world.plate_materials[armor_id].albedo_color == Presets.team_color(team)
			and main.world.lamp_glows[armor_id].visible, "timeout restores the original team color and glare")
		check(not restored.metadata.camera.armors.is_empty(), "timeout restores ideal observation")
		for view in ["main", "sensor"]:
			check(region_peak(restored[view], lamp_center, lamp_region)
				> region_peak(lit[view], lamp_center, lamp_region) * 0.9,
				team + " lamp visibly relights in " + view + " pixels")
		main.model.settings.weapon.damage = 1000
		main.model._spawn(main.model.time, solution.yaw, solution.pitch)
		main.model.paused = false
		main.model.step(0.5)
		main.model.paused = true
		var dead: Dictionary = await capture_flash_frame(main, stream, transport, team + "_dead")
		check(main.model.health == 0 and dead.metadata.camera.armors.is_empty(), "lethal collision stays dark beyond flash timeout")
		for index in range(4):
			check(not main.world.plate_materials[index].emission_enabled and not main.world.lamp_glows[index].visible,
				"death keeps all armor lights and glare off")
	main.model.reset(saved_settings)
	main.model.paused = saved_paused
	main.world.rebuild_target()
	main.world.update_world()


func _run() -> void:
	var main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	root.grab_focus()
	await process_frame
	check(main.has_graphics, "GUI smoke test requires graphical display")
	if not main.has_graphics:
		quit(1)
		return
	var camera_only = "--camera-only" in OS.get_cmdline_user_args()
	if camera_only:
		main.model.paused = true
		main.set_process_input(false)
		main.set_process_unhandled_input(false)
	check(main.world.first_person and main.main_reticle.visible, "first person is the initial view")
	check(is_equal_approx(main.fields["camera.brightness_gain"].value, 0.4), "initial exposure slider is 0.4")
	var ground_found = false
	for child in main.world.get_children():
		if child is MeshInstance3D and child.mesh is BoxMesh and child.mesh.size == Vector3(32, 0.04, 32):
			ground_found = child.material_override.albedo_color.is_equal_approx(Color("303030"))
	check(ground_found, "ground uses light black material")
	check(root.disable_3d and main.first_person_image.visible, "first person reuses raw sensor rendering instead of rendering root 3D")
	check(main.first_person_image.texture == main.world.raw_sensor_viewport.get_texture(),
		"first person displays the unprocessed camera texture")
	check(main.first_person_image.texture != main.world.sensor_viewport.get_texture()
		and main.world.sensor_viewport.disable_3d, "exposure output is a separate 2D pass without duplicate 3D rendering")
	check(main.model.settings.target.center.x == 4.0, "initial distance is 4 m")
	check(is_equal_approx(main.fields["target.center.z"].value, 0.2), "initial lower-edge slider is 200 mm")
	check(is_equal_approx(main.fields["target.height_difference"].value, -0.1), "initial height difference is -100 mm")
	check(main.fields["target.radius"] is HSlider and is_equal_approx(main.fields["target.radius"].value, 0.55), "initial spacing slider is 550 mm")
	var transport = preload("res://scripts/bridge.gd").new()
	main.model.settings.ipc.channel = "ui_test_%d" % OS.get_process_id()
	check(transport.setup(main.model) == OK, "isolated shared memory publisher starts")
	var stream = preload("res://scripts/camera_stream.gd").new()
	stream.setup(main.model, transport, main.world.sensor_viewport)
	var camera_session: String = main.model.session_id
	var camera_health: int = main.model.health
	var camera_stats: Dictionary = main.model.stats.duplicate()
	for index in range(main.CAMERA_RESOLUTIONS.size()):
		var size: Vector2i = main.CAMERA_RESOLUTIONS[index]
		var previous_time: float = main.model.time
		main.camera_resolution.select(index)
		main.camera_resolution.item_selected.emit(index)
		check(main.world.sensor_viewport.size == size, "resolution selection resizes the actual render target")
		check(main.world.raw_sensor_viewport.size == size, "resolution selection also resizes the raw main view")
		check(main.model.session_id == camera_session and main.model.time == previous_time,
			"resolution change preserves session and simulation time")
		check(main.model.health == camera_health and main.model.stats == camera_stats,
			"resolution change preserves health and statistics")
		var camera: Dictionary = main.model.camera_observation()
		check(camera.width == size.x and camera.height == size.y,
			"camera metadata matches selected dimensions")
		check(is_equal_approx(camera.K[0], size.y * 0.5 / tan(deg_to_rad(main.model.settings.camera.vertical_fov * 0.5)))
			and camera.K[2] == size.x * 0.5 and camera.K[5] == size.y * 0.5,
			"intrinsics follow dimensions at fixed vertical FOV")
		var request_id = "ui_%d_%d" % [OS.get_process_id(), index]
		transport.ipc.write_json("request.json", {"publisher_id": transport.publisher_id, "request_id": request_id})
		stream.poll()
		await RenderingServer.frame_post_draw
		var metadata: Dictionary = transport.ipc.read_json("frame.json")
		check(metadata.get("request_id") == request_id, "camera publishes the requested shared frame")
		check(metadata.get("publisher_id") == transport.publisher_id and metadata.session_id == camera_session,
			"frame remains paired with its publisher and session")
		var bytes = FileAccess.get_file_as_bytes(transport.ipc.directory.path_join(metadata.frame_file))
		var channels = 4 if metadata.encoding == "rgba8" else 3
		check(bytes.size() == size.x * size.y * channels and metadata.image_bytes == bytes.size(),
			"actual raw bytes match selected dimensions and channel count")
		check(not metadata.has("truth") and metadata.camera.width == size.x and metadata.camera.height == size.y,
			"shared frame metadata matches the actual pixels without target truth")
		var image: Image = main.world.sensor_viewport.get_texture().get_image()
		check(image.get_size() == size, "rendered image has the requested dimensions")
		check(image.get_data() == bytes, "shared pixels equal the sensor render byte for byte")
	# Exercise the actual outgoing pixels while the scene is frozen, then restore the original gain.
	var was_paused: bool = main.model.paused
	main.model.paused = true
	var original_gain: float = main.model.settings.camera.brightness_gain
	var original_K: Array = main.model.camera_observation().K
	var output_levels: Array[float] = []
	var digit_peaks: Array[float] = []
	var lamp_peaks: Array[float] = []
	var environment: Environment = main.world.get_child(0).environment
	var original_background = environment.background_color
	var original_ambient = environment.ambient_light_energy
	var original_lamp_color: Color = main.world.plate_materials[0].albedo_color
	var original_main_pixels = PackedByteArray()
	for gain in [1.0, 0.5, 0.1, 0.0, 4.0, 1.0]:
		main.fields["camera.brightness_gain"].value = gain
		await process_frame
		var request_id = "gain_%d_%d" % [OS.get_process_id(), output_levels.size()]
		transport.ipc.write_json("request.json", {"publisher_id": transport.publisher_id, "request_id": request_id})
		stream.poll()
		await RenderingServer.frame_post_draw
		var metadata: Dictionary = transport.ipc.read_json("frame.json")
		check(metadata.get("request_id") == request_id
			and is_equal_approx(metadata.camera.brightness_gain, gain),
			"brightness metadata matches the sampled output gain")
		var image: Image = main.world.sensor_viewport.get_texture().get_image()
		var main_pixels: PackedByteArray = main.first_person_image.texture.get_image().get_data()
		if original_main_pixels.is_empty():
			original_main_pixels = main_pixels
		check(main_pixels == original_main_pixels, "exposure changes leave first-person pixels byte-for-byte unchanged")
		var bytes = FileAccess.get_file_as_bytes(transport.ipc.directory.path_join(metadata.frame_file))
		check(image.get_data() == bytes, "brightness preview and outgoing shared pixels match")
		var level = 0.0
		for y in range(0, image.get_height(), 16):
			for x in range(0, image.get_width(), 16):
				level += image.get_pixel(x, y).get_luminance()
		output_levels.append(level)
		var corners: Array = metadata.camera.armors[0].corners
		var top_left = Vector2(corners[0][0], corners[0][1])
		var bottom_right = Vector2(corners[2][0], corners[2][1])
		var bottom_left = Vector2(corners[3][0], corners[3][1])
		digit_peaks.append(region_peak(image, (top_left + bottom_right) * 0.5, Vector2i(8, 12)))
		lamp_peaks.append(region_peak(image, (top_left + bottom_left) * 0.5, Vector2i(3, 5)))
		if gain == 0.0:
			check(is_zero_approx(level), "zero gain makes the entire outgoing image black")
		check(main.model.camera_observation().K == original_K
			and main.model.session_id == camera_session and main.model.stats == camera_stats,
			"brightness edits preserve calibration, session and statistics")
	check(output_levels[0] > output_levels[1] and output_levels[1] > output_levels[2]
		and output_levels[2] > output_levels[3] and output_levels[4] > output_levels[0],
		"actual outgoing pixels darken below one and brighten above one")
	check(is_equal_approx(output_levels[0], output_levels[5]), "restoring unit gain restores the original image brightness")
	check(digit_peaks[2] < digit_peaks[0] * 0.6 and lamp_peaks[2] > 0.9,
		"low exposure darkens printed white while the LED core remains near saturation")
	check(environment.background_color == original_background
		and environment.ambient_light_energy == original_ambient
		and main.world.plate_materials[0].albedo_color == original_lamp_color,
		"camera exposure leaves environment lighting and scene lamp materials unchanged")
	main.model.health = 0
	main.world.update_world()
	check(main.world.brightness_material.get_shader_parameter("lamp_count") == 0,
		"dead target has no sensor emission signal")
	main.model.health = camera_health
	main.fields["camera.brightness_gain"].value = original_gain
	main.world.update_world()
	main.model.paused = was_paused
	await check_hit_flash(main, stream, transport)
	var ipc_directory: String = transport.ipc.directory
	stream.close()
	transport.close()
	check(not FileAccess.file_exists(ipc_directory.path_join("frame.json"))
		and DirAccess.get_files_at(ipc_directory).is_empty(), "closing publisher clears frame and mailbox files")
	check(DirAccess.remove_absolute(ipc_directory) == OK, "closing publisher releases its instance lock")
	if camera_only:
		if failures.is_empty():
			print("PASS CAMERA: %d checks" % checks)
		else:
			print("FAILED CAMERA: " + str(failures))
		quit(0 if failures.is_empty() else 1)
		return
	main.model.settings.ipc.channel = "default"
	main.camera_resolution.select(4)
	main.camera_resolution.item_selected.emit(4)
	for index in range(main.robot_select.item_count):
		main.robot_select.select(index)
		main.robot_select.item_selected.emit(index)
		main.team_select.select(index % 2)
		main.team_select.item_selected.emit(index % 2)
		await process_frame
		check(main.model.settings.appearance.robot == main.robot_select.get_item_metadata(index), "robot selection applies")
		check(main.world.plates.size() == 4, "all presets retain four armor modules")
		check(main.world.plates[0].get_child_count() > 0, "armor renders without a car body")
		var preset: Dictionary = Presets.ROBOTS[main.model.settings.appearance.robot]
		check(main.model.health == preset.max_health, "robot selection applies RMUL health")
		check(main.model.settings.target.module_width == preset.module_width, "robot selection applies physical module size")
		check(is_equal_approx(main.model.settings.target.armor_height, preset.height), "robot selection retains scoring height precision")
		check(is_equal_approx(Presets.extent(main.model.settings.target), 0.55), "all robot presets retain 550 mm rotation envelope")
		check(is_equal_approx(Presets.lower_edge(main.model.settings.target), 0.2), "switching size retains 200 mm lower edge")
		check_rendered_extent(main, 0.55)
		for plate in main.world.plates:
			var sticker = plate.get_node_or_null("ArmorSticker")
			check(sticker is Sprite3D and sticker.texture is AtlasTexture, "each armor uses an image sticker")
			if sticker != null:
				var source: Image = sticker.texture.atlas.get_image()
				var background = source.get_pixelv(Vector2i(preset.sticker_region.position))
				check(plate.get_child(0).material_override.albedo_color.is_equal_approx(background), "panel black matches source sticker")
	main.robot_select.select(0)
	main.robot_select.item_selected.emit(0)
	var spacing_session: String = main.model.session_id
	var spacing_time: float = main.model.time
	main.fields["target.radius"].value = 0.6
	check(Settings.validate(main.model.settings).is_empty(), "600 mm slider boundary applies")
	check_rendered_extent(main, 0.6)
	main.fields["target.radius"].value = 1.0
	check(is_equal_approx(Presets.extent(main.model.settings.target), 0.6), "outward drag clamps at 600 mm")
	main.fields["target.radius"].value = main.fields["target.radius"].min_value
	check(Settings.validate(main.model.settings).is_empty(), "inward drag clamps before overlap or obstruction")
	check(main.model.session_id == spacing_session and main.model.time == spacing_time, "spacing drag does not reset the round")
	main.fields["target.radius"].value = 0.55
	check(main.fields["target.center.z"] is HSlider and main.fields["target.height_difference"] is HSlider, "height and pair offset use sliders")
	main.fields["target.center.z"].value = 0.3
	main.fields["target.height_difference"].value = 0.1
	check(is_equal_approx(main.model.settings.target.height_difference, 0.1), "height offset slider applies immediately")
	check(Settings.validate(main.model.settings).is_empty(), "height sliders retain rule-compliant lower edges")
	main.fields["target.center.z"].value = 0.6
	check(Settings.validate(main.model.settings).is_empty(), "height slider clamps at coupled 400 mm limit")
	main.fields["target.height_difference"].value = -0.1
	main.fields["target.center.z"].value = 0.2
	main.team_select.select(1)
	main.team_select.item_selected.emit(1)
	var session: String = main.model.session_id
	var live_time: float = main.model.time
	main.fields["target.translate"].button_pressed = true
	main.fields["target.rotate"].button_pressed = true
	check(main.model.session_id == session and main.model.time == live_time, "parameter changes preserve session and simulation time")
	main.fields["target.speed"].get_line_edit().text = "2.5"
	main.fields["target.speed"].get_line_edit().text_changed.emit("2.5")
	await process_frame
	check(main.model.settings.target.translate and main.model.settings.target.rotate, "motion switches apply immediately")
	check(main.model.settings.target.speed == 2.5, "typed numeric value applies immediately")
	check(main.model.settings.appearance.team == "red", "red team applies")
	check(main.world.plate_materials[0].albedo_color == Presets.team_color("red"), "red team reaches materials")
	main._toggle_pause()
	var before: float = main.model.time
	await create_timer(0.08).timeout
	check(main.model.time == before, "pause freezes model while UI keeps running")
	main._toggle_pause()
	main.fields["target.translate"].button_pressed = false
	main.fields["target.rotate"].button_pressed = false
	send_key(KEY_F, true)
	await wait_sim(main, 0.7)
	check(main.tracking_held, "F acquires static armor before shooting")
	send_key(KEY_F, false)
	var edited: LineEdit = main.fields["target.speed"].get_line_edit()
	edited.edit()
	edited.grab_focus()
	edited.text = "2.5"
	edited.text_changed.emit("2.5")
	await process_frame
	check(root.gui_get_focus_owner() == edited, "numeric field retains focus after editing")
	send_key(KEY_SPACE, true)
	await process_frame
	check(root.gui_get_focus_owner() != edited, "Space commits and exits numeric edit")
	await wait_sim(main, 1.2)
	send_key(KEY_SPACE, false)
	await wait_sim(main, 0.5)
	check(main.model.stats.fired > 0, "Space input actually fires")
	check(main.model.stats.hit > 0, "held assist plus Space actually hits")
	check(main.model.metrics().in_flight == 0, "GUI fire settles projectiles")
	check(not main.world.ricochets.is_empty(), "impact creates a bouncing projectile visual")
	for effect in main.world.ricochets:
		var mat: StandardMaterial3D = effect.node.material_override
		check(mat.albedo_color == WorldView.PROJECTILE_COLOR and not mat.emission_enabled
			and mat.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED, "ricochet stays fluorescent green without white highlights")
	var settled: Dictionary = main.model.stats.duplicate()
	await wait_sim(main, 1.0)
	check(main.world.ricochets.is_empty() and main.world.bullets.is_empty(), "projectile visuals clear without fixed impact markers")
	check(main.model.stats == settled, "visual bounces never score a second hit or reset statistics")
	var health_before: int = main.model.health
	var fired_before: int = main.model.stats.fired
	main.fields["target.speed"].value = 3.0
	check(main.model.health == health_before and main.model.stats.fired == fired_before,
		"unrelated live setting does not heal target or clear statistics")
	main._toggle_view()
	check(not main.world.first_person and not main.main_reticle.visible, "third person camera toggle works")
	check(not root.disable_3d and not main.first_person_image.visible, "third person restores root 3D")
	main._toggle_view()
	check(main.world.first_person and main.main_reticle.visible, "return to first person works")
	check(root.disable_3d and main.first_person_image.visible, "returning reuses sensor rendering")
	await RenderingServer.frame_post_draw
	var capture = "/tmp/rm_aim_sim_verified.png"
	check(root.get_texture().get_image().save_png(capture) == OK, "GUI screenshot saves")
	var sensor_path = "/tmp/rm_aim_sim_sensor.png"
	check(main.world.sensor_viewport.get_texture().get_image().save_png(sensor_path) == OK, "sensor image readable")
	var observation = main.model.camera_observation()
	check(not observation.armors.is_empty(), "sensor keypoints remain visible after aiming")
	main.fields["target.max_health"].value = 20
	check(main.model.health == 20, "health field applies immediately")
	root.grab_focus()
	send_key(KEY_SPACE, true)
	await wait_sim(main, 1.2)
	send_key(KEY_SPACE, false)
	await wait_sim(main, 0.5)
	check(main.model.health == 0 and main.model.stats.kills == 1, "real GUI fire deducts health and kills")
	check(not main.world.plate_materials[0].emission_enabled, "death switches off armor emission")
	check(not main.world.lamp_glows[0].visible, "death also switches off optical glare")
	check(main.model.camera_observation().armors.is_empty(), "dead target has no ideal lightbar observations")
	main.fields["target.max_health"].value = 40
	check(main.model.health == 40 and main.world.plate_materials[0].emission_enabled, "live health edit restores lights")
	check(main.model.stats.fired > fired_before, "health edits preserve accumulated shots")
	main.fields["target.max_health"].value = 10000
	main.fields["target.translate"].button_pressed = true
	main.fields["target.rotate"].button_pressed = true
	send_key(KEY_F, true)
	var shots_before_tracking: int = main.model.stats.fired
	await wait_sim(main, 0.3)
	check(main.tracking_held and main.tracking_armor >= 0, "holding F enables continuous tracking")
	var first_goal: float = main.model.command.yaw
	var first_yaw: float = main.model.yaw
	await wait_sim(main, 0.5)
	check(absf(main.model.command.yaw - first_goal) > 0.005 and absf(main.model.yaw - first_yaw) > 0.005,
		"held F continuously updates command and actual gimbal on moving target")
	check(main.model.stats.fired == shots_before_tracking, "holding F alone does not fire")
	send_key(KEY_F, false)
	var last_goal: float = main.model.command.yaw
	await process_frame
	check(not main.tracking_held, "releasing F stops following")
	check(absf(wrapf(main.model.command.yaw - last_goal, -PI, PI)) < deg_to_rad(0.06), "F release preserves last aim angle")
	click_hold(main.aim_button, true)
	await wait_sim(main, 0.05)
	check(main.tracking_held, "held tracking button also follows continuously")
	click_hold(main.aim_button, false)
	main.bridge.enabled = true
	var remote_command: Dictionary = main.model.command.duplicate(true)
	main._local_command(1.0 / 240.0)
	check(main.model.command == remote_command and not main.tracking_held, "assist cannot overwrite external control")
	main.bridge.enabled = false
	print("GUI_STATS " + JSON.stringify(main.model.metrics()))
	print("GUI_SCREENSHOT " + capture)
	print("PASS: %d GUI checks" % checks if failures.is_empty() else "FAILED GUI: " + str(failures))
	main.queue_free()
	await process_frame
	quit(0 if failures.is_empty() else 1)
