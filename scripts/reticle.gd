extends Control

var tint = Color(0.65, 0.95, 0.9, 0.85)


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(queue_redraw)


func _draw() -> void:
	var center = size * 0.5
	for side in [-1, 1]:
		draw_line(center + Vector2(side * 7, 0), center + Vector2(side * 22, 0), tint, 1.0, true)
		draw_line(center + Vector2(0, side * 7), center + Vector2(0, side * 22), tint, 1.0, true)
	draw_circle(center, 1.5, tint)
