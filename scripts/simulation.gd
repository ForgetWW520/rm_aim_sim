extends RefCounted

const Settings = preload("res://scripts/settings.gd")
const Presets = preload("res://scripts/presets.gd")
const MAX_COLLISION_DT = 0.001
const MAX_PROJECTILES = 512
const HIT_FLASH_DURATION = 0.05

var settings: Dictionary
var time = 0.0
var tick = 0
var session_id = ""
var paused = false
var yaw = 0.0
var pitch = 0.0
var yaw_velocity = 0.0
var pitch_velocity = 0.0
var command: Dictionary = {}
var projectiles: Array[Dictionary] = []
var pending: Array[float] = []
var events: Array[Dictionary] = []
var impacts: Array[Dictionary] = []
var stats: Dictionary
var next_trigger = 0.0
var next_shot_id = 0
var first_hit_time = -1.0
var max_health = 0
var health = 0
var death_time = -1.0
var next_health_event_id = 0
var armor_light_off_until: Array[float] = []
var translation_origin = Vector3.ZERO
var translation_epoch = 0.0
var translation_start_offset = 0.0
var translation_direction = 1.0
var rotation_origin = 0.0
var rotation_epoch = 0.0
var motion_stop_time = -1.0


func _init(initial: Dictionary = {}) -> void:
	reset(initial if not initial.is_empty() else Settings.defaults())


func reset(initial: Dictionary = {}) -> void:
	if not initial.is_empty():
		settings = initial.duplicate(true)
	time = 0.0
	tick = 0
	session_id = "%d-%d" % [Time.get_ticks_usec(), randi()]
	paused = false
	yaw = 0.0
	pitch = 0.0
	yaw_velocity = 0.0
	pitch_velocity = 0.0
	command = {"control": false, "fire": false, "yaw": 0.0, "pitch": 0.0,
		"yaw_vel": 0.0, "pitch_vel": 0.0, "yaw_acc": 0.0, "pitch_acc": 0.0}
	projectiles.clear()
	pending.clear()
	events.clear()
	impacts.clear()
	stats = {"fired": 0, "hit": 0, "body": 0, "ground": 0, "expired": 0,
		"damage": 0, "kills": 0}
	next_trigger = 0.0
	next_shot_id = 0
	first_hit_time = -1.0
	max_health = _configured_health(settings)
	health = max_health
	death_time = -1.0
	next_health_event_id = 0
	armor_light_off_until.resize(4)
	armor_light_off_until.fill(0.0)
	translation_origin = settings.target.center
	translation_epoch = 0.0
	translation_start_offset = 0.0
	translation_direction = 1.0
	rotation_origin = settings.target.phase
	rotation_epoch = 0.0
	motion_stop_time = 0.0 if health <= 0 else -1.0


func _configured_health(s: Dictionary) -> int:
	return int(Presets.ROBOTS[s.appearance.robot].max_health if s.target.max_health < 0 else s.target.max_health)


func apply_settings(updated: Dictionary, reset_health: bool = false) -> void:
	var pose = target_pose(time)
	var motion = _translation_state(time)
	var was_stopped = motion_stop_time >= 0.0
	var translation_changed = false
	for key in ["center", "translate", "speed", "acceleration", "heading", "travel"]:
		translation_changed = translation_changed or updated.target[key] != settings.target[key]
	if translation_changed or was_stopped:
		# Keep the configured center as the path center. Re-centering on the current pose made every
		# live edit shift the legal travel range and allowed repeated edits to drift indefinitely.
		var desired: Vector3 = pose.center + updated.target.center - settings.target.center
		if updated.target.translate:
			var axis = Vector3(cos(updated.target.heading), sin(updated.target.heading), 0.0)
			translation_start_offset = clampf(
				(desired - updated.target.center).dot(axis), -updated.target.travel, updated.target.travel)
			translation_origin = updated.target.center
		else:
			# Disabling translation intentionally freezes the current world position.
			translation_origin = desired
			translation_start_offset = 0.0
		translation_direction = float(motion.direction)
		translation_epoch = time
	if updated.target.rotate != settings.target.rotate or updated.target.omega != settings.target.omega \
			or updated.target.phase != settings.target.phase or was_stopped:
		rotation_origin = pose.angle + updated.target.phase - settings.target.phase
		rotation_epoch = time
	var health_changed: bool = reset_health or updated.target.max_health != settings.target.max_health \
		or updated.appearance.robot != settings.appearance.robot
	settings = updated.duplicate(true)
	if health_changed:
		max_health = _configured_health(settings)
		health = max_health
		death_time = -1.0
		armor_light_off_until.fill(0.0)
		events.append({"type": "health_set", "id": next_health_event_id,
			"time": time, "health": health, "max_health": max_health})
		next_health_event_id += 1
		_trim_events()
	motion_stop_time = time if health <= 0 else -1.0


func set_command(value: Dictionary) -> void:
	var was_firing = bool(command.fire)
	command = value.duplicate()
	for key in ["yaw_vel", "pitch_vel", "yaw_acc", "pitch_acc"]:
		if not command.has(key):
			command[key] = 0.0
	command.yaw = wrapf(float(command.yaw), -PI, PI)
	command.pitch = clampf(float(command.pitch), settings.gimbal.pitch_min, settings.gimbal.pitch_max)
	if not command.control:
		command.fire = false
		pending.clear()
	if command.fire and not was_firing:
		next_trigger = maxf(next_trigger, time)


func stop() -> void:
	set_command({"control": false, "fire": false, "yaw": yaw, "pitch": pitch})


static func forward(y: float, p: float) -> Vector3:
	return Vector3(cos(p) * cos(y), cos(p) * sin(y), -sin(p))


static func _leg_duration(distance: float, speed: float, acceleration: float) -> float:
	if distance <= 0.0 or speed <= 0.0:
		return 0.0
	var peak = minf(speed, sqrt(distance * acceleration))
	var acceleration_time = peak / acceleration
	var acceleration_distance = 0.5 * acceleration * acceleration_time * acceleration_time
	return 2.0 * acceleration_time + (distance - 2.0 * acceleration_distance) / peak


static func _leg_distance(distance: float, elapsed: float, speed: float, acceleration: float) -> float:
	if distance <= 0.0 or elapsed <= 0.0 or speed <= 0.0:
		return 0.0
	var peak = minf(speed, sqrt(distance * acceleration))
	var acceleration_time = peak / acceleration
	var acceleration_distance = 0.5 * acceleration * acceleration_time * acceleration_time
	var cruise_time = (distance - 2.0 * acceleration_distance) / peak
	var duration = 2.0 * acceleration_time + cruise_time
	var t = minf(elapsed, duration)
	if t < acceleration_time:
		return 0.5 * acceleration * t * t
	if t < acceleration_time + cruise_time:
		return acceleration_distance + peak * (t - acceleration_time)
	var remaining = duration - t
	return distance - 0.5 * acceleration * remaining * remaining


func _translation_state(at: float) -> Dictionary:
	var t: Dictionary = settings.target
	var start = clampf(translation_start_offset, -t.travel, t.travel)
	var initial_direction = 1.0 if translation_direction >= 0.0 else -1.0
	if not t.translate or t.speed <= 0.0:
		return {"offset": start, "direction": initial_direction}
	var motion_at = minf(at, motion_stop_time) if motion_stop_time >= 0.0 else at
	var elapsed = maxf(0.0, motion_at - translation_epoch)
	var first_distance = t.travel - start if initial_direction > 0.0 else start + t.travel
	var first_duration = _leg_duration(first_distance, t.speed, t.acceleration)
	if elapsed < first_duration:
		return {"offset": start + initial_direction * _leg_distance(
			first_distance, elapsed, t.speed, t.acceleration), "direction": initial_direction}
	elapsed -= first_duration
	var full_distance = 2.0 * t.travel
	var full_duration = _leg_duration(full_distance, t.speed, t.acceleration)
	var completed = int(floor(elapsed / full_duration))
	var local_time = elapsed - completed * full_duration
	var direction = -initial_direction if completed % 2 == 0 else initial_direction
	var leg_start = initial_direction * t.travel if completed % 2 == 0 else -initial_direction * t.travel
	return {"offset": leg_start + direction * _leg_distance(
		full_distance, local_time, t.speed, t.acceleration), "direction": direction}


func target_pose(at: float) -> Dictionary:
	var motion_at = minf(at, motion_stop_time) if motion_stop_time >= 0.0 else at
	var t: Dictionary = settings.target
	var center = translation_origin
	if t.translate:
		var motion = _translation_state(at)
		center += Vector3(cos(t.heading), sin(t.heading), 0.0) * float(motion.offset)
	return {"center": center, "angle": rotation_origin + (t.omega * (motion_at - rotation_epoch) if t.rotate else 0.0)}


func armor_pose(index: int, at: float) -> Dictionary:
	var pose = target_pose(at)
	var angle: float = pose.angle + index * TAU / 4.0
	var radial = Vector3(cos(angle), sin(angle), 0.0)
	var normal = radial * cos(settings.target.armor_tilt) + Vector3(0, 0, sin(settings.target.armor_tilt))
	var tangent = Vector3(-sin(angle), cos(angle), 0.0)
	var up = normal.cross(tangent)
	var center: Vector3 = pose.center + radial * settings.target.radius
	if index % 2 == 1:
		center.z += settings.target.height_difference
	return {"id": index, "center": center, "normal": normal, "tangent": tangent,
		"up": up, "normal_yaw": wrapf(angle, -PI, PI)}


func camera_pose() -> Dictionary:
	var f = forward(yaw, pitch)
	var right = Vector3(sin(yaw), -cos(yaw), 0)
	var up = right.cross(f)
	var offset: Vector3 = settings.camera.offset
	var origin: Vector3 = settings.gimbal.origin + f * offset.x - right * offset.y + up * offset.z
	return {"origin": origin, "forward": f, "right": right, "up": up}


func armor_light_on(index: int) -> bool:
	return health > 0 and time >= armor_light_off_until[index]


func camera_observation() -> Dictionary:
	var pose = camera_pose()
	var c: Dictionary = settings.camera
	var fy = 0.5 * c.height / tan(deg_to_rad(c.vertical_fov) * 0.5)
	var armors: Array[Dictionary] = []
	for i in range(4):
		if not armor_light_on(i):
			continue
		var armor = armor_pose(i, time)
		if (pose.origin - armor.center).dot(armor.normal) <= 0.0:
			continue
		var points: Array = []
		var all_in_frame = true
		# Order: top-left, top-right, bottom-right, bottom-left as seen from the face.
		for uv in [Vector2(-1, 1), Vector2(1, 1), Vector2(1, -1), Vector2(-1, -1)]:
			var point: Vector3 = armor.center + armor.tangent * uv.x * settings.target.lightbar_spacing * 0.5
			point += armor.up * uv.y * settings.target.lightbar_length * 0.5
			var rel: Vector3 = point - pose.origin
			var depth: float = rel.dot(pose.forward)
			if depth <= 0.01:
				all_in_frame = false
				break
			var pixel = Vector2(fy * rel.dot(pose.right) / depth + c.width * 0.5,
				-fy * rel.dot(pose.up) / depth + c.height * 0.5)
			if pixel.x < 0 or pixel.x >= c.width or pixel.y < 0 or pixel.y >= c.height:
				all_in_frame = false
			points.append([pixel.x, pixel.y])
		if all_in_frame:
			armors.append({"id": i, "corners": points})
	return {"timestamp": time, "tick": tick, "width": c.width, "height": c.height,
		"brightness_gain": c.brightness_gain,
		"K": [fy, 0.0, c.width * 0.5, 0.0, fy, c.height * 0.5, 0.0, 0.0, 1.0],
		"distortion": [0.0, 0.0, 0.0, 0.0, 0.0],
		"R_camera2gimbal": [0.0, 0.0, 1.0, -1.0, 0.0, 0.0, 0.0, -1.0, 0.0],
		"t_camera2gimbal": vec(c.offset),
		"origin": vec(pose.origin), "yaw": yaw, "pitch": pitch, "armors": armors}


func step(dt: float) -> void:
	if paused or dt <= 0.0:
		return
	# Collision resolution is independent of rendering and also bounded during fast rotation.
	var rotation_dt = 0.005 / maxf(absf(settings.target.omega), 1.0)
	var count = maxi(1, ceili(dt / minf(MAX_COLLISION_DT, rotation_dt)))
	var h = dt / count
	for _i in range(count):
		_substep(h)
	tick += 1


func _axis_step(angle: float, velocity: float, goal: float, goal_v: float, goal_a: float,
		dt: float, wrap_angle: bool) -> Vector2:
	var error = wrapf(goal - angle, -PI, PI) if wrap_angle else goal - angle
	var response: float = TAU * settings.gimbal.response_hz
	var accel = response * response * error + 2.0 * response * (goal_v - velocity) + goal_a
	accel = clampf(accel, -settings.gimbal.max_acceleration, settings.gimbal.max_acceleration)
	var new_v = clampf(velocity + accel * dt, -settings.gimbal.max_speed, settings.gimbal.max_speed)
	return Vector2(angle + (velocity + new_v) * 0.5 * dt, new_v)


func _substep(dt: float) -> void:
	var end = time + dt
	var old_yaw = yaw
	var old_pitch = pitch
	if command.control:
		var y = _axis_step(yaw, yaw_velocity, command.yaw, command.yaw_vel, command.yaw_acc, dt, true)
		var p = _axis_step(pitch, pitch_velocity, command.pitch, command.pitch_vel, command.pitch_acc, dt, false)
		yaw = wrapf(y.x, -PI, PI)
		yaw_velocity = y.y
		pitch = clampf(p.x, settings.gimbal.pitch_min, settings.gimbal.pitch_max)
		pitch_velocity = p.y if pitch == p.x else 0.0
	else:
		yaw_velocity = move_toward(yaw_velocity, 0.0, settings.gimbal.max_acceleration * dt)
		pitch_velocity = move_toward(pitch_velocity, 0.0, settings.gimbal.max_acceleration * dt)
		yaw = wrapf(yaw + yaw_velocity * dt, -PI, PI)
		pitch = clampf(pitch + pitch_velocity * dt, settings.gimbal.pitch_min, settings.gimbal.pitch_max)
	if command.control and command.fire:
		while next_trigger <= end + 1e-9:
			pending.append(maxf(time, next_trigger) + settings.weapon.delay)
			next_trigger = maxf(time, next_trigger) + 1.0 / settings.weapon.rate
	while not pending.is_empty() and pending.front() <= end + 1e-9:
		var release = pending.pop_front()
		var weight = clampf((release - time) / dt, 0.0, 1.0)
		_spawn(release, lerp_angle(old_yaw, yaw, weight), lerpf(old_pitch, pitch, weight))
	for i in range(projectiles.size() - 1, -1, -1):
		var bullet = projectiles[i]
		var start: float = maxf(time, bullet.born)
		var result = _collision(bullet, start, end)
		if not result.is_empty():
			_finish(bullet, result)
			projectiles.remove_at(i)
		elif end - bullet.born >= settings.weapon.lifetime or _outside_target_range(bullet, end):
			_finish(bullet, {"kind": "expired", "time": end, "point": bullet_position(bullet, end),
				"reason": "lifetime" if end - bullet.born >= settings.weapon.lifetime else "range"})
			projectiles.remove_at(i)
	time = end


func _spawn(at: float, actual_yaw: float, actual_pitch: float) -> void:
	if projectiles.size() >= MAX_PROJECTILES:
		return
	var direction = forward(actual_yaw, actual_pitch)
	var origin: Vector3 = settings.gimbal.origin + settings.gimbal.barrel_length * direction
	var bullet = {"id": next_shot_id, "born": at, "origin": origin,
		"velocity": direction * settings.weapon.speed, "damage": settings.weapon.damage}
	projectiles.append(bullet)
	next_shot_id += 1
	stats.fired += 1
	events.append({"type": "shot", "id": bullet.id, "time": at,
		"yaw": actual_yaw, "pitch": actual_pitch})
	_trim_events()


func bullet_position(bullet: Dictionary, at: float) -> Vector3:
	var age = maxf(0.0, at - bullet.born)
	return bullet.origin + bullet.velocity * age + Vector3(0, 0, -0.5 * settings.weapon.gravity * age * age)


func _outside_target_range(bullet: Dictionary, at: float) -> bool:
	var origin: Vector3 = bullet.origin
	var offset = Vector2(translation_origin.x - origin.x, translation_origin.y - origin.y)
	var half_diagonal = Vector2(settings.target.armor_width, settings.target.armor_height).length() * 0.5
	var limit = offset.length() + settings.target.radius + half_diagonal + 0.1
	if settings.target.translate:
		limit += settings.target.travel
	# Horizontal velocity is constant: after leaving this bound the bullet cannot hit any future target pose.
	var point = bullet_position(bullet, at)
	return Vector2(point.x - origin.x, point.y - origin.y).length_squared() > limit * limit


func _collision(bullet: Dictionary, start: float, end: float) -> Dictionary:
	var p0 = bullet_position(bullet, start)
	var p1 = bullet_position(bullet, end)
	var best: Dictionary = {}
	for i in range(4):
		var a0 = armor_pose(i, start)
		var a1 = armor_pose(i, end)
		var d0: float = (p0 - a0.center).dot(a0.normal)
		var d1: float = (p1 - a1.center).dot(a1.normal)
		# Only the outward face is a scoring surface.
		if d0 < 0.0 or d1 > 0.0:
			continue
		var lo = start
		var hi = end
		for _j in range(16):
			var mid = (lo + hi) * 0.5
			var armor = armor_pose(i, mid)
			if (bullet_position(bullet, mid) - armor.center).dot(armor.normal) > 0.0:
				lo = mid
			else:
				hi = mid
		var at = (lo + hi) * 0.5
		var armor = armor_pose(i, at)
		var point = bullet_position(bullet, at)
		var local: Vector3 = point - armor.center
		if absf(local.dot(armor.tangent)) <= settings.target.armor_width * 0.5 \
				and absf(local.dot(armor.up)) <= settings.target.armor_height * 0.5:
			if best.is_empty() or at < best.time:
				best = {"kind": "hit", "armor_id": i, "time": at, "point": point,
					"normal": armor.normal, "uv": Vector2(local.dot(armor.tangent), local.dot(armor.up))}
	if p1.z <= 0.0:
		var fraction_ground = clampf(p0.z / maxf(p0.z - p1.z, 1e-12), 0.0, 1.0)
		var at = lerpf(start, end, fraction_ground)
		if best.is_empty() or at < best.time:
			best = {"kind": "ground", "time": at, "point": bullet_position(bullet, at), "normal": Vector3(0, 0, 1)}
	return best


func _finish(bullet: Dictionary, result: Dictionary) -> void:
	stats[result.kind] += 1
	if result.kind == "hit" and first_hit_time < 0.0:
		first_hit_time = result.time
	var event = {"type": "impact", "id": bullet.id, "kind": result.kind,
		"time": result.time, "point": vec(result.point), "armor_id": result.get("armor_id", -1)}
	if result.has("reason"):
		event["reason"] = result.reason
	var damage = 0
	var killed = false
	if result.kind == "hit" and health > 0:
		var armor_id: int = result.armor_id
		armor_light_off_until[armor_id] = maxf(armor_light_off_until[armor_id], result.time + HIT_FLASH_DURATION)
		damage = mini(health, int(bullet.get("damage", settings.weapon.damage)))
		health -= damage
		stats.damage += damage
		if health == 0:
			death_time = result.time
			motion_stop_time = result.time
			stats.kills += 1
			killed = true
	event["damage"] = damage
	event["health"] = health
	event["killed"] = killed
	events.append(event)
	var effect = result.duplicate()
	effect["id"] = bullet.id
	effect["velocity"] = bullet.velocity + Vector3(0, 0, -settings.weapon.gravity * (result.time - bullet.born))
	impacts.append(effect)
	if impacts.size() > 80:
		impacts.pop_front()
	_trim_events()


func _trim_events() -> void:
	while events.size() > 128:
		events.pop_front()


func metrics() -> Dictionary:
	var resolved: int = stats.hit + stats.body + stats.ground + stats.expired
	var result = stats.duplicate()
	result["in_flight"] = projectiles.size()
	result["pending"] = pending.size()
	result["resolved"] = resolved
	result["hit_rate"] = float(stats.hit) / resolved if resolved > 0 else 0.0
	result["hits_per_second"] = float(stats.hit) / time if time > 0.0 else 0.0
	result["first_hit_time"] = first_hit_time
	return result


func snapshot() -> Dictionary:
	var pose = target_pose(time)
	var orientation = Quaternion(Vector3(0, 0, 1), yaw) * Quaternion(Vector3(0, 1, 0), pitch)
	var armors: Array[Dictionary] = []
	for i in range(4):
		var a = armor_pose(i, time)
		armors.append({"id": i, "center": vec(a.center), "normal": vec(a.normal),
			"normal_yaw": a.normal_yaw})
	return {"protocol": "rm_aim_sim/2", "type": "state", "session_id": session_id,
		"tick": tick, "sim_time": time, "paused": paused,
		"gimbal": {"yaw": yaw, "pitch": pitch, "yaw_vel": yaw_velocity,
			"pitch_vel": pitch_velocity, "origin": vec(settings.gimbal.origin),
			"quaternion_wxyz": [orientation.w, orientation.x, orientation.y, orientation.z]},
		"weapon": {"speed": settings.weapon.speed, "rate": settings.weapon.rate,
			"delay": settings.weapon.delay, "barrel_length": settings.gimbal.barrel_length,
			"gravity": settings.weapon.gravity, "damage": settings.weapon.damage},
		"health": {"current": health, "maximum": max_health, "alive": health > 0,
			"death_time": death_time},
		"appearance": settings.appearance.duplicate(),
		"truth": {"center": vec(pose.center), "angle": pose.angle, "armors": armors},
		"camera": camera_observation(), "stats": metrics(), "events": events.duplicate(true)}


static func vec(v: Vector3) -> Array:
	return [v.x, v.y, v.z]
