float plasmaField(vec2 p, float t) {
    float v = sin(p.x * 3.0 + t * 0.55);
    v += sin(p.y * 2.7 - t * 0.42);
    v += sin((p.x + p.y) * 1.9 + t * 0.38);
    vec2 c = vec2(sin(t * 0.27), cos(t * 0.31)) * 1.4;
    v += sin(length(p * 1.6 - c) * 4.2 - t * 0.65);
    return v * 0.25;
}

void main() {
    float aspect = u_resolution.x / max(u_resolution.y, 1.0);
    vec2 p = v_uv * 2.0 - 1.0;
    p.x *= aspect;

    float v = plasmaField(p, u_time);
    float n = v * 0.5 + 0.5;

    // IQ cosine palettes -- low-amplitude cream->coral for light,
    // deep plum->coral->ember for dark.
    const vec3 LIGHT_A = vec3(0.965, 0.935, 0.905);
    const vec3 LIGHT_B = vec3(0.085, 0.110, 0.130);
    const vec3 LIGHT_D = vec3(0.00, 0.10, 0.22);

    const vec3 DARK_A = vec3(0.180, 0.105, 0.135);
    const vec3 DARK_B = vec3(0.520, 0.230, 0.205);
    const vec3 DARK_D = vec3(0.00, 0.14, 0.30);

    vec3 lightColor = LIGHT_A + LIGHT_B * cos(6.28318 * (n + LIGHT_D));
    vec3 darkColor = DARK_A + DARK_B * cos(6.28318 * (n + DARK_D));

    // Soft scanline contour -- quiet demoscene callback.
    float band = sin(v * 9.0 + u_time * 0.6);
    float contour = smoothstep(0.86, 1.0, band);
    lightColor -= contour * 0.020;
    darkColor += contour * vec3(0.060, 0.022, 0.018);

    // Travelling sine ripple, nudges plasma slightly so it doesn't loop visibly.
    float ripple = sin(p.x * 1.8 - p.y * 1.2 + u_time * 0.9) * 0.5 + 0.5;
    lightColor = mix(lightColor, lightColor * 0.985, ripple * 0.20);
    darkColor = mix(darkColor, darkColor * 1.080, ripple * 0.22);

    // Tiny grain so flat regions never look dead.
    float grain = fract(sin(dot(v_uv * u_resolution, vec2(12.9898, 78.233))) * 43758.5453);
    lightColor += (grain - 0.5) * 0.008;
    darkColor += (grain - 0.5) * 0.014;

    // Editorial vignette.
    float vignette = smoothstep(1.70, 0.45, length(p * vec2(0.85, 1.0)));
    lightColor *= mix(0.96, 1.0, vignette);
    darkColor *= mix(0.55, 1.0, vignette);

    vec3 color = mix(darkColor, lightColor, u_scheme);
    frag_color = vec4(color, 1.0);
}
