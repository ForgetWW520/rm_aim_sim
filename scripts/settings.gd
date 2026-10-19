extends RefCounted

const Presets = preload("res://scripts/presets.gd")

static func defaults() -> Dictionary:
	var result = {
		"appearance": {"robot": "infantry_3", "team": "blue", "body_model": "",
			"armor_model": "", "body_scale": 1.0, "armor_scale": 1.0},
		"target": {"center": Vector3(4, 0, 0), "translate": false, "speed": 1.0,
			"acceleration": 3.0,
			"heading": PI / 2.0, "travel": 1.5, "rotate": false, "omega": 4.0,
			"phase": PI, "radius": 0.0, "height_difference": -0.1,
			"armor_width": 0.135, "armor_height": 0.125, "armor_tilt": PI / 12.0,
			"lightbar_spacing": 0.135, "lightbar_length": 0.056,
			"module_width": 0.140, "module_height": 0.125, "max_health": -1},
		"gimbal": {"origin": Vector3(0, 0, 0.65), "barrel_length": 0.22,
			"max_speed": 6.0, "max_acceleration": 50.0, "response_hz": 6.0,
			"pitch_min": -PI / 6.0, "pitch_max": PI / 9.0},
		"weapon": {"speed": 23.0, "rate": 10.0, "delay": 0.015,
			"gravity": 9.7833, "lifetime": 3.0, "damage": 20},
		"camera": {"width": 1440, "height": 1080, "vertical_fov": 45.0,
			"brightness_gain": 0.4,
			"offset": Vector3(0.08, 0, 0.04)},
		"ipc": {"channel": "default",
			"state_hz": 60.0, "timeout": 0.25},
	}
	result.target.center.z = Presets.DEFAULT_LOWER_EDGE + Presets.vertical_half_height(result.target)
	result.target.radius = Presets.radius_for_extent(Presets.DEFAULT_EXTENT, result.target)
	return result


static func load_file(path: String) -> Dictionary:
	var config = ConfigFile.new()
	var err = config.load(path)
	if err != OK:
		return {"ok": false, "error": "Cannot load %s (error %d)" % [path, err]}
	var result = defaults()
	for section in config.get_sections():
		if not result.has(section):
			return {"ok": false, "error": "Unknown section: " + section}
		for key in config.get_section_keys(section):
			if not result[section].has(key):
				return {"ok": false, "error": "Unknown setting: %s.%s" % [section, key]}
			result[section][key] = config.get_value(section, key)
	var robot = result.appearance.robot
	if robot is String and Presets.ROBOTS.has(robot):
		var preset: Dictionary = Presets.ROBOTS[robot]
		var dimensions = {"armor_width": preset.width, "armor_height": preset.height,
			"module_width": preset.module_width, "module_height": preset.module_height,
			"lightbar_spacing": preset.width}
		for key in dimensions:
			if not config.has_section_key("target", key):
				result.target[key] = dimensions[key]
	var type_error = _validate_types(result)
	if not type_error.is_empty():
		return {"ok": false, "error": type_error, "settings": result}
	if not config.has_section_key("target", "radius"):
		result.target.radius = Presets.radius_for_extent(Presets.DEFAULT_EXTENT, result.target)
	if not config.has_section_key("target", "center"):
		result.target.center.z = Presets.DEFAULT_LOWER_EDGE + Presets.vertical_half_height(result.target)
	var error = validate(result)
	return {"ok": error.is_empty(), "error": error, "settings": result}


static func _validate_types(s: Dictionary) -> String:
	var base = defaults()
	for section in base:
		if not s.has(section) or not s[section] is Dictionary:
			return "Missing section: " + section
		for key in base[section]:
			if not s[section].has(key):
				return "Missing setting: %s.%s" % [section, key]
			var value = s[section][key]
			var expected = base[section][key]
			if expected is String:
				if not value is String:
					return "%s.%s must be text" % [section, key]
			elif expected is bool:
				if not value is bool:
					return "%s.%s must be boolean" % [section, key]
			elif expected is Vector3:
				if not value is Vector3 or not value.is_finite():
					return "%s.%s must be a finite Vector3" % [section, key]
			else:
				if not (value is float or value is int) or not is_finite(float(value)):
					return "%s.%s must be finite numeric" % [section, key]
	return ""


static func validate(s: Dictionary) -> String:
	var type_error = _validate_types(s)
	if not type_error.is_empty():
		return type_error
	var bounds = {
		"appearance.body_scale": [0.001, 1000.0], "appearance.armor_scale": [0.001, 1000.0],
		"target.speed": [0.0, 10.0], "target.acceleration": [0.1, 50.0],
		"target.travel": [0.1, 10.0],
		"target.omega": [-25.0, 25.0], "target.radius": [0.001, 0.3],
		"target.height_difference": [-0.1, 0.1],
		"target.armor_width": [0.05, 0.3], "target.armor_height": [0.04, 0.3],
		"target.module_width": [0.05, 0.3], "target.module_height": [0.04, 0.3],
		"target.max_health": [-1, 10000], "weapon.damage": [0, 10000],
		"target.armor_tilt": [-PI / 4.0, PI / 4.0],
		"target.lightbar_spacing": [0.05, 0.3], "target.lightbar_length": [0.02, 0.15],
		"gimbal.barrel_length": [0.0, 0.5], "gimbal.max_speed": [0.1, 20.0],
		"gimbal.max_acceleration": [0.1, 500.0], "gimbal.response_hz": [0.1, 30.0],
		"gimbal.pitch_min": [-PI / 2.0 + 0.01, 0.0],
		"gimbal.pitch_max": [0.0, PI / 2.0 - 0.01],
		"weapon.speed": [1.0, 100.0], "weapon.rate": [0.1, 50.0],
		"weapon.delay": [0.0, 1.0], "weapon.gravity": [0.0, 20.0],
		"weapon.lifetime": [0.1, 10.0], "camera.width": [160, 3840],
		"camera.height": [120, 2160], "camera.vertical_fov": [10.0, 120.0],
		"camera.brightness_gain": [0.0, 4.0],
		"ipc.state_hz": [1.0, 240.0], "ipc.timeout": [0.05, 2.0],
	}
	for name in bounds:
		var parts = name.split(".")
		var value = float(s[parts[0]][parts[1]])
		if value < bounds[name][0] or value > bounds[name][1]:
			return "%s must be in [%s, %s]" % [name, bounds[name][0], bounds[name][1]]
	for name in ["camera.width", "camera.height",
			"target.max_health", "weapon.damage"]:
		var parts = name.split(".")
		if float(s[parts[0]][parts[1]]) != floor(float(s[parts[0]][parts[1]])):
			return name + " must be an integer"
	if not preload("res://scripts/local_ipc.gd").valid_name(s.ipc.channel):
		return "IPC channel must contain 1-80 letters, digits, underscores or hyphens"
	if s.gimbal.pitch_min >= s.gimbal.pitch_max:
		return "Pitch minimum must be below maximum"
	var half_vertical = s.target.module_height * absf(cos(s.target.armor_tilt)) * 0.5
	var lower_edge = s.target.center.z - half_vertical
	var other_edge = lower_edge + s.target.height_difference
	# Vector3 positions use engine precision; tolerate rounding at the 400 mm slider boundary.
	if minf(lower_edge, other_edge) <= 0.0 or maxf(lower_edge, other_edge) > 0.4 + 1e-7:
		return "Armor lower edges must be above ground and no higher than 400 mm (2026 S155)"
	if s.gimbal.origin.z < 0.3 or s.gimbal.origin.z > 3.0:
		return "Gimbal height must be in [0.3, 3] m"
	if s.target.center.length() > 25.0 or s.gimbal.origin.length() > 25.0:
		return "Initial positions must be within 25 m of world origin"
	if absf(s.target.heading) > TAU * 10.0 or absf(s.target.phase) > TAU * 10.0:
		return "Target angles are out of range"
	if s.camera.offset.length() > 0.5:
		return "Camera offset must be within 0.5 m"
	if not s.appearance.robot in ["infantry_3", "infantry_4", "infantry_5", "hero", "sentry"]:
		return "Unknown robot preset"
	if not s.appearance.team in ["red", "blue"]:
		return "Team must be red or blue"
	if s.target.radius < Presets.minimum_radius(s.target) - 1e-9:
		return "Armor spacing is too small: modules would overlap or obstruct adjacent armor"
	if Presets.extent(s.target) > Presets.MAX_EXTENT + 1e-9:
		return "Armor rotation envelope must not exceed 600 mm"
	return ""


static func save_file(s: Dictionary, path: String) -> Error:
	var config = ConfigFile.new()
	for section in s:
		for key in s[section]:
			config.set_value(section, key, s[section][key])
	return config.save(path)
