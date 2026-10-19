extends RefCounted


static func load_model(path: String) -> Node3D:
	if path.is_empty():
		return null
	if not FileAccess.file_exists(path):
		push_warning("Model does not exist: " + path)
		return null
	if path.get_extension().to_lower() in ["glb", "gltf"]:
		var document = GLTFDocument.new()
		var state = GLTFState.new()
		if document.append_from_file(path, state) == OK:
			return document.generate_scene(state)
	elif path.begins_with("res://") and path.get_extension() == "tscn":
		var resource = load(path)
		if resource is PackedScene:
			var node = resource.instantiate()
			if node is Node3D:
				return node
			node.free()
	push_warning("Cannot load 3D model: " + path)
	return null


static func mesh_bounds(root: Node3D) -> AABB:
	var result = AABB()
	var found = false
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node = stack.pop_back()
		if node is MeshInstance3D and node.mesh != null:
			var relative = Transform3D.IDENTITY
			var current: Node = node
			while current != root:
				if current is Node3D:
					relative = current.transform * relative
				current = current.get_parent()
			var box: AABB = relative * node.get_aabb()
			result = result.merge(box) if found else box
			found = true
		for child in node.get_children():
			stack.append(child)
	return result


static func fit_model(root: Node3D, size: float, factor: float, armor: bool) -> Node3D:
	var box = mesh_bounds(root)
	var extent = box.size.x if armor else maxf(box.size.x, box.size.z)
	var scale_factor = size / maxf(extent, 0.001) * factor
	var wrapper = Node3D.new()
	wrapper.add_child(root)
	root.scale *= scale_factor
	root.position = -box.get_center() * scale_factor
	return wrapper


static func tint_named_surfaces(root: Node, material: Material) -> void:
	if root is MeshInstance3D:
		var node_name = String(root.name).to_lower()
		if node_name.contains("team") or node_name.contains("lightbar"):
			root.material_override = material
	for child in root.get_children():
		tint_named_surfaces(child, material)
