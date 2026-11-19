// Metal source is compiled at launch so the app builds with a plain `swift build`,
// without depending on the optional offline Metal toolchain.
enum Shaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct LayerUniforms {
        float4 destRect;     // x, y, w, h in target pixels (top-left origin)
        float4 uvRect;       // u0, v0, u1, v1
        float2 targetSize;
        float2 texSize;
        float4 color;        // solid colour (mode 2) or backdrop for premultiplied sources (mode 0)
        float4 borderColor;
        float radius;
        float opacity;
        float shadowRadius;
        float borderWidth;
        int mode;            // 0 textured, 1 shadow, 2 solid
    };

    struct VOut {
        float4 position [[position]];
        float2 local;
        float2 uv;
    };

    vertex VOut layer_vertex(uint vid [[vertex_id]], constant LayerUniforms &u [[buffer(0)]]) {
        const float2 corners[4] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1) };
        float2 c = corners[vid];
        float pad = (u.mode == 1) ? u.shadowRadius * 2.0 : 1.0;
        float2 origin = u.destRect.xy - pad;
        float2 size = u.destRect.zw + 2.0 * pad;
        float2 p = origin + c * size;
        VOut o;
        o.position = float4(p.x / u.targetSize.x * 2.0 - 1.0, 1.0 - p.y / u.targetSize.y * 2.0, 0.0, 1.0);
        o.local = p - (u.destRect.xy + u.destRect.zw * 0.5);
        float2 t = (p - u.destRect.xy) / max(u.destRect.zw, float2(1.0));
        o.uv = mix(u.uvRect.xy, u.uvRect.zw, t);
        return o;
    }

    static float sdRoundRect(float2 p, float2 halfSize, float r) {
        float2 q = abs(p) - halfSize + r;
        return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
    }

    fragment float4 layer_fragment(VOut in [[stage_in]],
                                   constant LayerUniforms &u [[buffer(0)]],
                                   texture2d<float> tex [[texture(0)]],
                                   sampler smp [[sampler(0)]]) {
        float2 halfSize = u.destRect.zw * 0.5;
        float r = min(u.radius, min(halfSize.x, halfSize.y));
        float d = sdRoundRect(in.local, halfSize, r);

        if (u.mode == 1) {
            float s = max(u.shadowRadius, 1.0);
            float a = 1.0 - smoothstep(-s * 0.5, s * 1.6, d);
            a = a * a;
            return float4(0.0, 0.0, 0.0, a * u.opacity);
        }

        float2 uv = in.uv;
        float2 dx = dfdx(uv);
        float2 dy = dfdy(uv);
        float coverage = clamp(0.5 - d, 0.0, 1.0);

        float4 c;
        if (u.mode == 2) {
            c = float4(u.color.rgb, 1.0);
        } else {
            float footprint = max(length(dx * u.texSize), length(dy * u.texSize));
            if (footprint > 1.4) {
                // Rotated-grid supersampling keeps downscaled text from shimmering.
                c = 0.25 * (tex.sample(smp, uv + 0.125 * dx + 0.375 * dy) +
                            tex.sample(smp, uv - 0.375 * dx + 0.125 * dy) +
                            tex.sample(smp, uv + 0.375 * dx - 0.125 * dy) +
                            tex.sample(smp, uv - 0.125 * dx - 0.375 * dy));
            } else {
                c = tex.sample(smp, uv);
            }
            c = float4(c.rgb + u.color.rgb * (1.0 - c.a), 1.0);
        }

        if (u.borderWidth > 0.0) {
            float inner = clamp(0.5 - (d + u.borderWidth), 0.0, 1.0);
            c.rgb = mix(u.borderColor.rgb, c.rgb, inner);
        }

        float a = coverage * u.opacity;
        return float4(c.rgb * a, a);
    }
    """
}
