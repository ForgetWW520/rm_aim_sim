shader_type canvas_item;
render_mode unshaded;

uniform sampler2D camera_texture : repeat_disable, filter_nearest;
uniform float brightness_gain : hint_range(0.0, 4.0) = 0.4;
uniform int lamp_count = 0;
uniform vec4 lamp_segments[8];
uniform float lamp_widths[8];
uniform vec4 lamp_color : source_color = vec4(0.0, 0.157, 1.0, 1.0);
uniform vec4 core_color : source_color = vec4(0.863, 0.980, 1.0, 1.0);

vec3 to_linear(vec3 srgb) {
	return mix(srgb / 12.92, pow((srgb + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), srgb));
}

vec3 to_srgb(vec3 linear_rgb) {
	return mix(linear_rgb * 12.92, 1.055 * pow(linear_rgb, vec3(1.0 / 2.4)) - 0.055,
		step(vec3(0.0031308), linear_rgb));
}

void fragment() {
	vec3 radiance = to_linear(textureLod(camera_texture, UV, 0.0).rgb);
	vec3 emission = vec3(0.0);
	vec2 pixel = UV / SCREEN_PIXEL_SIZE;
	for (int i = 0; i < 8; i++) {
		if (i >= lamp_count) {
			break;
		}
		vec2 start = lamp_segments[i].xy;
		vec2 end = lamp_segments[i].zw;
		float length_px = length(end - start);
		vec2 axis = (end - start) / max(length_px, 0.001);
		vec2 relative = pixel - (start + end) * 0.5;
		float across = abs(dot(relative, vec2(-axis.y, axis.x)));
		float along = abs(dot(relative, axis));
		float width_px = max(lamp_widths[i], 0.25);
		vec2 outside = max(vec2(across - width_px * 0.5, along - length_px * 0.5), vec2(0.0));
		float halo = exp(-length(outside) / max(width_px * 0.5, 0.5));
		float core = (1.0 - smoothstep(width_px * 0.15, width_px * 0.6, across))
			* (1.0 - smoothstep(length_px * 0.43, length_px * 0.5 + 0.5, along));
		// Keep LED energy above sensor saturation until after exposure. Printed white stays reflective.
		emission += lamp_color.rgb * (3.0 * halo) + core_color.rgb * (24.0 * core);
	}
	// The Compatibility renderer has already clipped highlights, so geometric LED emission supplies
	// their missing dynamic range. This is a simplified sensor model, not calibrated optical HDR.
	radiance = max(radiance, emission);
	vec3 exposed = clamp(radiance * brightness_gain, vec3(0.0), vec3(1.0));
	COLOR = vec4(to_srgb(exposed), 1.0);
}
