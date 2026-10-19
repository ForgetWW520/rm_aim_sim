shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_back, shadows_disabled, fog_disabled;

uniform vec4 team_color : source_color = vec4(0.0, 0.157, 1.0, 1.0);
uniform vec4 core_color : source_color = vec4(0.863, 0.980, 1.0, 1.0);
uniform float lamp_width = 0.005;
uniform float lamp_length = 0.056;
uniform vec2 plane_size = vec2(0.025, 0.076);

void fragment() {
	vec2 point = abs((UV - vec2(0.5)) * plane_size);
	vec2 outside = max(point - vec2(lamp_width, lamp_length) * 0.5, vec2(0.0));
	float distance_to_lamp = length(outside);
	// Local glare approximates camera bloom without a full-screen post-process.
	float halo = exp(-distance_to_lamp / 0.0025);
	// Only the lamp center approaches white; the surrounding glow retains the team hue.
	float core = (1.0 - smoothstep(lamp_width * 0.15, lamp_width * 0.5, point.x))
		* (1.0 - smoothstep(lamp_length * 0.43, lamp_length * 0.5, point.y));
	ALBEDO = mix(team_color.rgb, core_color.rgb, core);
	ALPHA = 0.8 * halo * smoothstep(0.012, 0.008, distance_to_lamp);
}
