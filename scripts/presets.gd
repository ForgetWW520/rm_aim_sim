extends RefCounted

const DEFAULT_EXTENT = 0.550
const MAX_EXTENT = 0.600
const DEFAULT_LOWER_EDGE = 0.200

const ROBOTS = {
	"infantry_3": {"label": "步兵 3", "number": "3", "width": 0.135, "height": 0.125,
		"module_width": 0.140, "module_height": 0.125, "max_health": 350,
		"sticker": "res://assets/stickers/infantry_3.png", "sticker_region": Rect2(110, 30, 330, 440)},
	"infantry_4": {"label": "步兵 4", "number": "4", "width": 0.135, "height": 0.125,
		"module_width": 0.140, "module_height": 0.125, "max_health": 350,
		"sticker": "res://assets/stickers/infantry_4.png", "sticker_region": Rect2(110, 30, 335, 445)},
	"infantry_5": {"label": "步兵 5", "number": "5", "width": 0.135, "height": 0.125,
		"module_width": 0.140, "module_height": 0.125, "max_health": 350,
		"sticker": "res://assets/stickers/infantry_5.png", "sticker_region": Rect2(110, 30, 330, 445)},
	"hero": {"label": "英雄 1", "number": "1", "width": 0.23, "height": 0.127,
		"module_width": 0.235, "module_height": 0.127, "max_health": 350,
		"sticker": "res://assets/stickers/hero.png", "sticker_region": Rect2(220, 45, 360, 370)},
	"sentry": {"label": "哨兵 7", "number": "7", "width": 0.135, "height": 0.125,
		"module_width": 0.140, "module_height": 0.125, "max_health": 400,
		"sticker": "res://assets/stickers/sentry.png", "sticker_region": Rect2(110, 85, 400, 375)},
}


static func apply_robot(settings: Dictionary, robot: String) -> void:
	var lower = lower_edge(settings.target)
	settings.appearance.robot = robot
	settings.target.armor_width = ROBOTS[robot].width
	settings.target.armor_height = ROBOTS[robot].height
	settings.target.module_width = ROBOTS[robot].module_width
	settings.target.module_height = ROBOTS[robot].module_height
	settings.target.max_health = ROBOTS[robot].max_health
	settings.target.lightbar_spacing = ROBOTS[robot].width
	settings.target.center.z = lower + vertical_half_height(settings.target)
	settings.target.radius = radius_for_extent(DEFAULT_EXTENT, settings.target)


static func vertical_half_height(target: Dictionary) -> float:
	return target.module_height * absf(cos(target.armor_tilt)) * 0.5


static func lower_edge(target: Dictionary) -> float:
	return target.center.z - vertical_half_height(target)


static func module_boxes(target: Dictionary) -> Array[Dictionary]:
	var width: float = target.module_width - 0.005
	var height: float = target.module_height
	var parts: Array[Dictionary] = [
		{"size": Vector3(width, height, 0.018), "position": Vector3(0, 0, -0.012), "light": false},
		{"size": Vector3(width - 0.004, height - 0.004, 0.004), "position": Vector3(0, 0, 0.001), "light": false},
	]
	for side in [-1, 1]:
		parts.append({"size": Vector3(0.005, target.lightbar_length, 0.008),
			"position": Vector3(side * target.lightbar_spacing * 0.5, 0, 0.007), "light": true})
	return parts


static func _outline(target: Dictionary) -> Array[Vector3]:
	var vertices: Array[Vector3] = []
	var sine = sin(target.armor_tilt)
	var cosine = cos(target.armor_tilt)
	for part in module_boxes(target):
		for x in [-1, 1]:
			for y in [-1, 1]:
				for z in [-1, 1]:
					var point: Vector3 = part.position + part.size * Vector3(x, y, z) * 0.5
					vertices.append(Vector3(-point.y * sine + point.z * cosine,
						point.x, point.y * cosine + point.z * sine))
	return vertices


static func extent(target: Dictionary) -> float:
	var outer = 0.0
	for point in _outline(target):
		var radial: float = target.radius + point.x
		outer = maxf(outer, sqrt(radial * radial + point.y * point.y))
	return outer * 2.0


static func radius_for_extent(diameter: float, target: Dictionary) -> float:
	var radius = INF
	for point in _outline(target):
		var squared = diameter * diameter * 0.25 - point.y * point.y
		if squared < 0.0:
			return -1.0
		radius = minf(radius, sqrt(squared) - point.x)
	return radius


static func minimum_radius(target: Dictionary) -> float:
	var inward = 0.0
	var tangent = 0.0
	var facing = 0.0
	var sine = sin(target.armor_tilt)
	var cosine = cos(target.armor_tilt)
	for point in _outline(target):
		inward = minf(inward, point.x)
		tangent = maxf(tangent, absf(point.y))
		facing = maxf(facing, absf(point.y) * cosine + point.z * sine)
	# Keep adjacent modules disjoint and behind each other's front planes, including the height offset.
	var visible = (facing + absf(target.height_difference * sine) + 0.001) / cosine
	return maxf(tangent - inward + 0.001, visible)


static func team_color(team: String) -> Color:
	return Color("ff1000") if team == "red" else Color("0028ff")
