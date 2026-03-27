#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float2 position [[attribute(0)]];
    float4 color    [[attribute(1)]];
};

struct VertexOut {
    float4 position [[position]];
    float4 color;
};

vertex VertexOut cfgVertexShader(
    uint vid [[vertex_id]],
    const device VertexIn *vertices [[buffer(0)]]
) {
    VertexOut out;
    out.position = float4(vertices[vid].position, 0.0, 1.0);
    out.color = vertices[vid].color;
    return out;
}

fragment float4 cfgFragmentShader(VertexOut in [[stage_in]]) {
    return in.color;
}
