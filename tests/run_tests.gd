extends SceneTree

const Settings = preload("res://scripts/settings.gd")
const Simulation = preload("res://scripts/simulation.gd")
const Bridge = preload("res://scripts/bridge.gd")
const Presets = preload("res://scripts/presets.gd")
const AimAssist = preload("res://scripts/aim_assist.gd")
var failures: Array[String] = []
var checks = 0


func _initialize() -> void:
	call_deferred("_run")


func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error("FAIL: " + message)


func approx(actual: float, expected: float, tolerance: float, message: String) -> void:
	check(absf(actual - expected) <= tolerance, "%s: actual=%f expected=%f" % [message, actual, expected])


func base_settings() -> Dictionary:
	var s = Settings.defaults()
	s.target.armor_tilt = 0.0
	s.target.center = Vector3(6, 0, 0.65)
	s.weapon.gravity = 0.0
	return s


func command(y: float = 0, p: float = 0, fire: bool = false) -> Dictionary:
	return {"control": true, "fire": fire, "yaw": y, "pitch": p}


func advance(sim: RefCounted, duration: float, dt: float = 1.0 / 240.0) -> void:
	var count = int(round(duration / dt))
	for _i in range(count):
		sim.step(dt)


func _run() -> void:
	_test_settings()
	_test_spacing()
	_test_motion()
	_test_accelerated_translation()
	_test_gimbal()
	_test_fire_and_collision()
	_test_health()
	_test_hit_flash()
	_test_death_motion()
	_test_live_settings()
	_test_aim_assist()
	_test_projectile_cleanup()
	_test_moving_collision()
	_test_camera()
	_test_bridge()
	if failures.is_empty():
		print("PASS: %d simulation checks" % checks)
		quit(0)
	else:
		print("FAILED: %d / %d checks" % [failures.size(), checks])
		quit(1)


func _test_settings() -> void:
	check(Settings.validate(Settings.defaults()).is_empty(), "default settings valid")
	check(Settings.load_file("res://configs/default.cfg").ok, "default config loads")
	approx(Settings.defaults().camera.brightness_gain, 0.4, 0.0, "camera exposure gain defaults to 0.4")
	approx(Settings.load_file("res://configs/default.cfg").settings.camera.brightness_gain, 0.4, 0.0,
		"default config uses 0.4 exposure gain")
	approx(Settings.defaults().target.center.x, 4.0, 0.0, "default target distance is 4 m")
	approx(Settings.load_file("res://configs/default.cfg").settings.target.center.x, 4.0, 0.0, "default config distance is 4 m")
	for name in ["translate", "spin", "combined"]:
		check(Settings.load_file("res://configs/%s.cfg" % name).ok, name + " scenario loads")
	var s = Settings.defaults()
	s.weapon.speed = 0.0
	check(not Settings.validate(s).is_empty(), "zero bullet speed rejected")
	s = Settings.defaults()
	s.target.omega = NAN
	check(not Settings.validate(s).is_empty(), "NaN rejected")
	s = Settings.defaults()
	s.target.acceleration = 0.0
	check(not Settings.validate(s).is_empty(), "zero translation acceleration rejected")
	s = Settings.defaults()
	s.camera.width = 160.5
	check(not Settings.validate(s).is_empty(), "fractional image width rejected")
	s = Settings.defaults()
	s.camera.brightness_gain = -0.1
	check(not Settings.validate(s).is_empty(), "negative camera gain rejected")
	s.camera.brightness_gain = 4.1
	check(not Settings.validate(s).is_empty(), "camera gain above maximum rejected")
	s.camera.brightness_gain = 0.0
	check(Settings.validate(s).is_empty(), "zero camera gain is valid for black output")
	s.camera.brightness_gain = 0.25
	var gain_path = "user://test_camera_gain.cfg"
	check(Settings.save_file(s, gain_path) == OK, "camera gain saves with scenario")
	var gain_loaded = Settings.load_file(gain_path)
	check(gain_loaded.ok and gain_loaded.settings.camera.brightness_gain == 0.25,
		"camera gain survives read-write-read")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(gain_path))
	s = Settings.defaults()
	s.ipc.channel = "../invalid"
	check(not Settings.validate(s).is_empty(), "invalid IPC channel rejected")
	s = Settings.defaults()
	Presets.apply_robot(s, "hero")
	approx(s.target.armor_width, 0.23, 1e-9, "hero uses large armor")
	approx(s.target.lightbar_spacing, 0.23, 1e-9, "hero lightbar geometry follows preset")
	check(Presets.ROBOTS.sentry.number == "7", "sentry number")
	check(Presets.team_color("red") != Presets.team_color("blue"), "red and blue colors differ")
	approx(s.target.module_width, 0.235, 1e-9, "hero physical module width")
	approx(s.target.module_height, 0.127, 1e-9, "hero physical module height")
	for robot in Presets.ROBOTS:
		s = Settings.defaults()
		s.appearance.robot = robot
		var sim = Simulation.new(s)
		check(sim.health == (400 if robot == "sentry" else 350), "RMUL 3v3 health: " + robot)
	s.target.max_health = 35.5
	check(not Settings.validate(s).is_empty(), "fractional health rejected")
	s.target.max_health = -1
	s.weapon.damage = 20.5
	check(not Settings.validate(s).is_empty(), "fractional damage rejected")
	var partial = ConfigFile.new()
	partial.set_value("appearance", "robot", "hero")
	var path = "user://test_hero_dimensions.cfg"
	check(partial.save(path) == OK, "partial hero configuration saved")
	var loaded = Settings.load_file(path)
	check(loaded.ok and loaded.settings.target.module_width == 0.235, "partial hero config inherits large module")
	partial.set_value("target", "module_width", 0.24)
	partial.save(path)
	check(Settings.load_file(path).settings.target.module_width == 0.24, "explicit custom module size is retained")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	s = Settings.defaults()
	s.target.height_difference = 0.101
	check(not Settings.validate(s).is_empty(), "height difference above 100 mm rejected")
	s.target.height_difference = 0.1
	s.target.center.z = 0.3
	check(Settings.validate(s).is_empty(), "100 mm height difference within legal ground clearance accepted")
	s.target.center.z = 0.3 + Presets.vertical_half_height(s.target)
	check(Settings.validate(s).is_empty(), "400 mm lower-edge boundary accepts engine position rounding")
	s.target.center.z += 0.001
	check(not Settings.validate(s).is_empty(), "401 mm lower edge is rejected")
	s.target.center.z = 0.5
	check(not Settings.validate(s).is_empty(), "lower edge above 400 mm rejected")
	s.target.center.z = 0.05
	s.target.height_difference = 0.0
	check(not Settings.validate(s).is_empty(), "armor intersecting ground rejected")


func _test_spacing() -> void:
	var s = Settings.defaults()
	approx(Presets.extent(s.target), 0.55, 1e-7, "default rotation envelope is 550 mm")
	approx(Presets.lower_edge(s.target), 0.2, 1e-7, "default base lower edge is 200 mm")
	approx(s.target.height_difference, -0.1, 1e-9, "default pair offset is -100 mm")
	approx(Presets.lower_edge(s.target) + s.target.height_difference, 0.1, 1e-7, "other pair lower edge is 100 mm")
	var config = Settings.load_file("res://configs/default.cfg")
	approx(Presets.extent(config.settings.target), 0.55, 1e-7, "default file uses 550 mm envelope")
	approx(Presets.lower_edge(config.settings.target), 0.2, 1e-7, "default file uses 200 mm lower edge")
	for robot in Presets.ROBOTS:
		s = Settings.defaults()
		Presets.apply_robot(s, robot)
		check(Settings.validate(s).is_empty(), "preset spacing valid: " + robot)
		approx(Presets.extent(s.target), 0.55, 1e-7, "all presets default to 550 mm: " + robot)
		approx(Presets.lower_edge(s.target), 0.2, 1e-7, "changing module height retains lower-edge height: " + robot)
		s.target.radius = Presets.radius_for_extent(0.6, s.target)
		check(Settings.validate(s).is_empty(), "600 mm boundary accepted: " + robot)
		s.target.radius = Presets.radius_for_extent(0.601, s.target)
		check(not Settings.validate(s).is_empty(), "601 mm envelope rejected: " + robot)
		s.target.radius = Presets.minimum_radius(s.target)
		check(Settings.validate(s).is_empty(), "minimum clear spacing accepted: " + robot)
		s.target.radius -= 0.002
		check(not Settings.validate(s).is_empty(), "overlapping or obstructing spacing rejected: " + robot)
	s = Settings.defaults()
	s.target.radius = Presets.radius_for_extent(0.6, s.target)
	var path = "user://test_spacing.cfg"
	check(Settings.save_file(s, path) == OK, "spacing configuration saves")
	var loaded = Settings.load_file(path)
	check(loaded.ok, "spacing configuration reads back")
	approx(loaded.settings.target.radius, s.target.radius, 1e-7, "explicit radius survives read-write-read")
	approx(Presets.lower_edge(loaded.settings.target), 0.2, 1e-7, "mount height survives read-write-read")
	var invalid = ConfigFile.new()
	invalid.set_value("target", "module_height", "invalid")
	invalid.save(path)
	check(not Settings.load_file(path).ok, "bad geometry type is rejected before derivation")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _test_motion() -> void:
	var s = base_settings()
	var sim = Simulation.new(s)
	check(sim.target_pose(12.0).center == s.target.center, "translation disabled stays still")
	approx(sim.target_pose(12.0).angle, PI, 1e-9, "rotation disabled stays still")
	s.target.translate = true
	s.target.speed = 1.0
	s.target.acceleration = 2.0
	s.target.travel = 1.0
	s.target.heading = PI / 2
	s.target.rotate = true
	s.target.omega = -4.0
	sim.reset(s)
	approx(sim.target_pose(0.5).center.y, 0.25, 1e-6, "world frame accelerated translation")
	approx(sim.target_pose(1.5).center.y, 1.0, 1e-6, "motion brakes at positive boundary")
	approx(sim.target_pose(4.0).center.y, -1.0, 1e-6, "motion brakes at negative boundary")
	approx(sim.target_pose(0.5).angle, PI - 2.0, 1e-6, "signed rotation independent of translation")
	var original_session: String = sim.session_id
	sim.reset()
	check(sim.session_id != original_session, "reset creates a fresh session")
	sim.paused = true
	sim.step(0.1)
	approx(sim.time, 0.0, 0.0, "pause freezes time")


func _test_accelerated_translation() -> void:
	var s = base_settings()
	s.target.translate = true
	s.target.speed = 1.0
	s.target.acceleration = 2.0
	s.target.travel = 1.0
	s.target.heading = PI / 2
	var sim = Simulation.new(s)
	approx(sim.target_pose(0.25).center.y, 0.0625, 1e-6,
		"translation accelerates from rest")
	approx(sim.target_pose(1.5).center.y, 1.0, 1e-6,
		"translation brakes to the positive boundary")
	approx(sim.target_pose(4.0).center.y, -1.0, 1e-6,
		"translation brakes before reversing at the negative boundary")
	var epsilon = 0.01
	var incoming = (sim.target_pose(1.5).center.y - sim.target_pose(1.5 - epsilon).center.y) / epsilon
	var outgoing = (sim.target_pose(1.5 + epsilon).center.y - sim.target_pose(1.5).center.y) / epsilon
	check(incoming > 0.0 and incoming < 0.02 and outgoing < 0.0 and outgoing > -0.02,
		"translation reaches zero speed before reversing")
	var max_speed = 0.0
	var max_acceleration = 0.0
	var previous = sim.target_pose(0.0).center.y
	var previous_speed = 0.0
	for i in range(1, 601):
		var current: float = sim.target_pose(i * 0.01).center.y
		var speed = (current - previous) / 0.01
		max_speed = maxf(max_speed, absf(speed))
		max_acceleration = maxf(max_acceleration, absf(speed - previous_speed) / 0.01)
		previous = current
		previous_speed = speed
	check(max_speed <= s.target.speed + 1e-4, "translation respects configured speed limit")
	check(max_acceleration <= s.target.acceleration + 0.01,
		"translation respects acceleration limit across reversals")
	var before = sim.target_pose(0.3).center
	sim.time = 0.3
	var changed = s.duplicate(true)
	changed.target.speed = 2.5
	sim.apply_settings(changed)
	check(sim.target_pose(sim.time).center.is_equal_approx(before),
		"live speed edit preserves the current position")
	for _i in range(120):
		advance(sim, 0.05)
		var offset: Vector3 = sim.target_pose(sim.time).center - changed.target.center
		check(absf(offset.y) <= changed.target.travel + 1e-6 and absf(offset.x) <= 1e-6,
			"live speed edit keeps translation inside configured bounds")
	# Repeated edits must not accumulate a new center, including edits on a return leg.
	var stays_in_bounds = true
	for i in range(40):
		changed.target.speed = 0.5 if i % 2 == 0 else 2.5
		sim.apply_settings(changed)
		advance(sim, 0.3)
		stays_in_bounds = stays_in_bounds and absf(sim.target_pose(sim.time).center.y) <= 1.0 + 1e-6
	check(stays_in_bounds, "repeated live edits never drift the configured center")
	changed.target.travel = 0.1
	sim.apply_settings(changed)
	check(absf(sim.target_pose(sim.time).center.y) <= 0.1 + 1e-6,
		"shrinking travel clamps the current position into the new range")
	changed.target.heading = 0.0
	sim.apply_settings(changed)
	approx(sim.target_pose(sim.time).center.y, changed.target.center.y, 1e-6,
		"changing direction projects the position onto the new configured path")
	advance(sim, 0.3)
	changed.target.translate = false
	sim.apply_settings(changed)
	var frozen: Vector3 = sim.target_pose(sim.time).center
	advance(sim, 0.3)
	check(sim.target_pose(sim.time).center.is_equal_approx(frozen),
		"disabled translation freezes the accelerated target")
	changed.target.translate = true
	sim.apply_settings(changed)
	check(sim.target_pose(sim.time).center.is_equal_approx(frozen),
		"re-enabling translation retains a position already inside the path")
	changed.target.speed = 0.0
	sim.apply_settings(changed)
	check(sim.target_pose(sim.time + 100.0).center.is_equal_approx(frozen),
		"zero target speed holds position without invalid leg durations")


func _test_gimbal() -> void:
	var sim = Simulation.new(base_settings())
	sim.set_command(command(1.0, -0.2))
	sim.step(1.0 / 240.0)
	check(sim.yaw > 0 and sim.yaw < 0.01, "gimbal moves without teleporting")
	check(sim.yaw_velocity <= sim.settings.gimbal.max_acceleration / 240.0 + 1e-6, "acceleration limited")
	advance(sim, 2.0)
	approx(sim.yaw, 1.0, 0.001, "gimbal reaches commanded yaw")
	approx(sim.pitch, -0.2, 0.001, "gimbal reaches commanded pitch")
	check(Simulation.forward(0, -0.2).z > 0, "negative pitch elevates barrel")
	sim.set_command(command(0, 10))
	advance(sim, 2.0)
	check(sim.pitch <= sim.settings.gimbal.pitch_max, "pitch mechanical limit respected")
	sim.yaw = PI - 0.01
	sim.yaw_velocity = 0
	sim.set_command(command(-PI + 0.01, 0))
	sim.step(0.01)
	check(sim.yaw_velocity > 0, "yaw takes shortest path across wrap")


func _test_fire_and_collision() -> void:
	var sim = Simulation.new(base_settings())
	sim.set_command(command(0, 0, true))
	advance(sim, 1.0)
	check(sim.stats.fired == 10, "continuous fire uses configured rate")
	check(sim.stats.hit >= 7, "static target receives real projectile hits")
	approx(sim.events[0].time, 0.015, 1e-6, "first shot respects launch delay")
	sim.stop()
	advance(sim, 0.5)
	var m = sim.metrics()
	check(m.fired == m.resolved + m.in_flight, "shot accounting closes")
	approx(m.hit_rate, 1.0, 1e-9, "static aligned shots all score")
	check(m.hit == 10, "each bullet scores only once")
	sim.reset()
	sim.set_command(command(0, 0, true))
	sim.step(0.01)
	check(sim.stats.fired == 0 and sim.pending.size() == 1, "accepted trigger is not counted before muzzle release")
	sim.stop()
	sim.step(0.1)
	check(sim.stats.fired == 0, "control disable cancels pending launch")
	sim.reset()
	sim.set_command(command(1.0, 0, true))
	sim.step(0.02)
	var actual_shot = sim.events[0]
	check(actual_shot.yaw > 0.0 and actual_shot.yaw < 0.1, "launch uses actual delayed gimbal pose rather than commanded yaw")
	var s = base_settings()
	s.weapon.speed = 100.0
	sim.reset(s)
	sim.set_command(command(0, 0, true))
	advance(sim, 0.12, 0.02)
	check(sim.stats.hit >= 1, "fast projectile does not tunnel through armor")
	sim.reset(s)
	sim.pitch = atan2(0.16, 6.0)
	sim.set_command(command(0, sim.pitch, true))
	advance(sim, 0.2, 0.02)
	check(sim.stats.body == 0 and sim.stats.hit == 0 and sim.stats.expired >= 1, "empty space below armor has no invisible chassis collision")
	sim.reset(s)
	sim.yaw = 0.3
	sim.set_command(command(sim.yaw, 0, true))
	advance(sim, 0.1)
	sim.stop()
	advance(sim, 3.5)
	check(sim.stats.expired == 1 and sim.stats.hit == 0, "off-target bullet expires as miss")
	sim.reset()
	check(sim.stats.fired == 0 and sim.projectiles.is_empty() and sim.events.is_empty(), "reset clears round")


func _test_health() -> void:
	var s = base_settings()
	s.target.max_health = 35
	var sim = Simulation.new(s)
	sim.set_command(command(0, 0, true))
	advance(sim, 0.6)
	sim.stop()
	advance(sim, 0.5)
	check(sim.stats.hit == 6, "all aligned hits still counted after death")
	check(sim.impacts[0].normal.dot(sim.impacts[0].velocity) < 0.0, "impact preserves incoming velocity and surface normal for ricochet")
	check(sim.health == 0 and sim.stats.damage == 35 and sim.stats.kills == 1, "damage clamps at zero and kill counted once")
	var damages: Array = []
	for event in sim.events:
		if event.type == "impact":
			damages.append(event.damage)
	check(damages == [20, 15, 0, 0, 0, 0], "lethal hit truncates damage; dead target takes no further damage")
	check(sim.death_time > 0 and sim.camera_observation().armors.is_empty(), "dead target has death time and no ideal lightbar observations")
	check(sim.snapshot().truth.armors.size() == 4 and not sim.snapshot().health.alive, "dead target retains physical truth")
	var session: String = sim.session_id
	var counts: Dictionary = sim.stats.duplicate()
	advance(sim, 5.0)
	check(sim.health == 0 and sim.session_id == session and sim.stats == counts, "death and idle time never reset the round")
	sim.reset()
	check(sim.health == 35 and sim.stats.damage == 0 and sim.stats.kills == 0, "round reset restores configured health and counters")
	s.target.max_health = 0
	sim.reset(s)
	check(sim.health == 0 and sim.camera_observation().armors.is_empty(), "zero health starts with lights off")
	s.target.max_health = 100
	sim.reset(s)
	sim._spawn(0.0, 0.3, 0.0)
	advance(sim, 3.5)
	check(sim.health == 100 and sim.stats.damage == 0, "miss does not damage health")
	sim.reset(s)
	sim._spawn(0.0, 0.0, 0.0)
	var changed = s.duplicate(true)
	changed.weapon.damage = 99
	sim.apply_settings(changed)
	advance(sim, 0.5)
	check(sim.health == 80, "in-flight projectile retains muzzle-time damage")
	sim._spawn(sim.time, 0.0, 0.0)
	advance(sim, 0.5)
	check(sim.health == 0 and sim.stats.damage == 100, "new projectile uses live damage value")
	sim.apply_settings(changed, true)
	check(sim.health == 100 and sim.stats.damage == 100 and sim.stats.kills == 1, "explicit health edit restores same maximum without clearing statistics")


func _test_hit_flash() -> void:
	for team in ["blue", "red"]:
		var s = base_settings()
		s.appearance.team = team
		var sim = Simulation.new(s)
		for index in range(4):
			check(sim.armor_light_on(index), team + " starts with all armor lights on")
		sim._spawn(0.0, 0.0, 0.0)
		advance(sim, 0.02, 0.001)
		sim._spawn(sim.time, 0.0, 0.0)
		for _i in range(500):
			sim.step(0.001)
			if sim.stats.hit > 0:
				break
		check(sim.stats.hit == 1 and sim.health > 0, team + " real projectile causes nonlethal hit")
		var armor_id: int = sim.impacts[0].armor_id
		var first_deadline: float = sim.armor_light_off_until[armor_id]
		approx(first_deadline - sim.impacts[0].time, 0.05, 1e-9, "hit extinguishes lights for 50 ms")
		check(not sim.armor_light_on(armor_id), "hit armor is dark immediately")
		check(sim.camera_observation().armors.is_empty(), "dark armor has no ideal lightbar observation")
		check(sim.snapshot().truth.armors.size() == 4, "flashing does not remove physical armor truth")
		for index in range(4):
			if index != armor_id:
				check(sim.armor_light_on(index), "unhit armor remains illuminated")
		sim.paused = true
		var paused_time: float = sim.time
		advance(sim, 0.2)
		check(sim.time == paused_time and not sim.armor_light_on(armor_id), "pause freezes flash timer")
		sim.paused = false
		for _i in range(50):
			sim.step(0.001)
			if sim.stats.hit == 2:
				break
		check(sim.stats.hit == 2 and sim.armor_light_off_until[armor_id] > first_deadline,
			"repeated hit extends the same armor's flash deadline")
		while sim.time < first_deadline + 0.001:
			sim.step(0.001)
		check(not sim.armor_light_on(armor_id), "repeated hit prevents early relighting")
		var updated = sim.settings.duplicate(true)
		updated.camera.brightness_gain = 0.2
		sim.apply_settings(updated)
		check(not sim.armor_light_on(armor_id), "unrelated settings preserve an active flash")
		advance(sim, 0.05, 0.001)
		check(sim.armor_light_on(armor_id) and sim.camera_observation().armors.size() == 1,
			"light and ideal observation return after the latest deadline")
		sim._spawn(sim.time, 0.0, 0.0)
		for _i in range(500):
			sim.step(0.001)
			if sim.stats.hit == 3:
				break
		check(not sim.armor_light_on(armor_id), "new hit flashes again")
		sim.apply_settings(updated, true)
		check(sim.armor_light_on(armor_id), "explicit health restore clears stale flash state")
		s.target.max_health = 20
		sim.reset(s)
		sim._spawn(0.0, 0.0, 0.0)
		advance(sim, 0.5)
		for index in range(4):
			check(not sim.armor_light_on(index), "lethal hit keeps every armor dark beyond flash timeout")
		sim.reset()
		for index in range(4):
			check(sim.armor_light_on(index), "round reset clears flash and restores lights")
		sim._spawn(0.0, 0.0, PI / 8.0)
		advance(sim, 0.5)
		check(sim.stats.ground == 1, "miss lands on the ground")
		for index in range(4):
			check(sim.armor_light_on(index), "ground hit does not flash armor")


func _test_death_motion() -> void:
	var s = Settings.defaults()
	s.target.max_health = 20
	s.target.translate = true
	s.target.rotate = true
	var sim = Simulation.new(s)
	var solution: Dictionary = AimAssist.solve(sim)
	sim._spawn(0.0, solution.yaw, solution.pitch)
	advance(sim, 0.4)
	check(sim.health == 0, "moving target killed by predicted shot")
	var stopped = sim.target_pose(sim.time)
	advance(sim, 1.0)
	check(sim.target_pose(sim.time) == stopped, "death freezes translation and rotation at impact pose")
	check(sim.settings.target.translate and sim.settings.target.rotate, "death preserves motion switches")
	var changed = sim.settings.duplicate(true)
	changed.target.speed = 2.0
	changed.target.omega = -5.0
	sim.apply_settings(changed)
	check(sim.target_pose(sim.time) == stopped and sim.health == 0, "editing dead target speed neither moves nor revives it")
	sim.reset()
	check(sim.health == 20 and sim.settings.target.translate and sim.settings.target.rotate, "explicit reset restores health and motion settings")
	advance(sim, 0.1)
	check(sim.target_pose(sim.time).center != sim.settings.target.center, "translation resumes after reset")
	approx(sim.target_pose(sim.time).angle, s.target.phase - 0.5, 1e-6, "rotation resumes with preserved edited speed")


func _test_live_settings() -> void:
	var s = base_settings()
	s.target.translate = true
	s.target.rotate = true
	var sim = Simulation.new(s)
	sim.set_command(command(0.1, 0.05))
	advance(sim, 0.3)
	sim._spawn(sim.time, sim.yaw, sim.pitch)
	var before = sim.snapshot()
	var changed = s.duplicate(true)
	changed.target.speed = 2.5
	changed.target.omega = -3.0
	sim.apply_settings(changed)
	check(sim.session_id == before.session_id and sim.time == before.sim_time and sim.tick == before.tick,
		"live edit preserves session and clock")
	check(sim.projectiles.size() == 1 and sim.stats.fired == 1 and sim.yaw == before.gimbal.yaw,
		"live edit preserves bullets, statistics and gimbal")
	check(sim.snapshot().truth.center == before.truth.center, "live speed edit preserves current position")
	approx(sim.target_pose(sim.time).angle, before.truth.angle, 1e-9, "live angular-speed edit preserves current angle")
	var position: Vector3 = sim.target_pose(sim.time).center
	advance(sim, 0.1)
	approx(sim.target_pose(sim.time).center.y - position.y, 0.015, 1e-6,
		"live speed edit restarts with configured acceleration")
	approx(sim.target_pose(sim.time).angle - before.truth.angle, -0.3, 1e-6, "live rotation speed takes effect on following steps")
	changed.target.translate = false
	changed.target.rotate = false
	sim.apply_settings(changed)
	var frozen = sim.target_pose(sim.time)
	advance(sim, 0.1)
	check(sim.target_pose(sim.time) == frozen, "disabling motion freezes pose without teleporting")
	sim.paused = true
	changed.target.center.x += 1.0
	sim.apply_settings(changed)
	check(sim.paused and sim.target_pose(sim.time).center.is_equal_approx(frozen.center + Vector3.RIGHT),
		"position edit applies while paused without resuming")
	changed.target.max_health = 80
	sim.apply_settings(changed)
	check(sim.health == 80 and sim.max_health == 80 and sim.stats.fired == 1, "live health edit preserves fired count")


func _test_aim_assist() -> void:
	for scenario in ["static", "translate", "spin", "combined"]:
		var s = Settings.defaults()
		s.target.max_health = 10000
		s.target.translate = scenario in ["translate", "combined"]
		s.target.rotate = scenario in ["spin", "combined"]
		s.target.speed = 1.5
		var sim = Simulation.new(s)
		var solution: Dictionary = AimAssist.solve(sim)
		check(not solution.is_empty(), "assist finds ballistic solution: " + scenario)
		if solution.is_empty():
			continue
		sim._spawn(0.0, solution.yaw, solution.pitch)
		advance(sim, 0.5)
		check(sim.stats.hit == 1, "predicted trajectory intersects real moving armor: " + scenario)
		sim.reset(s)
		for tick_index in range(720):
			solution = AimAssist.solve(sim)
			if not solution.is_empty():
				solution.control = true
				solution.fire = tick_index >= 168
				sim.set_command(solution)
			sim.step(1.0 / 240.0)
		sim.stop()
		advance(sim, 3.5)
		print("ASSIST %s %s" % [scenario, JSON.stringify(sim.metrics())])
		check(sim.stats.hit >= 12 and sim.metrics().hit_rate >= 0.7, "continuous assist follows and hits: " + scenario)
	var s = Settings.defaults()
	s.target.max_health = 0
	check(AimAssist.solve(Simulation.new(s)).is_empty(), "assist ignores extinguished target")
	s.target.max_health = 350
	s.weapon.speed = 1.0
	check(AimAssist.solve(Simulation.new(s)).is_empty(), "assist rejects unreachable target")
	s = base_settings()
	s.target.translate = true
	var sim = Simulation.new(s)
	var solution: Dictionary = AimAssist.solve(sim)
	check(not solution.is_empty() and solution.yaw_vel > 0.0, "assist supplies motion feedforward without gravity")
	check(not solution.has("fire") and not sim.command.fire and sim.stats.fired == 0, "solving assist alone never fires")


func _test_projectile_cleanup() -> void:
	var s = Settings.defaults()
	s.weapon.gravity = 0.0
	var sim = Simulation.new(s)
	sim._spawn(0.0, 0.3, 0.0)
	var session: String = sim.session_id
	advance(sim, 0.3)
	check(sim.projectiles.is_empty() and sim.stats.expired == 1, "missed projectile clears promptly beyond target range")
	check(sim.events.back().reason == "range" and sim.stats.fired == sim.metrics().resolved,
		"early cleanup records a resolved miss and preserves accounting")
	check(sim.session_id == session and sim.stats.fired == 1, "projectile cleanup does not reset round")
	s.target.center.x = 20.0
	sim.reset(s)
	var solution: Dictionary = AimAssist.solve(sim)
	sim._spawn(0.0, solution.yaw, solution.pitch)
	advance(sim, 0.3)
	check(sim.projectiles.size() == 1, "range cleanup retains a projectile still travelling toward distant target")
	advance(sim, 0.7)
	check(sim.stats.hit == 1, "long-range projectile reaches armor before cleanup")


func _test_moving_collision() -> void:
	var s = base_settings()
	s.target.translate = true
	s.target.speed = 4.0
	s.target.travel = 10.0
	var sim = Simulation.new(s)
	# At the crossing time the target has moved away; aiming at its launch-time pose must miss.
	sim._spawn(0, 0, 0)
	advance(sim, 0.4)
	check(sim.stats.hit == 0, "collision uses moving target, not launch-time target pose")
	# Aim a synthetic projectile at the plate's accelerated pose at a known contact time.
	sim.reset(s)
	s.target.center.y = 0.0
	# Place the mathematical launch at the origin to isolate moving surface collision.
	var contact_time = 0.2
	var center: Vector3 = sim.armor_pose(0, contact_time).center
	var origin = Vector3(0, 0, 0.65)
	var bullet = {"id": 0, "born": 0.0, "origin": Vector3(0, 0, 0.65),
		"velocity": (center - origin) / contact_time}
	sim.projectiles.append(bullet)
	sim.stats.fired = 1
	advance(sim, 0.4)
	check(sim.stats.hit == 1, "continuous collision hits a translating plate at intercept time")
	for translation in [false, true]:
		s = base_settings()
		s.target.rotate = true
		s.target.omega = 4.0
		s.target.translate = translation
		s.target.speed = 1.0
		sim.reset(s)
		contact_time = 0.2
		center = sim.armor_pose(0, contact_time).center
		origin = Vector3(0, 0, 0.65)
		var rotating_bullet = {"id": 0, "born": 0.0, "origin": origin,
			"velocity": (center - origin) / contact_time}
		sim.projectiles.append(rotating_bullet)
		sim.stats.fired = 1
		advance(sim, 0.4)
		check(sim.stats.hit == 1, "intercept rotating plate with translation=" + str(translation))
	s = base_settings()
	s.target.rotate = true
	s.target.omega = 12.0
	var coarse = Simulation.new(s)
	var fine = Simulation.new(s)
	coarse.set_command(command(0, 0, true))
	fine.set_command(command(0, 0, true))
	advance(coarse, 1.0, 0.02)
	advance(fine, 1.0, 0.001)
	check(coarse.stats == fine.stats, "rotating target collision is stable across outer step sizes")


func _test_camera() -> void:
	var sim = Simulation.new(base_settings())
	var observation = sim.camera_observation()
	check(observation.armors.size() == 1, "only outward-facing near armor is observed")
	var points: Array = observation.armors[0].corners
	check(points[0][0] < points[1][0] and points[0][1] < points[3][1], "corners ordered TL TR BR BL")
	var original_height: float = points[3][1] - points[0][1]
	sim.settings.target.armor_height *= 2
	var changed = sim.camera_observation().armors[0].corners
	approx(changed[3][1] - changed[0][1], original_height, 1e-6, "PnP geometry independent of scoring size")
	sim.yaw = PI
	check(sim.camera_observation().armors.is_empty(), "out-of-view target is not observed")
	var snapshot = sim.snapshot()
	var q: Array = snapshot.gimbal.quaternion_wxyz
	var orientation = Quaternion(q[1], q[2], q[3], q[0])
	check((orientation * Vector3(1, 0, 0)).distance_to(Simulation.forward(sim.yaw, sim.pitch)) < 1e-6,
		"wxyz feedback quaternion maps gimbal forward into RM world")
	check(JSON.parse_string(JSON.stringify(snapshot)) is Dictionary, "telemetry is JSON serializable")


func _test_bridge() -> void:
	var sim = Simulation.new(base_settings())
	var bridge = Bridge.new()
	bridge.model = sim
	bridge.enabled = true
	var packet = {"protocol": "rm_aim_sim/2", "type": "command", "session_id": sim.session_id,
		"seq": 0, "control": true, "fire": true, "yaw": 0.0, "pitch": 0.0}
	check(bridge.accept_command(packet, 1000000), "valid external command accepted")
	check(not bridge.accept_command(packet, 1000010), "duplicate sequence rejected")
	packet.seq = 1
	packet.yaw = "0"
	check(not bridge.accept_command(packet, 1000020), "text angle rejected")
	packet.yaw = NAN
	check(not bridge.accept_command(packet, 1000020), "nonfinite command rejected")
	packet.yaw = 0
	packet.fire = 1
	check(not bridge.accept_command(packet, 1000020), "nonboolean fire rejected")
	packet.fire = true
	packet.session_id = "old-session"
	check(not bridge.accept_command(packet, 1000020), "old-session command rejected")
	packet.session_id = sim.session_id
	packet.seq = 1.5
	check(not bridge.accept_command(packet, 1000020), "fractional sequence rejected")
	packet.seq = 2
	sim.paused = true
	check(not bridge.accept_command(packet, 1000020), "commands rejected during pause")
	sim.paused = false
	bridge.check_timeout(1300000)
	check(not sim.command.control and not sim.command.fire and sim.pending.is_empty(), "watchdog clears control, fire and pending launches")
	bridge.close()
