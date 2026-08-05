#include <metal_stdlib>
using namespace metal;

// Screen-filling quad shared by every effect. The interpolant carries the
// locn0 attribute that the generated fragment functions declare their
// stage_in against.
struct ShaderEffectVertexOut {
    float4 position [[position]];
    float2 v_uv [[user(locn0)]];
};

vertex ShaderEffectVertexOut shaderEffectVertex(uint vid [[vertex_id]]) {
    const float2 positions[4] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2( 1.0,  1.0),
    };
    ShaderEffectVertexOut out;
    out.position = float4(positions[vid], 0.0, 1.0);
    out.v_uv = positions[vid] * 0.5 + 0.5;
    return out;
}
