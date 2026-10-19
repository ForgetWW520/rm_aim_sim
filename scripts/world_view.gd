extends Node3D

const Assets = preload("res://scripts/visual_assets.gd")
const Presets = preload("res://scripts/presets.gd")
const PROJECTILE_DIAMETER = 0.0168
const PROJECTILE_COLOR = Color("39ff14")
const RICOCHET_LIFETIME = 0.8

var model: RefCounted
var plates: Array[Node3D] = []
var gun: Node3D
var main_camera: Camera3D
var sensor_camera: Camera3D
var brightness_material: ShaderMaterial
var raw_sensor_viewport: SubViewport
var sensor_viewport: SubViewport
var bullets: Dictionary = {}
var bullet_root: Node3D
var trace_mesh: ImmediateMesh
var orbit_angle = 0.68
var orbit_elevation = 0.42
var orbit_distance = 8.0
var first_person = true
var plate_materials: Array[StandardMaterial3D] = []
var lamp_glows: Array[Node3D] = []
var ricochets: Array[Dictionary] = []
var seen_impacts: Dictionary = {}


static func to_engine(v: Vector3) -> Vector3:
	return Vector3(-v.y, v.z, -v.x)


func build(simulation: RefCounted) -> void:
	model = simulation
	var environment = WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color("111e30")
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color("b2c5e5")
	environment.environment.ambient_light_energy = 0.4
	environment.environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	add_child(environment)
	var sun = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48, -30, 0)
	sun.light_energy = 1.0
	sun.shadow_enabled = true
	add_child(sun)
	var fill = DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-25, 130, 0)
	fill.light_color = Color("7ec8ff")
	fill.light_energy = 0.3
	add_child(fill)
	var ground_material = material(Color("303030"))
	ground_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	box(self, Vector3(32, 0.04, 32), Vector3(0, -0.03, -5), ground_material)
	_build_grid()
	main_camera = Camera3D.new()
	main_camera.fov = 52.0
	main_camera.near = 0.03
	main_camera.far = 80.0
	add_child(main_camera)
	main_camera.current = true
	raw_sensor_viewport = SubViewport.new()
	raw_sensor_viewport.size = Vector2i(model.settings.camera.width, model.settings.camera.height)
	raw_sensor_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(raw_sensor_viewport)
	raw_sensor_viewport.world_3d = get_world_3d()
	sensor_camera = Camera3D.new()
	sensor_camera.fov = model.settings.camera.vertical_fov
	sensor_camera.near = 0.02
	sensor_camera.far = 80.0
	raw_sensor_viewport.add_child(sensor_camera)
	sensor_camera.current = true
	# Render 3D once; keep the raw main view separate from the exposure-processed output.
	sensor_viewport = SubViewport.new()
	sensor_viewport.size = raw_sensor_viewport.size
	sensor_viewport.disable_3d = true
	sensor_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(sensor_viewport)
	var brightness_layer = CanvasLayer.new()
	sensor_viewport.add_child(brightness_layer)
	var brightness_rect = ColorRect.new()
	brightness_layer.add_child(brightness_rect)
	brightness_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	brightness_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	brightness_material = ShaderMaterial.new()
	brightness_material.shader = preload("res://shaders/camera_brightness.gdshader")
	brightness_material.set_shader_parameter("camera_texture", raw_sensor_viewport.get_texture())
	brightness_material.set_shader_parameter("brightness_gain", model.settings.camera.brightness_gain)
	brightness_rect.material = brightness_material
	gun = Node3D.new()
	add_child(gun)
	var metal = material(Color("71838d"), 0.75)
	box(gun, Vector3(0.12, 0.11, model.settings.gimbal.barrel_length),
		Vector3(0, 0, -model.settings.gimbal.barrel_length * 0.5), metal)
	box(gun, Vector3(0.08, 0.07, 0.055), Vector3(0, 0.04, -0.08), material(Color("58ded4"), 0, 0.8))
	var base_position = to_engine(model.settings.gimbal.origin)
	box(self, Vector3(0.34, 0.12, 0.34), base_position - Vector3(0, 0.16, 0), metal)
	box(self, Vector3(0.09, base_position.y - 0.2, 0.09),
		Vector3(base_position.x, (base_position.y - 0.2) * 0.5, base_position.z), metal)
	bullet_root = Node3D.new()
	add_child(bullet_root)
	trace_mesh = ImmediateMesh.new()
	var traces = MeshInstance3D.new()
	traces.mesh = trace_mesh
	traces.material_override = _projectile_material()
	add_child(traces)
	rebuild_target()
	update_world()


func rebuild_target() -> void:
	for plate in plates:
		plate.free()
	plates.clear()
	plate_materials.clear()
	lamp_glows.clear()
	for bullet in bullets.values():
		bullet.free()
	bullets.clear()
	for effect in ricochets:
		effect.node.free()
	ricochets.clear()
	seen_impacts.clear()
	for i in range(4):
		var lamp_material = material(Presets.team_color(model.settings.appearance.team), 0.0, 1.1)
		lamp_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		plate_materials.append(lamp_material)
		var plate = Node3D.new()
		add_child(plate)
		plates.append(plate)
		var custom = Assets.load_model(model.settings.appearance.armor_model)
		if custom != null:
			plate.add_child(Assets.fit_model(custom, model.settings.target.module_width,
				model.settings.appearance.armor_scale, true))
			Assets.tint_named_surfaces(custom, lamp_material)
		else:
			_build_armor(plate, lamp_material)
	sensor_viewport.size = Vector2i(model.settings.camera.width, model.settings.camera.height)
	raw_sensor_viewport.size = sensor_viewport.size
	sensor_camera.fov = model.settings.camera.vertical_fov
	_update_lights()


func _build_armor(plate: Node3D, lamp_material: StandardMaterial3D) -> void:
	var height: float = model.settings.target.module_height
	var preset: Dictionary = Presets.ROBOTS[model.settings.appearance.robot]
	# Runtime loading keeps the sticker replaceable without an editor import cache.
	var image = Image.load_from_file(preset.sticker)
	var background = Color.BLACK
	if image != null:
		# The crop's corner is black; sample it so the panel and texture have the same unlit color.
		background = image.get_pixelv(Vector2i(preset.sticker_region.position))
	var face_material = material(background)
	face_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	for part in Presets.module_boxes(model.settings.target):
		if part.light:
			box(plate, part.size, part.position, lamp_material)
		else:
			_armor_shell(plate, part.size, part.position, face_material)
	_add_lamp_glow(plate)
	if image != null:
		var texture = AtlasTexture.new()
		texture.atlas = ImageTexture.create_from_image(image)
		texture.region = preset.sticker_region
		var sticker = Sprite3D.new()
		sticker.name = "ArmorSticker"
		sticker.texture = texture
		sticker.pixel_size = minf(model.settings.target.lightbar_spacing * 0.72 / texture.get_width(),
			height * 0.8 / texture.get_height())
		sticker.position.z = 0.006
		sticker.double_sided = false
		plate.add_child(sticker)
		return
	push_warning("Missing armor sticker for " + model.settings.appearance.robot)


func _armor_shell(parent: Node3D, size: Vector3, origin: Vector3, mat: Material) -> void:
	var x = size.x * 0.5
	var y = size.y * 0.5
	var bevel = minf(size.x, size.y) * 0.035
	var notch = minf(size.x * 0.045, 0.006)
	var shoulder = model.settings.target.lightbar_length * 0.65
	var outline = PackedVector2Array([Vector2(-x + bevel, y), Vector2(x - bevel, y),
		Vector2(x, y - bevel), Vector2(x, shoulder + notch), Vector2(x - notch, shoulder),
		Vector2(x - notch, -shoulder), Vector2(x, -shoulder - notch), Vector2(x, -y + bevel),
		Vector2(x - bevel, -y), Vector2(-x + bevel, -y), Vector2(-x, -y + bevel),
		Vector2(-x, -shoulder - notch), Vector2(-x + notch, -shoulder),
		Vector2(-x + notch, shoulder), Vector2(-x, shoulder + notch), Vector2(-x, y - bevel)])
	var surface = SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var triangles = Geometry2D.triangulate_polygon(outline)
	for face in [-1.0, 1.0]:
		for index in range(0, triangles.size(), 3):
			for corner in ([0, 1, 2] if face > 0 else [2, 1, 0]):
				var point = outline[triangles[index + corner]]
				surface.add_vertex(Vector3(point.x, point.y, size.z * 0.5 * face))
	for index in range(outline.size()):
		var a = outline[index]
		var b = outline[(index + 1) % outline.size()]
		for point in [Vector3(a.x, a.y, -size.z * 0.5), Vector3(b.x, b.y, -size.z * 0.5),
				Vector3(b.x, b.y, size.z * 0.5), Vector3(a.x, a.y, -size.z * 0.5),
				Vector3(b.x, b.y, size.z * 0.5), Vector3(a.x, a.y, size.z * 0.5)]:
			surface.add_vertex(point)
	surface.generate_normals()
	var node = MeshInstance3D.new()
	node.mesh = surface.commit()
	node.material_override = mat
	node.position = origin
	parent.add_child(node)


func _add_lamp_glow(plate: Node3D) -> void:
	# Glare is optical, outside the physical collision/envelope geometry.
	var group = Node3D.new()
	group.name = "LampGlare"
	plate.add_child(group)
	lamp_glows.append(group)
	for sign_value in [-1.0, 1.0]:
		var node = MeshInstance3D.new()
		var mesh = QuadMesh.new()
		mesh.size = Vector2(0.025, model.settings.target.lightbar_length + 0.02)
		var glow = ShaderMaterial.new()
		glow.shader = preload("res://shaders/lamp_glow.gdshader")
		glow.set_shader_parameter("team_color", Presets.team_color(model.settings.appearance.team))
		glow.set_shader_parameter("core_color",
			Color("fff0dc") if model.settings.appearance.team == "red" else Color("dcfaff"))
		glow.set_shader_parameter("lamp_length", model.settings.target.lightbar_length)
		glow.set_shader_parameter("plane_size", mesh.size)
		node.mesh = mesh
		node.material_override = glow
		node.position = Vector3(sign_value * model.settings.target.lightbar_spacing * 0.5, 0, 0.0112)
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		group.add_child(node)


func _update_lights() -> void:
	for index in range(plates.size()):
		var lit: bool = model.armor_light_on(index)
		var lamp_material = plate_materials[index]
		if lamp_material.emission_enabled != lit:
			lamp_material.albedo_color = Presets.team_color(model.settings.appearance.team) if lit else Color("14191f")
			lamp_material.emission_enabled = lit
		var glow = plates[index].get_node_or_null("LampGlare")
		if glow != null:
			glow.visible = lit


func update_world() -> void:
	_update_lights()
	sensor_viewport.size = Vector2i(model.settings.camera.width, model.settings.camera.height)
	raw_sensor_viewport.size = sensor_viewport.size
	sensor_camera.fov = model.settings.camera.vertical_fov
	var pose = model.target_pose(model.time)
	for i in range(4):
		var a = model.armor_pose(i, model.time)
		plates[i].transform = Transform3D(Basis(to_engine(a.tangent), to_engine(a.up), to_engine(a.normal)), to_engine(a.center))
	var camera = model.camera_pose()
	var direction = to_engine(model.forward(model.yaw, model.pitch))
	gun.position = to_engine(model.settings.gimbal.origin)
	gun.look_at(gun.position + direction, to_engine(camera.up))
	sensor_camera.position = to_engine(camera.origin)
	sensor_camera.look_at(sensor_camera.position + to_engine(camera.forward), to_engine(camera.up))
	_update_camera_exposure()
	if first_person:
		main_camera.transform = sensor_camera.transform
		main_camera.fov = sensor_camera.fov
	else:
		main_camera.fov = 52.0
		var focus = to_engine(pose.center) * 0.55 + Vector3(0, 0.25, 0)
		var offset = Vector3(sin(orbit_angle) * cos(orbit_elevation), sin(orbit_elevation), cos(orbit_angle) * cos(orbit_elevation))
		main_camera.position = focus + offset * orbit_distance
		main_camera.look_at(focus)
	_update_bullets()


func _update_camera_exposure() -> void:
	var segments = PackedVector4Array()
	var widths = PackedFloat32Array()
	segments.resize(8)
	widths.resize(8)
	var count = 0
	var camera_origin: Vector3 = model.camera_pose().origin
	if model.health > 0:
		for index in range(4):
			# The sensor's reconstructed LED signal must follow the same hit/death state as the mesh.
			if not model.armor_light_on(index):
				continue
			var armor = model.armor_pose(index, model.time)
			if (camera_origin - armor.center).dot(armor.normal) <= 0.0:
				continue
			for side in [-1.0, 1.0]:
				var center: Vector3 = armor.center + armor.tangent * side * model.settings.target.lightbar_spacing * 0.5
				center += armor.normal * 0.0112
				var top = to_engine(center + armor.up * model.settings.target.lightbar_length * 0.5)
				var bottom = to_engine(center - armor.up * model.settings.target.lightbar_length * 0.5)
				if sensor_camera.is_position_behind(top) or sensor_camera.is_position_behind(bottom):
					continue
				var start = sensor_camera.unproject_position(top)
				var end = sensor_camera.unproject_position(bottom)
				var left = sensor_camera.unproject_position(to_engine(center - armor.tangent * 0.0025))
				var right = sensor_camera.unproject_position(to_engine(center + armor.tangent * 0.0025))
				segments[count] = Vector4(start.x, start.y, end.x, end.y)
				widths[count] = left.distance_to(right)
				count += 1
	brightness_material.set_shader_parameter("brightness_gain", model.settings.camera.brightness_gain)
	brightness_material.set_shader_parameter("lamp_count", count)
	brightness_material.set_shader_parameter("lamp_segments", segments)
	brightness_material.set_shader_parameter("lamp_widths", widths)
	brightness_material.set_shader_parameter("lamp_color", Presets.team_color(model.settings.appearance.team))
	brightness_material.set_shader_parameter("core_color",
		Color("fff0dc") if model.settings.appearance.team == "red" else Color("dcfaff"))


func _update_bullets() -> void:
	var live: Dictionary = {}
	trace_mesh.clear_surfaces()
	if not model.projectiles.is_empty():
		trace_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for bullet in model.projectiles:
		live[bullet.id] = true
		if not bullets.has(bullet.id):
			var node = _projectile_visual()
			bullet_root.add_child(node)
			bullets[bullet.id] = node
		var point: Vector3 = model.bullet_position(bullet, model.time)
		bullets[bullet.id].position = to_engine(point)
		trace_mesh.surface_add_vertex(to_engine(model.bullet_position(bullet, maxf(bullet.born, model.time - 0.018))))
		trace_mesh.surface_add_vertex(to_engine(point))
	if not model.projectiles.is_empty():
		trace_mesh.surface_end()
	for id in bullets.keys():
		if not live.has(id):
			bullets[id].queue_free()
			bullets.erase(id)
	_update_ricochets()


func _projectile_visual() -> MeshInstance3D:
	var node = MeshInstance3D.new()
	var mesh = SphereMesh.new()
	mesh.radius = PROJECTILE_DIAMETER * 0.5
	mesh.height = PROJECTILE_DIAMETER
	mesh.radial_segments = 8
	mesh.rings = 4
	node.mesh = mesh
	node.material_override = _projectile_material()
	return node


func _projectile_material() -> StandardMaterial3D:
	var result = material(PROJECTILE_COLOR)
	result.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return result


func _update_ricochets() -> void:
	var recent: Dictionary = {}
	for impact in model.impacts:
		recent[impact.id] = true
		if seen_impacts.has(impact.id) or impact.kind == "expired" \
				or model.time - impact.time >= RICOCHET_LIFETIME:
			continue
		var normal: Vector3 = impact.get("normal", Vector3(0, 0, 1))
		var incoming: Vector3 = impact.velocity
		var outgoing = (incoming - 2.0 * normal * incoming.dot(normal)) * 0.45
		var node = _projectile_visual()
		bullet_root.add_child(node)
		ricochets.append({"node": node, "born": impact.time, "updated": impact.time,
			"point": impact.point + normal * PROJECTILE_DIAMETER * 0.6, "velocity": outgoing})
	seen_impacts = recent
	for index in range(ricochets.size() - 1, -1, -1):
		var effect = ricochets[index]
		if model.time - effect.born >= RICOCHET_LIFETIME:
			effect.node.queue_free()
			ricochets.remove_at(index)
			continue
		var remaining: float = model.time - effect.updated
		while remaining > 1e-8:
			var dt = minf(remaining, 1.0 / 120.0)
			effect.point += effect.velocity * dt + Vector3(0, 0, -0.5 * model.settings.weapon.gravity * dt * dt)
			effect.velocity.z -= model.settings.weapon.gravity * dt
			if effect.point.z < PROJECTILE_DIAMETER * 0.5:
				effect.point.z = PROJECTILE_DIAMETER * 0.5
				effect.velocity = Vector3(effect.velocity.x * 0.65, effect.velocity.y * 0.65, absf(effect.velocity.z) * 0.4)
			remaining -= dt
		effect.updated = model.time
		effect.node.position = to_engine(effect.point)


func _build_grid() -> void:
	var mesh = ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for i in range(-15, 16):
		mesh.surface_add_vertex(Vector3(i, 0.001, -20))
		mesh.surface_add_vertex(Vector3(i, 0.001, 10))
		mesh.surface_add_vertex(Vector3(-15, 0.001, i - 5))
		mesh.surface_add_vertex(Vector3(15, 0.001, i - 5))
	mesh.surface_end()
	var node = MeshInstance3D.new()
	node.mesh = mesh
	node.material_override = material(Color("294455"), 0, 0.15)
	add_child(node)
	for distance in [2, 4, 6, 8, 10]:
		var label = Label3D.new()
		label.text = "%d m" % distance
		label.position = Vector3(1.0, 0.01, -distance)
		label.rotation_degrees.x = -90
		label.font_size = 40
		label.pixel_size = 0.008
		label.modulate = Color("709299")
		label.outline_size = 0
		add_child(label)


static func material(color: Color, metallic: float = 0.0, glow: float = 0.0) -> StandardMaterial3D:
	var result = StandardMaterial3D.new()
	result.albedo_color = color
	result.metallic = metallic
	result.roughness = 0.65
	if glow > 0.0:
		result.emission_enabled = true
		result.emission = color
		result.emission_energy_multiplier = glow
	return result


static func box(parent: Node3D, size: Vector3, position_value: Vector3, mat: Material) -> MeshInstance3D:
	var node = MeshInstance3D.new()
	var mesh = BoxMesh.new()
	mesh.size = size
	node.mesh = mesh
	node.position = position_value
	node.material_override = mat
	parent.add_child(node)
	return node
