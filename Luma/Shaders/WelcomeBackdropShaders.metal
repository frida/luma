#include <metal_stdlib>
using namespace metal;

struct BackdropVertexOut {
    float4 position [[position]];
    float2 uv;
};

struct BackdropUniforms {
    float2 resolution;
    float time;
    float scheme; // 0 = dark plum, 1 = light cream
};

vertex BackdropVertexOut welcomeBackdropVertex(uint vid [[vertex_id]]) {
    const float2 positions[4] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2( 1.0,  1.0),
    };
    BackdropVertexOut out;
    out.position = float4(positions[vid], 0.0, 1.0);
    out.uv = positions[vid] * 0.5 + 0.5;
    return out;
}

static float seed(int i, float k) {
    return fract(sin(float(i) * k) * 43758.5453);
}

fragment float4 welcomeBackdropFragment(
    BackdropVertexOut in [[stage_in]],
    constant BackdropUniforms &u [[buffer(0)]]
) {
    // frida.re palette.
    const float3 CORAL      = float3(0.937, 0.392, 0.337); // #EF6456
    const float3 CORAL_DEEP = float3(0.820, 0.290, 0.235); // deeper for cores on white
    const float3 PLUM       = float3(0.369, 0.298, 0.353); // #5E4C5A
    const float3 LIGHT_TOP  = float3(1.000, 1.000, 0.998); // pure white, faint warmth
    const float3 LIGHT_BOT  = float3(0.988, 0.982, 0.974);
    const float3 DARK_TOP   = float3(0.155, 0.115, 0.140); // warm plum
    const float3 DARK_BOT   = float3(0.075, 0.050, 0.065); // deep plum

    float aspect = u.resolution.x / max(u.resolution.y, 1.0);
    float2 p = in.uv * 2.0 - 1.0;
    p.x *= aspect;

    float3 lightColor = mix(LIGHT_BOT, LIGHT_TOP, in.uv.y);
    float3 darkColor  = mix(DARK_BOT,  DARK_TOP,  in.uv.y);

    // Rising motes — events drifting up out of the instrumented process.
    constexpr int NUM = 22;
    for (int i = 0; i < NUM; ++i) {
        float s1 = seed(i, 12.93);
        float s2 = seed(i, 78.23);
        float s3 = seed(i,  5.41);
        float s4 = seed(i, 91.71);

        float speed = 0.018 + 0.030 * s1;
        float life = fract(u.time * speed + s2);

        float xBase = (-1.0 + 2.0 * s3) * aspect;
        float xWobble = 0.04 + 0.10 * s4;
        float x = xBase + xWobble * sin(u.time * (0.10 + 0.18 * s1) + s2 * 6.2832);
        float y = -1.18 + life * 2.36;

        float coreR = 0.006 + 0.007 * s4;
        float haloR = 0.060 + 0.090 * s1;

        float r = length(float2(x, y) - p);
        float core = 1.0 - smoothstep(0.0, coreR, r);
        float halo = pow(1.0 - smoothstep(0.0, haloR, r), 2.2);
        float fade = smoothstep(0.0, 0.18, life) * (1.0 - smoothstep(0.82, 1.0, life));

        bool isPlum = s4 > 0.80;
        float3 lightHue = isPlum ? PLUM : CORAL_DEEP;
        float3 lightHalo = isPlum ? PLUM : CORAL;

        // Light: mix toward a deeper coral for cores (so they punch on white),
        // softer chromatic halo via mix (additive blows out instantly on white).
        lightColor = mix(lightColor, lightHue, core * fade * 0.70);
        lightColor = mix(lightColor, lightHalo, halo * fade * 0.32);

        // Dark: additive bloom so cores glow as embers; plum motes brighten so
        // they're visible against the plum bg.
        float3 darkHue = isPlum ? mix(PLUM, CORAL, 0.55) : CORAL;
        darkColor += darkHue * core * fade * 0.95;
        darkColor += darkHue * halo * fade * 0.35;
    }

    // Slow coral filament — soft horizontal ribbon drifting upper third.
    float ribY = 0.45 + 0.18 * sin(u.time * 0.025);
    float ribX = sin(p.x * 1.1 + u.time * 0.018);
    float ribDist = (p.y - ribY) + 0.06 * ribX;
    float ribbon = exp(-ribDist * ribDist * 32.0);
    lightColor += CORAL * ribbon * 0.05;
    darkColor  += CORAL * ribbon * 0.12;

    // Tiny film grain so neither background looks dead.
    float grain = fract(sin(dot(in.uv * u.resolution, float2(12.9898, 78.233))) * 43758.5453);
    lightColor += (grain - 0.5) * 0.008;
    darkColor  += (grain - 0.5) * 0.012;

    // Editorial vignette.
    float vignette = smoothstep(1.60, 0.45, length(p * float2(0.85, 1.0)));
    lightColor *= mix(0.96, 1.0, vignette);
    darkColor  *= mix(0.65, 1.0, vignette);

    float3 color = mix(darkColor, lightColor, u.scheme);

    return float4(color, 1.0);
}
