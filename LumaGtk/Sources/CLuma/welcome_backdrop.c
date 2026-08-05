#include "include/CLuma.h"

static const char *welcome_backdrop_fragment_src =
    "float plasmaField(vec2 p, float t) {\n"
    "    float v = sin(p.x * 3.0 + t * 0.55);\n"
    "    v += sin(p.y * 2.7 - t * 0.42);\n"
    "    v += sin((p.x + p.y) * 1.9 + t * 0.38);\n"
    "    vec2 c = vec2(sin(t * 0.27), cos(t * 0.31)) * 1.4;\n"
    "    v += sin(length(p * 1.6 - c) * 4.2 - t * 0.65);\n"
    "    return v * 0.25;\n"
    "}\n"
    "void main() {\n"
    "    float aspect = u_resolution.x / max(u_resolution.y, 1.0);\n"
    "    vec2 p = v_uv * 2.0 - 1.0;\n"
    "    p.x *= aspect;\n"
    "    float v = plasmaField(p, u_time);\n"
    "    float n = v * 0.5 + 0.5;\n"
    "    const vec3 LIGHT_A = vec3(0.965, 0.935, 0.905);\n"
    "    const vec3 LIGHT_B = vec3(0.085, 0.110, 0.130);\n"
    "    const vec3 LIGHT_D = vec3(0.00, 0.10, 0.22);\n"
    "    const vec3 DARK_A  = vec3(0.180, 0.105, 0.135);\n"
    "    const vec3 DARK_B  = vec3(0.520, 0.230, 0.205);\n"
    "    const vec3 DARK_D  = vec3(0.00, 0.14, 0.30);\n"
    "    vec3 lightColor = LIGHT_A + LIGHT_B * cos(6.28318 * (n + LIGHT_D));\n"
    "    vec3 darkColor  = DARK_A  + DARK_B  * cos(6.28318 * (n + DARK_D));\n"
    "    float band = sin(v * 9.0 + u_time * 0.6);\n"
    "    float contour = smoothstep(0.86, 1.0, band);\n"
    "    lightColor -= contour * 0.020;\n"
    "    darkColor  += contour * vec3(0.060, 0.022, 0.018);\n"
    "    float ripple = sin(p.x * 1.8 - p.y * 1.2 + u_time * 0.9) * 0.5 + 0.5;\n"
    "    lightColor = mix(lightColor, lightColor * 0.985, ripple * 0.20);\n"
    "    darkColor  = mix(darkColor,  darkColor  * 1.080, ripple * 0.22);\n"
    "    float grain = fract(sin(dot(v_uv * u_resolution, vec2(12.9898, 78.233))) * 43758.5453);\n"
    "    lightColor += (grain - 0.5) * 0.008;\n"
    "    darkColor  += (grain - 0.5) * 0.014;\n"
    "    float vignette = smoothstep(1.70, 0.45, length(p * vec2(0.85, 1.0)));\n"
    "    lightColor *= mix(0.96, 1.0, vignette);\n"
    "    darkColor  *= mix(0.55, 1.0, vignette);\n"
    "    vec3 color = mix(darkColor, lightColor, u_scheme);\n"
    "    frag_color = vec4(color, 1.0);\n"
    "}\n";

void *
luma_welcome_backdrop_new(void)
{
    void *widget = luma_shader_effect_new(welcome_backdrop_fragment_src);
    luma_welcome_backdrop_set_dark(widget, false);
    return widget;
}

void
luma_welcome_backdrop_set_dark(void *widget, bool dark)
{
    luma_shader_effect_set_scheme(widget, dark ? 0.0f : 1.0f);
    if (dark)
        luma_shader_effect_set_clear_color(widget, 0.075f, 0.050f, 0.065f);
    else
        luma_shader_effect_set_clear_color(widget, 0.994f, 0.991f, 0.986f);
}
