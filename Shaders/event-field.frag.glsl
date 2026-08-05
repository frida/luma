float bands(vec2 p, float t, float speed) {
    float v = sin(p.y * 8.0 - t * speed);
    v += sin(p.y * 3.0 + p.x * 0.6 + t * speed * 0.55) * 0.7;
    return v * 0.4;
}

void main() {
    float aspect = u_resolution.x / max(u_resolution.y, 1.0);
    vec2 p = v_uv * 2.0 - 1.0;
    p.x *= aspect;

    float speed = 0.35 + u_activity * 2.4;
    float v = bands(p, u_time, speed);
    float n = v * 0.5 + 0.5;

    const vec3 LIGHT_A = vec3(0.980, 0.968, 0.958);
    const vec3 LIGHT_B = vec3(0.022, 0.030, 0.038);
    const vec3 LIGHT_D = vec3(0.00, 0.10, 0.22);

    const vec3 DARK_A = vec3(0.105, 0.082, 0.098);
    const vec3 DARK_B = vec3(0.055, 0.030, 0.032);
    const vec3 DARK_D = vec3(0.00, 0.14, 0.30);

    vec3 lightColor = LIGHT_A + LIGHT_B * cos(6.28318 * (n + LIGHT_D));
    vec3 darkColor = DARK_A + DARK_B * cos(6.28318 * (n + DARK_D));

    // Each arrival blooms outward from the leading edge, then fades.
    float front = 1.0 - u_pulse;
    float ring = smoothstep(0.35, 0.0, abs(length(p * vec2(0.6, 1.0)) - front * 1.8));
    float bloom = ring * u_pulse * 0.6;
    lightColor -= bloom * vec3(0.030, 0.045, 0.022);
    darkColor += bloom * vec3(0.090, 0.038, 0.030);

    // Quiet sessions settle toward the flat page colour.
    float presence = 0.25 + u_activity * 0.75;
    lightColor = mix(LIGHT_A, lightColor, presence);
    darkColor = mix(DARK_A, darkColor, presence);

    float grain = fract(sin(dot(v_uv * u_resolution, vec2(12.9898, 78.233))) * 43758.5453);
    lightColor += (grain - 0.5) * 0.004;
    darkColor += (grain - 0.5) * 0.010;

    vec3 color = mix(darkColor, lightColor, u_scheme);
    frag_color = vec4(color, 1.0);
}
