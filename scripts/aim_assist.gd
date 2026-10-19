extends RefCounted


# A local ground-truth helper for exercising the simulator before an external aimer is connected.
static func solve(model: RefCounted, predict: bool = true) -> Dictionary:
	if model.health <= 0:
		return {}
	var best: Dictionary = {}
	var closest = INF
	for index in range(4):
		var candidate = _candidate(model, index, model.time, predict)
		if not candidate.is_empty() and candidate.distance < closest:
			closest = candidate.distance
			best = candidate
	if best.is_empty():
		return {}
	best.yaw_vel = 0.0
	best.pitch_vel = 0.0
	if predict:
		# Follow the same plate when differentiating; switching plates must not create a velocity spike.
		var delta = 1.0 / 240.0
		var following = _candidate(model, best.armor_id, model.time + delta, true)
		if not following.is_empty():
			var limit: float = model.settings.gimbal.max_speed
			best.yaw_vel = clampf(wrapf(following.yaw - best.yaw, -PI, PI) / delta, -limit, limit)
			best.pitch_vel = clampf((following.pitch - best.pitch) / delta, -limit, limit)
	return best


static func _candidate(model: RefCounted, index: int, at: float, predict: bool) -> Dictionary:
	var origin: Vector3 = model.settings.gimbal.origin
	var armor: Dictionary = model.armor_pose(index, at)
	var flight = armor.center.distance_to(origin) / model.settings.weapon.speed
	var result: Dictionary = {}
	for _iteration in range(12):
		# Commands keep updating during the launch delay; predict flight from the current muzzle pose.
		armor = model.armor_pose(index, at + (flight if predict else 0.0))
		result = _ballistic(model.settings, armor.center - origin)
		if result.is_empty():
			return {}
		var change = absf(result.flight_time - flight)
		flight = result.flight_time
		if change < 1e-7:
			break
	if (origin - armor.center).normalized().dot(armor.normal) <= 0.2:
		return {}
	if result.pitch < model.settings.gimbal.pitch_min or result.pitch > model.settings.gimbal.pitch_max \
			or flight > model.settings.weapon.lifetime:
		return {}
	result.armor_id = index
	result.distance = armor.center.distance_squared_to(origin)
	return result


static func _ballistic(settings: Dictionary, delta: Vector3) -> Dictionary:
	var horizontal = Vector2(delta.x, delta.y).length()
	var elevation = atan2(delta.z, horizontal)
	var speed: float = settings.weapon.speed
	var gravity: float = settings.weapon.gravity
	for _iteration in range(8):
		var distance = horizontal - settings.gimbal.barrel_length * cos(elevation)
		var height = delta.z - settings.gimbal.barrel_length * sin(elevation)
		if distance <= 0.0:
			return {}
		if gravity < 1e-9:
			elevation = atan2(height, distance)
		else:
			var discriminant = pow(speed, 4) - gravity * (gravity * distance * distance + 2.0 * height * speed * speed)
			if discriminant < 0.0:
				return {}
			elevation = atan((speed * speed - sqrt(discriminant)) / (gravity * distance))
	var flight = (horizontal - settings.gimbal.barrel_length * cos(elevation)) / (speed * cos(elevation))
	return {"yaw": atan2(delta.y, delta.x), "pitch": -elevation, "flight_time": flight}
