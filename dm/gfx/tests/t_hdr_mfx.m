// MetalFX HDR investigation: which input/output formats does the installed SDK accept for the Spatial
// scaler's HDR / linear / perceptual colour processing modes? Creation only, no game and no frame loop.
// Informational: it prints a table and succeeds when at least one HDR configuration is accepted.
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#include <stdio.h>

int main(void) {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) { fprintf(stderr, "no Metal device\n"); return 2; }
        NSError *e = nil;
        id<MTL4Compiler> comp = [dev newCompilerWithDescriptor:[MTL4CompilerDescriptor new] error:&e];
        if (!comp) { fprintf(stderr, "no Metal 4 compiler: %s\n", e.localizedDescription.UTF8String); return 2; }
        printf("MetalFX supportsMetal4FX: %d\n", [MTLFXSpatialScalerDescriptor supportsMetal4FX:dev]);
        struct { const char *name; MTLPixelFormat in, out; MTLFXSpatialScalerColorProcessingMode mode; } cases[] = {
            {"RGB10A2 -> RGB10A2, HDR",        MTLPixelFormatRGB10A2Unorm, MTLPixelFormatRGB10A2Unorm, MTLFXSpatialScalerColorProcessingModeHDR},
            {"RGB10A2 -> RGB10A2, perceptual", MTLPixelFormatRGB10A2Unorm, MTLPixelFormatRGB10A2Unorm, MTLFXSpatialScalerColorProcessingModePerceptual},
            {"RGBA16F -> RGBA16F, HDR",        MTLPixelFormatRGBA16Float,  MTLPixelFormatRGBA16Float,  MTLFXSpatialScalerColorProcessingModeHDR},
            {"RGBA16F -> RGB10A2, HDR",        MTLPixelFormatRGBA16Float,  MTLPixelFormatRGB10A2Unorm, MTLFXSpatialScalerColorProcessingModeHDR},
            {"RGB10A2 -> RGBA16F, HDR",        MTLPixelFormatRGB10A2Unorm, MTLPixelFormatRGBA16Float,  MTLFXSpatialScalerColorProcessingModeHDR},
            {"RGBA16F -> RGBA16F, linear",     MTLPixelFormatRGBA16Float,  MTLPixelFormatRGBA16Float,  MTLFXSpatialScalerColorProcessingModeLinear},
            {"BGRA8 -> BGRA8, perceptual",     MTLPixelFormatBGRA8Unorm,   MTLPixelFormatBGRA8Unorm,   MTLFXSpatialScalerColorProcessingModePerceptual},
        };
        int hdr_ok = 0, pq_pq_hdr = 0, f16_f16_hdr = 0;
        for (unsigned i = 0; i < sizeof cases / sizeof *cases; i++) {
            MTLFXSpatialScalerDescriptor *d = [MTLFXSpatialScalerDescriptor new];
            d.inputWidth = 64; d.inputHeight = 36; d.outputWidth = 128; d.outputHeight = 72;
            d.colorTextureFormat = cases[i].in; d.outputTextureFormat = cases[i].out;
            d.colorProcessingMode = cases[i].mode;
            id<MTL4FXSpatialScaler> sc = [d newSpatialScalerWithDevice:dev compiler:comp];
            printf("%-36s : %s\n", cases[i].name, sc ? "accepted" : "refused");
            if (sc && cases[i].mode == MTLFXSpatialScalerColorProcessingModeHDR) hdr_ok = 1;
            if (i == 0 && sc) pq_pq_hdr = 1;   // the old direct-PQ experiment, kept as a format fact
            if (i == 2 && sc) f16_f16_hdr = 1; // the linear-light pipeline's RGBA16F -> RGBA16F HDR scaler
        }
        // This is a format-support check, not a correctness claim: t_present_crop measures the overshoot
        // that makes the experimental path unsuitable. Acceptance itself only needs Metal 4 support.
        if (![MTLFXSpatialScalerDescriptor supportsMetal4FX:dev]) {
            printf("== Metal 4 FX unsupported on this GPU: HDR scaler format check skipped ==\n");
            return 0;
        }
        printf("== HDR-mode scaler accepted: %s; RGB10A2 PQ -> PQ HDR: %s; RGBA16F -> RGBA16F HDR (linear pipeline): %s ==\n",
               hdr_ok ? "yes" : "no", pq_pq_hdr ? "yes" : "no", f16_f16_hdr ? "yes" : "no");
        printf("== acceptance proves format support only; t_present_crop measures colour and reconstruction ==\n");
        return (pq_pq_hdr && f16_f16_hdr) ? 0 : 1;
    }
}
