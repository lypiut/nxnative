// The present: the frame drawn into the drawable, cropped (nvn_mtl.m present_pipeline)
#include <metal_stdlib>
using namespace metal;
struct V { float4 p [[position]]; float2 uv; };
vertex V vs(uint id [[vertex_id]]) { float2 uv = float2((id << 1) & 2, id & 2); V o; o.p = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1); o.uv = uv; return o; }
struct Crop { float4 rect; float4 edge; float4 mode; float4 xf; };
// fs is the original SDR pass and is byte-for-byte unchanged: its 8 floats are the crop and the edge clamps.
fragment float4 fs(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant Crop& c [[buffer(0)]]) { return t.sample(s, clamp(in.uv * c.rect.zw + c.rect.xy, c.edge.xy, c.edge.zw)); }

// HDR output (DM_HDR). mode.x selects the conversion, so one pipeline per drawable format is enough:
//   0 pass through (only used with an HDR source into a PQ drawable, which needs no conversion at all);
//   1 an HDR10 source (RGB10A2, PQ code values of BT.2020) into an SDR target (a screenshot, or a drawable
//     still in the SDR format during a layer switch): BT.709, then a shoulder into SDR white;
//   2 an SDR source into the PQ drawable (the frames before the game switches its window): decode, convert
//     to BT.2020 and encode PQ with the paper white at EDR 1.0.
//   4 an HDR10 source into the PQ drawable with a controlled roll-off of highlights the screen cannot show.
//   5 a linear-light HDR source (RGBA16Float, nits / 10000) from MetalFX's HDR scaler into the PQ drawable:
//     PQ-encode once here, after the scaler and any roll-off, so MetalFX never sees PQ code values.
// mode.y = paper white in nits; mode.z/w = roll-off knee / target in nits. xf.x = source peak (nits for 4/5,
// paper whites for 1), xf.y = knee as a PQ code value, xf.z = the SDR picture's display gamma (0 = sRGB).
// Linear-light primaries (ITU-R BT.2087); Metal's float3x3 takes its columns. Applied to linear light only,
// never to PQ codes.
constant float3x3 kRec709To2020 = float3x3(float3(0.627404, 0.069097, 0.016391), float3(0.329283, 0.919540, 0.088013), float3(0.043313, 0.011362, 0.895595));
constant float3x3 kRec2020To709 = float3x3(float3(1.660491, -0.124550, -0.018151), float3(-0.587641, 1.132900, -0.100579), float3(-0.072850, -0.008349, 1.118730));
static inline float3 present_sdr_to_linear(float3 c, float g) {
    if (g > 0.0) return pow(max(c, float3(0.0)), float3(g));
    float3 lo = c * (1.0 / 12.92);
    float3 hi = pow((c + 0.055) * (1.0 / 1.055), float3(2.4));
    return select(hi, lo, c <= 0.04045);
}
static inline float3 present_linear_to_sdr(float3 l, float g) {
    if (g > 0.0) return pow(max(l, float3(0.0)), float3(1.0 / g));
    float3 lo = l * 12.92;
    float3 hi = 1.055 * pow(l, float3(1.0 / 2.4)) - 0.055;
    return select(hi, lo, l <= 0.0031308);
}
// SMPTE ST 2084: code value to absolute luminance in nits, and back. The pow bases are clamped because the
// host's shader compiler uses fast math.
static inline float3 present_pq_eotf(float3 e) {
    const float m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875;
    float3 p = pow(max(e, float3(0.0)), float3(1.0 / m2));
    float3 num = max(p - c1, float3(0.0)), den = max(c2 - c3 * p, float3(1e-6));
    return 10000.0 * pow(num / den, float3(1.0 / m1));
}
static inline float3 present_pq_inverse(float3 nits) {
    const float m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875;
    float3 y = pow(clamp(nits / 10000.0, float3(1e-8), float3(1.0)), float3(m1));
    return pow((c1 + c2 * y) / (1.0 + c3 * y), float3(m2));
}
// Rational shoulder: slope 1 at the knee, the source peak lands exactly on the target; the brightest
// channel scales all three so the hue is kept. The CPU mirror is hdr.h's hdr_shoulder.
static inline float3 present_shoulder(float3 n, float k, float t, float s) {
    float m = max(max(n.r, n.g), n.b);
    if (!(m > k)) return n;
    float a = t - k, x = m - k;
    if (!(a > 0)) return float3(t);
    float f = min(k + x / (1.0 + x * (1.0 / a - 1.0 / max(s - k, a))), t);
    return n * (f / m);
}
fragment float4 fs_hdr(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant Crop& c [[buffer(0)]]) {
    float4 v = t.sample(s, clamp(in.uv * c.rect.zw + c.rect.xy, c.edge.xy, c.edge.zw));
    if (c.mode.x > 3.5) {   // HDR10 -> PQ drawable with a roll-off above the screen's current headroom
        if (max(max(v.r, v.g), v.b) > c.xf.y) {
            float3 nits = present_pq_eotf(v.rgb);
            if (max(max(nits.r, nits.g), nits.b) > c.mode.z)
                v.rgb = present_pq_inverse(present_shoulder(nits, c.mode.z, c.mode.w, c.xf.x));
        }
    } else if (c.mode.x > 1.5) {   // SDR -> PQ drawable: the paper white becomes the screen's ordinary white
        float3 l709 = present_sdr_to_linear(v.rgb, c.xf.z);
        v = float4(present_pq_inverse(kRec709To2020 * l709 * c.mode.y), 1.0);
    } else if (c.mode.x > 0.5) {   // HDR10 -> SDR (screenshots and transition frames)
        float3 l709 = max(kRec2020To709 * (present_pq_eotf(v.rgb) / c.mode.y), float3(0.0));
        l709 = present_shoulder(l709, 0.75, 1.0, c.xf.x);
        v = float4(present_linear_to_sdr(saturate(l709), c.xf.z), 1.0);
    }
    return v;
}

// MetalFX's HDR mode takes linear-light input (its SDK header: HDR values beyond [0,1], with a reversible
// tone map into [0,1]); PQ code values are neither. Decode the game's BT.2020 PQ window here at SOURCE
// resolution into RGBA16Float, normalised to PQ full scale (10000 nits = 1.0). Alpha is untouched.
// c.mode.x holds the luminance scale (10000 nits); c.rect/c.edge are the crop and half-texel clamps.
fragment float4 fs_pq_decode(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant Crop& c [[buffer(0)]]) {
    float4 v = t.sample(s, clamp(in.uv * c.rect.zw + c.rect.xy, c.edge.xy, c.edge.zw));
    return float4(present_pq_eotf(v.rgb) / max(c.mode.x, 1.0f), v.a);
}

// The last pass of the opt-in MetalFX HDR path: the scaler's linear-light result (nits / 10000)
// becomes nits, gets the same single headroom-aware shoulder the bilinear path uses, and is PQ-encoded once.
fragment float4 fs_hdr_fx(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant Crop& c [[buffer(0)]]) {
    float4 v = t.sample(s, clamp(in.uv * c.rect.zw + c.rect.xy, c.edge.xy, c.edge.zw));
    float3 nits = max(v.rgb, float3(0.0)) * c.mode.y;
    if (c.xf.x > 0.0f) nits = present_shoulder(nits, c.mode.z, c.mode.w, c.xf.x);
    return float4(present_pq_inverse(nits), v.a);
}
