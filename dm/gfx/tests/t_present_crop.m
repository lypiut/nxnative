// Present crop regression: colored 8×8 texture, closed-form RGBA expectations; real Metal rendering, no dependence on the game or on cross-run determinism.
// nvn_mtl.m's nvn_game_fps is a weak default and hle_nvn.c gives the strong definition; in one translation unit that is a redefinition, so the weak one is renamed (this test does not look at the frame-rate target)
#define nvn_game_fps nvn_game_fps_mtl_default
#include "../nvn/nvn_mtl.m"
#undef nvn_game_fps
#define g_ft g_ft_hle   // both files have a static g_ft (nvn_mtl.m's fragment argument table, hle_nvn.c's textures a flush can mark CPU-written), so hle_nvn.c's is renamed too
#include "../nvn/hle_nvn.c"
#undef g_ft
#include <assert.h>
int dm_hdr_fx_test_fault;   // strong override of nvn_mtl.m's weak test-only fault injection (0 in production)
uint64_t g_t0_ns;   // process start time from host main.c (used by hle_nvn's per-frame @t_s); unit test stub
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int g_layer_crop[4];   // what the vi layer crop (hle_vi.c) answers: x, y, w, h, all 0 = none
void dm_vi_layer_crop(int c[4]) { memcpy(c, g_layer_crop, sizeof g_layer_crop); }
#ifdef CROP_LEGACY_HEADER
#include CROP_LEGACY_HEADER
#define ENCODE legacy_present_encode
#else
#define ENCODE present_encode
#endif
static int failed, cases;
#define EXPECT(n, w, v) do { int a=(w),b=(v); cases++; printf("%s expected %d → got %d %s\n",n,a,b,a==b?"✓":"✗");failed+=a!=b; } while(0)

#ifndef CROP_LEGACY_HEADER
// HDR present fixtures: a texture of one texel, a present into a canvas of a chosen format, and its centre
// pixel (8- or 16-bit) -- the GPU side of hdr.h's CPU colour helpers.
static id<MTLTexture> tex_fill(MTLPixelFormat pf, uint32_t texel) {
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf width:8 height:8 mipmapped:NO];
    d.storageMode=MTLStorageModeShared; d.usage=MTLTextureUsageShaderRead;
    id<MTLTexture> t=[g_dev newTextureWithDescriptor:d];uint32_t px[64];for(int i=0;i<64;i++)px[i]=texel;
    [t replaceRegion:MTLRegionMake2D(0,0,8,8) mipmapLevel:0 withBytes:px bytesPerRow:32];res_add(t);res_commit();return t;
}
static uint32_t pq_texel(int r, int g, int b) { return (uint32_t)r | (uint32_t)g<<10 | (uint32_t)b<<20 | 3u<<30; }
static void present_px(id<MTLTexture> src, MTLPixelFormat pf, int w, int h, int m4, float out[4]) {
    MTLTextureDescriptor *od=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf width:w height:h mipmapped:NO];
    od.storageMode=MTLStorageModeShared; od.usage=MTLTextureUsageRenderTarget;
    id<MTLTexture> ot=[g_dev newTextureWithDescriptor:od];res_add(ot);res_commit();
    if(m4){EXPECT("Metal 4 present",1,present_offscreen_wait(src,NULL,ot)!=PRESENT_FAILED);}
    else{id<MTLCommandBuffer> cb=[g_q commandBuffer];EXPECT("classic present",1,present_encode(cb,src,ot,NULL));[cb commit];[cb waitUntilCompleted];}
    MTLRegion c=MTLRegionMake2D(w/2,h/2,1,1);
    if(pf==MTLPixelFormatRGB10A2Unorm){uint32_t v=0;[ot getBytes:&v bytesPerRow:4 fromRegion:c mipmapLevel:0];out[0]=(v&0x3ff)/1023.0f;out[1]=((v>>10)&0x3ff)/1023.0f;out[2]=((v>>20)&0x3ff)/1023.0f;out[3]=(v>>30)/3.0f;}
    else{uint8_t v[4]={0};[ot getBytes:v bytesPerRow:4 fromRegion:c mipmapLevel:0];for(int i=0;i<4;i++)out[i]=v[i];}
    res_remove(ot);
}
// One present of a PQ source into an RGB10A2 canvas, and one texel of the result as a 10-bit code + alpha.
static uint32_t present_pq_at(id<MTLTexture> src, const int crop[4], int w, int h, int x, int y, int m4) {
    MTLTextureDescriptor *od=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGB10A2Unorm width:w height:h mipmapped:NO];
    od.storageMode=MTLStorageModeShared; od.usage=MTLTextureUsageRenderTarget;
    id<MTLTexture> ot=[g_dev newTextureWithDescriptor:od];res_add(ot);res_commit();
    if(m4){EXPECT("Metal 4 PQ present",1,present_offscreen_wait(src,crop,ot)!=PRESENT_FAILED);}
    else{id<MTLCommandBuffer> cb=[g_q commandBuffer];EXPECT("classic PQ present",1,present_encode(cb,src,ot,crop));[cb commit];[cb waitUntilCompleted];}
    uint32_t v=0;[ot getBytes:&v bytesPerRow:4 fromRegion:MTLRegionMake2D(x,y,1,1) mipmapLevel:0];res_remove(ot);return v;
}
// A real CAMetalLayer (no window needed on this Mac) configured as the front end configures it, and the
// actual drawable it hands out. The production layer mutations are in front_mac.m's main-thread front end;
// this fixture applies the same three properties so the drawable format can be inspected directly.
static void hdr_test_layer_set(CAMetalLayer *l, int pq) {
    CGColorSpaceRef cs=CGColorSpaceCreateWithName(pq?kCGColorSpaceITUR_2100_PQ:kCGColorSpaceSRGB);
    l.pixelFormat=pq?MTLPixelFormatRGB10A2Unorm:MTLPixelFormatBGRA8Unorm;
    l.colorspace=cs; CGColorSpaceRelease(cs);   // the layer retains it
    l.wantsExtendedDynamicRangeContent=pq?YES:NO;
}
static CAMetalLayer *hdr_test_layer(int pq) {
    CAMetalLayer *l=[CAMetalLayer layer]; l.device=g_dev;
    l.drawableSize=CGSizeMake(16,16);
    hdr_test_layer_set(l,pq);
    return l;
}
// Present the PQ fixture into an already-acquired drawable, then read its centre texel through a blit.
static uint32_t present_into_drawable(id<MTLTexture> src, id<CAMetalDrawable> dr, int *variant) {
    id<MTL4CommandAllocator> al=[g_dev newCommandAllocator]; id<MTL4CommandBuffer> cb=[g_dev newCommandBuffer];
    if(!al||!cb) { EXPECT("drawable present resources available",0,1); return 0; }
    [cb beginCommandBufferWithAllocator:al];
    int kind=present_encode_m4(cb,src,dr.texture,NULL,g_present_uv[0],nil);   // bilinear: no scaler state in this test
    [cb endCommandBuffer];
    dispatch_semaphore_t done=dispatch_semaphore_create(0); __block NSError *err=nil;
    MTL4CommitOptions *o=[MTL4CommitOptions new];
    [o addFeedbackHandler:^(id<MTL4CommitFeedback> f){err=f.error;dispatch_semaphore_signal(done);}];
    [g_q4 commit:&cb count:1 options:o];
    if(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC))) MLOG("[RED] drawable present did not complete");
    EXPECT("drawable present completed",1,kind!=PRESENT_FAILED&&err==nil);
    if(variant)*variant=kind;
    id<MTLBuffer> rb=[g_dev newBufferWithLength:4 options:MTLResourceStorageModeShared];
    id<MTLCommandQueue> q=[g_dev newCommandQueue]; id<MTLCommandBuffer> rc=q?[q commandBuffer]:nil; id<MTLBlitCommandEncoder> b=rc?[rc blitCommandEncoder]:nil;
    if(!rb||!b){ EXPECT("drawable readback resources available",0,1); return 0; }
    [b copyFromTexture:dr.texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(8,8,0) sourceSize:MTLSizeMake(1,1,1) toBuffer:rb destinationOffset:0 destinationBytesPerRow:4 destinationBytesPerImage:4];
    [b endEncoding]; [rc commit]; [rc waitUntilCompleted];
    uint32_t v=0; memcpy(&v,rb.contents,4); return v;
}
// One opt-in HDR present with an injected failure; returns the encoding kind and the centre PQ code. The
// invariant under test: MetalFX must never be reported as used unless the PQ decode stage actually ran.
static int hdr_fx_rolloff_present(id<MTLTexture> src, id<MTLTexture> dst) {
    setenv("DM_HDR_UPSCALE","hdrfx",1); mtl_hdr_fx_reset();
    g_present_n = g_fx_hdr.made_at + FX_REMAKE_PRESENTS;
    id<MTL4CommandAllocator> al=[g_dev newCommandAllocator]; id<MTL4CommandBuffer> cb=[g_dev newCommandBuffer]; id<MTLSharedEvent> ev=[g_dev newSharedEvent];
    int kind=0;
    if (al && cb && ev) {
        [cb beginCommandBufferWithAllocator:al];
        kind=present_encode_m4(cb,src,dst,NULL,g_present_uv[0],&g_fx_present);
        [cb endCommandBuffer]; [g_q4 commit:&cb count:1]; [g_q4 signalEvent:ev value:1];
        if (![ev waitUntilSignaledValue:1 timeoutMS:10000]) kind=0;
    }
    return kind;
}
static int hdr_fx_fault_present(id<MTLTexture> src, int fault, uint32_t *code, int reset) {
    dm_hdr_fx_test_fault = fault;
    if (reset) mtl_hdr_fx_reset();   // a transient decode failure needs no reset: the next frame must recover by itself
    g_present_n = g_fx_hdr.made_at + FX_REMAKE_PRESENTS;
    setenv("DM_HDR_UPSCALE","hdrfx",1);
    MTLTextureDescriptor *od=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGB10A2Unorm width:16 height:16 mipmapped:NO];
    od.storageMode=MTLStorageModeShared; od.usage=MTLTextureUsageRenderTarget;
    id<MTLTexture> dst=[g_dev newTextureWithDescriptor:od]; res_add(dst); res_commit();
    id<MTL4CommandAllocator> al=[g_dev newCommandAllocator]; id<MTL4CommandBuffer> cb=[g_dev newCommandBuffer]; id<MTLSharedEvent> ev=[g_dev newSharedEvent];
    int kind=0;
    if (al && cb && ev) {
        [cb beginCommandBufferWithAllocator:al];
        kind=present_encode_m4(cb,src,dst,NULL,g_present_uv[0],&g_fx_present);
        [cb endCommandBuffer]; [g_q4 commit:&cb count:1]; [g_q4 signalEvent:ev value:1];
        if ([ev waitUntilSignaledValue:1 timeoutMS:10000]) {
            uint32_t v=0; [dst getBytes:&v bytesPerRow:4 fromRegion:MTLRegionMake2D(8,8,1,1) mipmapLevel:0];
            if (code) *code=v;
        } else kind=0;
    }
    res_remove(dst); return kind;
}

// Indicative GPU cost of the present itself (not gameplay): repeated offscreen presents are timed with the
// Metal 4 command buffer's own GPU timestamps. The first present of each mode is a warm-up that makes the
// scaler and its pipelines, so a first-use compile is never counted as steady-state scaling cost.
static double present_gpu_median_ms(id<MTLTexture> src, int use_fx, int n, int w, int h) {
    const int expected = use_fx ? PRESENT_METALFX : PRESENT_STANDARD;   // a fallback is not a MetalFX sample
    if (use_fx) { setenv("DM_HDR_UPSCALE","hdrfx",1); mtl_hdr_fx_reset(); }
    else { unsetenv("DM_HDR_UPSCALE"); mtl_hdr_fx_reset(); }
    if (n <= 0 || n > 16) return -1;
    double ms[16] = {0}; int got = 0;
    for (int i = 0; i <= n; i++) {
        MTLTextureDescriptor *od=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGB10A2Unorm width:w height:h mipmapped:NO];
        od.storageMode=MTLStorageModeShared; od.usage=MTLTextureUsageRenderTarget;
        id<MTLTexture> dst=[g_dev newTextureWithDescriptor:od]; res_add(dst); res_commit();
        id<MTL4CommandAllocator> al=[g_dev newCommandAllocator]; id<MTL4CommandBuffer> cb=[g_dev newCommandBuffer];
        if (!al || !cb || !dst) { res_remove(dst); return -1; }
        [cb beginCommandBufferWithAllocator:al];
        int kind=present_encode_m4(cb,src,dst,NULL,g_present_uv[0],use_fx?&g_fx_hdr:&g_fx_present);
        [cb endCommandBuffer];
        dispatch_semaphore_t done=dispatch_semaphore_create(0); __block double t=0; __block int bad=(kind!=expected);
        MTL4CommitOptions *o=[MTL4CommitOptions new];
        [o addFeedbackHandler:^(id<MTL4CommitFeedback> f) { (void)al; (void)dst; (void)src;
            if (f.error) { bad=1; t=0; }
            else {
                double st=f.GPUStartTime, en=f.GPUEndTime;
                t=(en-st)*1e3;
                if (!(en>st) || !isfinite(st) || !isfinite(en) || !(t>0.0)) { bad=1; t=0; }
            }
            dispatch_semaphore_signal(done); }];
        [g_q4 commit:&cb count:1 options:o];
        int waited=dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC));
        res_remove(dst);
        if (waited != 0 || bad) return -1;   // an invalid measurement is unavailable, never a zero sample
        if (i) ms[got++]=t;
    }
    for (int i=1;i<got;i++) { double v=ms[i]; int j=i-1; while(j>=0&&ms[j]>v){ms[j+1]=ms[j];j--;} ms[j+1]=v; }
    if (got != n) return -1;   // every required sample must have completed successfully
    return ms[got/2];
}
// Objective reconstruction metric: the 10%-to-90% width of a vertical step in output pixels. Smaller is
// sharper. path 0 = HDR bilinear, 1 = opt-in linear-light HDR MetalFX, 2 = SDR MetalFX (perceptual).
// SDR uses its own byte levels because its present cannot encode above SDR white; the metric compares
// reconstruction filters, not absolute luminance, and is printed as evidence rather than a gameplay claim.
static double present_edge_width(id<MTLTexture> src, int path) {
    int sdr = path == 2;
    if (path == 1) { setenv("DM_HDR_UPSCALE","hdrfx",1); unsetenv("DM_PRESENT_UPSCALE"); g_fx_mode=0; mtl_hdr_fx_reset(); }
    else { unsetenv("DM_HDR_UPSCALE"); g_fx_mode = sdr ? 1 : 0; mtl_hdr_fx_reset(); }
    g_present_n = g_fx_present.made_at + FX_REMAKE_PRESENTS;   // a new input format rebuilds the scaler at once
    mtl_present_layer(16,9);
    MTLTextureDescriptor *od=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:sdr?MTLPixelFormatBGRA8Unorm:MTLPixelFormatRGB10A2Unorm width:128 height:72 mipmapped:NO];
    od.storageMode=MTLStorageModeShared; od.usage=MTLTextureUsageRenderTarget;
    id<MTLTexture> dst=[g_dev newTextureWithDescriptor:od]; res_add(dst); res_commit();
    id<MTL4CommandAllocator> al=[g_dev newCommandAllocator]; id<MTL4CommandBuffer> cb=[g_dev newCommandBuffer]; id<MTLSharedEvent> ev=[g_dev newSharedEvent];
    if (!al || !cb || !ev) { res_remove(dst); return -1; }
    [cb beginCommandBufferWithAllocator:al];
    present_encode_m4(cb,src,dst,NULL,g_present_uv[0],sdr?&g_fx_present:&g_fx_hdr);
    [cb endCommandBuffer]; [g_q4 commit:&cb count:1]; [g_q4 signalEvent:ev value:1];
    int ok=[ev waitUntilSignaledValue:1 timeoutMS:10000];
    uint8_t bytes[128*4]={0};
    if(ok){[dst getBytes:bytes bytesPerRow:128*4 fromRegion:MTLRegionMake2D(0,36,128,1) mipmapLevel:0];}
    res_remove(dst);
    if(!ok) return -1;
    double v[128];
    for(int x=0;x<128;x++) v[x]= sdr ? bytes[x*4] : ((uint32_t)(((uint32_t*)bytes)[x])>>10&0x3ff); // B byte, or G PQ code
    double lo=v[8], hi=v[120], a=lo+0.1*(hi-lo), b=lo+0.9*(hi-lo);
    if(!(hi>lo)) return -1;
    int x10=-1,x90=-1;
    for(int x=40;x<90;x++){ if(x10<0&&v[x]>=a) x10=x; if(x90<0&&v[x]>=b) x90=x; }
    return x10>=0&&x90>=0 ? x90-x10 : -1;
}
// Present one source with a given Upscaling choice (g_fx_mode is the cached player preference) and an optional
// HDR-only diagnostic override, into a w x h canvas. Reports the encoding kind and whether the HDR float
// decode/scaler was actually engaged. Each case resets the HDR state so no work leaks between cases.
static int selection_present(id<MTLTexture> src, MTLPixelFormat dst_pf, int w, int h, int fx, const char *override, int *hdr_used) {
    g_fx_mode = fx;
    if (override) setenv("DM_HDR_UPSCALE", override, 1); else unsetenv("DM_HDR_UPSCALE");
    mtl_hdr_fx_reset();
    uint64_t made = g_fx_present.made_at > g_fx_hdr.made_at ? g_fx_present.made_at : g_fx_hdr.made_at;
    g_present_n = made + FX_REMAKE_PRESENTS;   // past both scalers' remake throttle, whichever was made last
    MTLTextureDescriptor *od=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:dst_pf width:w height:h mipmapped:NO];
    od.storageMode=MTLStorageModeShared; od.usage=MTLTextureUsageRenderTarget;
    id<MTLTexture> dst=[g_dev newTextureWithDescriptor:od]; res_add(dst); res_commit();
    id<MTL4CommandAllocator> al=[g_dev newCommandAllocator]; id<MTL4CommandBuffer> cb=[g_dev newCommandBuffer]; id<MTLSharedEvent> ev=[g_dev newSharedEvent];
    int kind=0;
    if (al && cb && ev) {
        [cb beginCommandBufferWithAllocator:al];
        kind=present_encode_m4(cb,src,dst,NULL,g_present_uv[0],&g_fx_present);
        [cb endCommandBuffer]; [g_q4 commit:&cb count:1]; [g_q4 signalEvent:ev value:1];
        if (![ev waitUntilSignaledValue:1 timeoutMS:10000]) kind=0;
    }
    if (hdr_used) *hdr_used = (g_fx_hdr.sc != nil || g_fx_hdr.decoded != nil);
    res_remove(dst);
    return kind;
}
static uint8_t *present_to(id<MTLTexture> src, int w, int h, int m4) {
    MTLTextureDescriptor *od=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:w height:h mipmapped:NO];
    od.storageMode=MTLStorageModeShared; od.usage=MTLTextureUsageRenderTarget;
    id<MTLTexture> ot=[g_dev newTextureWithDescriptor:od];res_add(ot);res_commit();
    if(m4){EXPECT("Metal 4 present",1,present_offscreen_wait(src,NULL,ot)!=PRESENT_FAILED);}
    else{id<MTLCommandBuffer> cb=[g_q commandBuffer];EXPECT("classic present",1,present_encode(cb,src,ot,NULL));[cb commit];[cb waitUntilCompleted];}
    uint8_t *o=malloc(w*h*4);[ot getBytes:o bytesPerRow:w*4 fromRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0];res_remove(ot);return o;
}
static int near(double a, double b, double tol) { return fabs(a-b)<=tol; }
extern void mtl_hdr_fx_reset(void);   // diagnostic: re-read DM_HDR_UPSCALE and drop the experimental scaler
#endif

static const uint8_t colors[4][4]={{255,0,0,255},{0,255,0,255},{0,0,255,255},{255,255,0,255}};
#ifndef CROP_LEGACY_HEADER
extern int g_shape_w,g_shape_h;   // t_host_stubs.c: the last shape the present reported to the front end
#endif

#ifndef CROP_LEGACY_HEADER
// Exercise the persistent scaler used by real presents, completing each command buffer before its allocator and output leave scope.
static int check_present_resize(id<MTLTexture> src, int w, int h) {
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:w height:h mipmapped:NO];
    d.storageMode=MTLStorageModePrivate;d.usage=MTLTextureUsageRenderTarget;
    id<MTLTexture> out=[g_dev newTextureWithDescriptor:d];res_add(out);res_commit();
    id<MTL4CommandAllocator> al=[g_dev newCommandAllocator];id<MTL4CommandBuffer> cb=[g_dev newCommandBuffer];id<MTLSharedEvent> ev=[g_dev newSharedEvent];
    assert(al && ev);
    [cb beginCommandBufferWithAllocator:al];int kind=present_encode_m4(cb,src,out,NULL,g_present_uv[0],&g_fx_present);[cb endCommandBuffer];
    [g_q4 commit:&cb count:1];[g_q4 signalEvent:ev value:1];
    EXPECT("resize present completes",1,[ev waitUntilSignaledValue:1 timeoutMS:10000]);res_remove(out);return kind;
}
#endif

static void check(id<MTLTexture> src, const char *name, const int crop[4], int w, int h, int color) {
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:w height:h mipmapped:NO];
    d.storageMode=MTLStorageModeShared;d.usage=MTLTextureUsageRenderTarget;
    id<MTLTexture> dst=[g_dev newTextureWithDescriptor:d];id<MTLCommandBuffer> cb=[g_q commandBuffer];
    EXPECT("encode succeeds",1,ENCODE(cb,src,dst,crop));[cb commit];[cb waitUntilCompleted];
    EXPECT("GPU done",MTLCommandBufferStatusCompleted,cb.status);
    uint8_t *out=malloc(w*h*4);[dst getBytes:out bytesPerRow:w*4 fromRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0];
    int bad=0;
    for(int y=0;y<h;y++)for(int x=0;x<w;x++) {
        int q=color;
        if(q==4) { // square valid area onto a 2:1 target: 4 black columns on each side, the middle 8 columns all red.
            static const uint8_t black[4]={0,0,0,255};
            const uint8_t *want=x<4||x>=12?black:colors[0];bad+=memcmp(out+4*(y*w+x),want,4)!=0;continue;
        }
        if(q==-2) { // crop=(1,1,4,4): 3×3 red, last column green, last row blue, bottom-right 1 cell yellow.
            q=(x+1>=4)+2*(y+1>=4);
        } else if(q<0) { // same-size default whole frame: the boundary is dead center.
            q=(x>=w/2)+2*(y>=h/2);
        }
        bad+=memcmp(out+4*(y*w+x),colors[q],4)!=0;
    }
    EXPECT(name,0,bad);free(out);
}

// This fixture is the only present producer. A window now holds a logical queue receipt;
// wait for replay, then for the display ticket (snapshots do not return that ticket).
static uint64_t display_ticket(uint64_t receipt, uint64_t before) {
    EXPECT("present returned a logical receipt",1,receipt!=0);
    if (!receipt) return 0;
    nvn_queue_present_wait(receipt);
    uint64_t queued, done; mtl_present_progress(&queued,&done);
    EXPECT("one frame reached the display queue",1,queued==before+1);
    if (queued!=before+1) return 0;
    mtl_present_wait(queued);
    return queued;
}

#ifndef CROP_LEGACY_HEADER
static void check_external_png(const char *path) {
    NSURL *url = [NSURL fileURLWithPath:@(path)];
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    CGImageRef image = source ? CGImageSourceCreateImageAtIndex(source, 0, NULL) : NULL;
    int green = 0;
    if (image) {
        uint8_t pixels[4 * 4 * 4];
        CGColorSpaceRef color = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(pixels, 4, 4, 8, 16, color, (CGBitmapInfo)kCGImageAlphaNoneSkipLast);
        if (ctx) {
            CGContextDrawImage(ctx, CGRectMake(0, 0, 4, 4), image);
            for (int i = 0; i < 16; i++)
                green += pixels[4*i] == 0 && pixels[4*i+1] == 255 && pixels[4*i+2] == 0;
            CGContextRelease(ctx);
        }
        CGColorSpaceRelease(color);
        CGImageRelease(image);
    }
    if (source) CFRelease(source);
    EXPECT(path, 16, green);
}

static void check_external_screenshots(void) {
    char dir[] = "/tmp/nxnative-external-shot.XXXXXX";
    if (!mkdtemp(dir)) { EXPECT("screenshot test directory", 1, 0); return; }
    char scheduled[sizeof dir + 16], queued[sizeof dir + 16], spec[sizeof scheduled + 3];
    snprintf(scheduled, sizeof scheduled, "%s/scheduled.png", dir);
    snprintf(queued, sizeof queued, "%s/queued.png", dir);
    snprintf(spec, sizeof spec, "1:%s", scheduled);
    setenv("DM_NVN_SHOT", spec, 1);
    unsetenv("DM_NVN_SHOT_OUT");

    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:4 height:4 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget;
    td.storageMode = MTLStorageModeShared;
    id<MTLTexture> tex = [g_dev newTextureWithDescriptor:td];
    const uint8_t black[4 * 4 * 4] = {0};
    [tex replaceRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0 withBytes:black bytesPerRow:16];

    id<MTLSharedEvent> ready = [g_dev newSharedEvent];
    assert(ready);
    id<MTLCommandQueue> producer = [g_dev newCommandQueue];
    id<MTLCommandBuffer> cb = [producer commandBuffer];
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = tex;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 1, 0, 1);
    [[cb renderCommandEncoderWithDescriptor:pass] endEncoding];
    [cb encodeSignalEvent:ready value:1];
    // Leave the producer unsubmitted while the external present first reaches readback.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), dispatch_get_global_queue(0, 0), ^{ [cb commit]; });
    uint64_t serial = mtl_ext_tex((__bridge void *)tex);
    dm_gfx_shot_at(1, queued);
    uint64_t ticket = mtl_present_ext(serial, 1.0 / 60, (__bridge void *)ready, 1, NULL);
    EXPECT("external present returns a ticket", 1, ticket != 0);
    if (ticket) mtl_present_wait(ticket);
    check_external_png(scheduled);
    check_external_png(queued);
    EXPECT("producer completes", 1, [ready waitUntilSignaledValue:1 timeoutMS:5000]);
    mtl_ext_tex_release(serial);
    unlink(scheduled);
    unlink(queued);
    rmdir(dir);
}
#endif

int main(int argc, char **argv) { @autoreleasepool {
    mtl_init();
#ifndef CROP_LEGACY_HEADER
    if (argc == 2 && !strcmp(argv[1], "--external-screenshots")) {
        check_external_screenshots();
        return failed != 0;
    }
    mtl_present_layer(1,1);   // square fixtures: a sized square layer, so the checks below see the crop's texels and the bars of that shape; the display's own shape is checked at the end
#endif
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:8 height:8 mipmapped:NO];d.storageMode=MTLStorageModeShared;d.usage=MTLTextureUsageShaderRead;
    id<MTLTexture> src=[g_dev newTextureWithDescriptor:d];uint8_t px[8*8*4];
    for(int y=0;y<8;y++)for(int x=0;x<8;x++)memcpy(px+4*(y*8+x),colors[(x>=4)+2*(y>=4)],4);
    [src replaceRegion:MTLRegionMake2D(0,0,8,8) mipmapLevel:0 withBytes:px bytesPerRow:32];
    int zero[4]={0},tl[4]={0,0,4,4},tr[4]={4,0,4,4},bl[4]={0,4,4,4},br[4]={4,4,4,4},one[4]={3,3,1,1},inset[4]={1,1,4,4};
    check(src,"default whole frame 64 pixels",zero,8,8,-1);
    check(src,"NULL default whole frame 64 pixels",NULL,8,8,-1);
    check(src,"top-left crop scaled up, 256 pixels all red",tl,16,16,0);
    check(src,"non-zero x crop scaled up, 256 pixels all green",tr,16,16,1);
    check(src,"non-zero y crop scaled up, 256 pixels all blue",bl,16,16,2);
    check(src,"bottom-right crop at the edge, 256 pixels all yellow",br,16,16,3);
    check(src,"single texel scaled up without crossing edges, 256 pixels all red",one,16,16,0);
    check(src,"non-zero x and y offset, 16 pixels byte-identical to a hand-written sub-rectangle",inset,4,4,-2);
    check(src,"aspect of the valid area kept, 128 pixels red in the middle / black on both sides",tl,16,8,4);
#ifndef CROP_LEGACY_HEADER
    {
        // sRGB swapchain: present sends the raw bytes (as the Switch's scan-out does) without decoding first; unfixed, 128/64/200 decode to about 55/13/148
        MTLTextureDescriptor *sd=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB width:8 height:8 mipmapped:NO];sd.storageMode=MTLStorageModeShared;sd.usage=MTLTextureUsageShaderRead;
        id<MTLTexture> s8=[g_dev newTextureWithDescriptor:sd];uint8_t g[8*8*4];
        for(int i=0;i<64;i++){g[4*i]=128;g[4*i+1]=64;g[4*i+2]=200;g[4*i+3]=255;}
        [s8 replaceRegion:MTLRegionMake2D(0,0,8,8) mipmapLevel:0 withBytes:g bytesPerRow:32];
        MTLTextureDescriptor *od=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:8 height:8 mipmapped:NO];od.storageMode=MTLStorageModeShared;od.usage=MTLTextureUsageRenderTarget;
        id<MTLTexture> dst=[g_dev newTextureWithDescriptor:od];id<MTLCommandBuffer> cb=[g_q commandBuffer];
        EXPECT("sRGB source encode succeeds",1,ENCODE(cb,s8,dst,zero));[cb commit];[cb waitUntilCompleted];
        uint8_t o[8*8*4];[dst getBytes:o bytesPerRow:32 fromRegion:MTLRegionMake2D(0,0,8,8) mipmapLevel:0];
        int bad=0;for(int i=0;i<64;i++)bad+=abs(o[4*i]-128)>1||abs(o[4*i+1]-64)>1||abs(o[4*i+2]-200)>1;
        EXPECT("sRGB swapchain present sends raw bytes, 64 pixels",0,bad);
    }
#endif
#ifndef CROP_LEGACY_HEADER
    {   // DM_PRESENT_UPSCALE: which content MetalFX scales, and to which size (the picture's rectangle on the canvas)
        const struct { unsigned cw,ch,dw,dh,w,h; int upscale; } sizes[] = {
            {1280,720,2868,1320,2347,1320,1},   // handheld, letterboxed on an iPhone
            {1952,900,2868,1320,2868,1320,1},   // ratios within 1 % fill the canvas
            {1280,720,2560,1440,2560,1440,1},   // Retina window
            {1280,720,1280,720,1280,720,0},     // native size
            {1600,900,1280,720,1280,720,0},     // downscale
            {8,8,16,8,8,8,0},                  // larger canvas, native-size picture
        };
        for (unsigned i=0;i<sizeof sizes/sizeof *sizes;i++) {
            MTLViewport vp=present_viewport(sizes[i].cw,sizes[i].ch,sizes[i].dw,sizes[i].dh);
            EXPECT("MetalFX only upscales the picture",sizes[i].upscale,fx_wanted(vp,sizes[i].cw,sizes[i].ch));
            EXPECT("picture width",sizes[i].w,(int)vp.width);EXPECT("picture height",sizes[i].h,(int)vp.height);
        }
        EXPECT("empty content is not upscaled",0,fx_wanted((MTLViewport){0,0,2868,1320,0,1},0,720));
    }
    if([MTLFXSpatialScalerDescriptor supportsMetal4FX:g_dev]) {   // the present pass through MetalFX into an offscreen canvas (present_offscreen_m4, as DM_NVN_SHOT_OUT uses it)
        g_fx_mode=1;
        const int N=64;MTLTextureDescriptor *bd=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB width:N height:N mipmapped:NO];bd.storageMode=MTLStorageModeShared;bd.usage=MTLTextureUsageShaderRead;
        id<MTLTexture> big=[g_dev newTextureWithDescriptor:bd];uint8_t *bp=malloc(N*N*4);
        for(int y=0;y<N;y++)for(int x=0;x<N;x++)memcpy(bp+4*(y*N+x),colors[(x>=N/2)+2*(y>=N/2)],4);
        for(int y=N/2;y<N;y++)for(int x=0;x<N/2;x++){uint8_t g[4]={128,64,200,255};memcpy(bp+4*(y*N+x),g,4);}   // lower-left quadrant: a mid grey-violet the sRGB bytes must keep
        [big replaceRegion:MTLRegionMake2D(0,0,N,N) mipmapLevel:0 withBytes:bp bytesPerRow:N*4];free(bp);
        res_add(big);res_commit();
        const int W=4*N,H=2*N;MTLTextureDescriptor *od=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
        od.storageMode=MTLStorageModePrivate;od.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;id<MTLTexture> out=[g_dev newTextureWithDescriptor:od];
        const int crops[4][4]={{0},{8,8,48,48},{8,8,48,48},{8,8,48,48}};
        for (int mode=0;mode<4;mode++) {
            g_fx_mode=mode==3?0:1;atomic_store(&g_origin_ll,mode==2);
            EXPECT("offscreen present reports the scaler actually used",mode==3?PRESENT_STANDARD:PRESENT_METALFX,present_offscreen_wait(big,crops[mode],out));
            id<MTLBuffer> rb=[g_dev newBufferWithLength:W*H*4 options:MTLResourceStorageModeShared];id<MTLCommandBuffer> cb=[g_q commandBuffer];id<MTLBlitCommandEncoder> bl=[cb blitCommandEncoder];
            [bl copyFromTexture:out sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(W,H,1) toBuffer:rb destinationOffset:0 destinationBytesPerRow:W*4 destinationBytesPerImage:W*H*4];
            [bl endEncoding];[cb commit];[cb waitUntilCompleted];
            const uint8_t *o=rb.contents;   // BGRA
        #define PX(x,y,c) o[4*((y)*W+(x))+(c)]
            int bars=0;for(int y=0;y<H;y++)for(int x=0;x<W;x++)if(x<64||x>=192)bars+=PX(x,y,0)||PX(x,y,1)||PX(x,y,2);
            EXPECT("  black bars beside the square picture, 0 lit pixels",0,bars);
            int bad=0;const int cxs[2]={64+32,64+96},cys[2]={32,96};
            for(int q=0;q<4;q++){int x=cxs[q&1],y=cys[q>>1],sq=mode==2?q^2:q;const uint8_t *want=sq==2?(const uint8_t[4]){128,64,200,255}:colors[sq];
                bad+=abs(PX(x,y,2)-want[0])>3||abs(PX(x,y,1)-want[1])>3||abs(PX(x,y,0)-want[2])>3;}
            EXPECT("  quadrant centres keep their colours, raw bytes of the sRGB source (4 checked)",0,bad);
        #undef PX
        }
        atomic_store(&g_origin_ll,0);g_fx_mode=1;
        MTLTextureDescriptor *smallD=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:32 height:32 mipmapped:NO];
        smallD.storageMode=MTLStorageModePrivate;smallD.usage=MTLTextureUsageRenderTarget;
        id<MTLTexture> small=[g_dev newTextureWithDescriptor:smallD];int whole[4]={0},invalidCrop[4]={63,0,2,2};
        EXPECT("MetalFX requested but downscaling uses standard",PRESENT_STANDARD,present_offscreen_wait(big,whole,small));
        EXPECT("offscreen rejects an invalid crop before submission",PRESENT_FAILED,present_offscreen_wait(big,invalidCrop,out));

        uint64_t savedPresent=g_present_n;g_present_n=1;
        EXPECT("initial present makes its scaler",PRESENT_METALFX,check_present_resize(big,W,H));
        id<MTL4FXSpatialScaler> first=g_fx_present.sc;
        g_present_n=2;
        EXPECT("resizing within 30 presents falls back to standard",PRESENT_STANDARD,check_present_resize(big,192,96));
        EXPECT("resizing keeps the previous scaler until replacement",1,g_fx_present.sc==first);
        g_present_n=31;
        EXPECT("stable new size makes its scaler",PRESENT_METALFX,check_present_resize(big,192,96));
        EXPECT("replacement has the new picture size",96,(int)g_fx_present.sc.outputWidth);
        EXPECT("exactly two scalers made",2,g_fx_present.made);
        g_present_n=32;
        EXPECT("same size reuses its scaler",PRESENT_METALFX,check_present_resize(big,192,96));
        EXPECT("reuse makes no new scaler",2,g_fx_present.made);
        // DM_FX_INPLACE and DM_FX_DIRECT: the scaler reads a private window texture in place and writes a canvas it can write, while the frame that draws that texture is
        // still running on the queue (committed just before, as a present follows its frame). The scaler must still see the whole frame: the encoder before it orders it after
        // the queue's earlier work only around work of its own (an encoder of barriers alone ordered nothing, and the scaler read the frame before, in every round)
        {
            const int S=256,ROUNDS=8;
            MTLTextureDescriptor *wd=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:S height:S mipmapped:NO];
            wd.storageMode=MTLStorageModePrivate;wd.usage=MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite;id<MTLTexture> win=[g_dev newTextureWithDescriptor:wd];
            MTLTextureDescriptor *cd=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:2*S height:2*S mipmapped:NO];
            cd.storageMode=MTLStorageModePrivate;cd.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite;id<MTLTexture> canvas=[g_dev newTextureWithDescriptor:cd];
            id<MTLBuffer> args=[g_dev newBufferWithLength:16 options:MTLResourceStorageModeShared],rb=[g_dev newBufferWithLength:4*S*S*4 options:MTLResourceStorageModeShared];
            res_add(win);res_add(canvas);res_add(args);res_commit();
            NSError *err=nil;id<MTL4Compiler> comp=[g_dev newCompilerWithDescriptor:[MTL4CompilerDescriptor new] error:&err];
            id<MTLLibrary> lib=[g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\nstruct A { uint iters; uint tag; };\n"
                "kernel void frame(constant A &a [[buffer(0)]], texture2d<float, access::write> t [[texture(0)]], uint2 i [[thread_position_in_grid]]) {\n"
                "  float x = float(i.x); for (uint k = 0; k < a.iters; k++) x = fma(x, 1.0000001f, 0.5f); float g = x > -1.0f ? float(a.tag) / 255.0f : 0.0f; t.write(float4(g, g, g, 1), i); }\n" options:nil error:&err];
            MTL4LibraryFunctionDescriptor *fd=[MTL4LibraryFunctionDescriptor new];fd.name=@"frame";fd.library=lib;
            MTL4ComputePipelineDescriptor *pd=[MTL4ComputePipelineDescriptor new];pd.computeFunctionDescriptor=fd;
            id<MTLComputePipelineState> ps=lib&&comp?[comp newComputePipelineStateWithDescriptor:pd compilerTaskOptions:nil error:&err]:nil;
            EXPECT("the slow frame kernel compiles",1,ps!=nil);
            MTL4ArgumentTableDescriptor *ad=[MTL4ArgumentTableDescriptor new];ad.maxBufferBindCount=1;ad.maxTextureBindCount=1;
            id<MTL4ArgumentTable> at=[g_dev newArgumentTableWithDescriptor:ad error:&err];
            id<MTL4CommandAllocator> fal=[g_dev newCommandAllocator],pal=[g_dev newCommandAllocator];id<MTLSharedEvent> ev=[g_dev newSharedEvent];
            g_present_n=1000;int stale=0,kinds=0;
            for (int round=1;ps&&round<=ROUNDS;round++) {
                uint32_t tag=40+round*23;((uint32_t *)args.contents)[0]=50000;((uint32_t *)args.contents)[1]=tag;
                [at setAddress:args.gpuAddress atIndex:0];[at setTexture:win.gpuResourceID atIndex:0];[fal reset];[pal reset];
                id<MTL4CommandBuffer> fcb=[g_dev newCommandBuffer];[fcb beginCommandBufferWithAllocator:fal];
                id<MTL4ComputeCommandEncoder> ce=[fcb computeCommandEncoder];[ce setComputePipelineState:ps];[ce setArgumentTable:at];
                [ce dispatchThreads:MTLSizeMake(S,S,1) threadsPerThreadgroup:MTLSizeMake(16,16,1)];[ce endEncoding];[fcb endCommandBuffer];
                id<MTL4CommandBuffer> pcb=[g_dev newCommandBuffer];[pcb beginCommandBufferWithAllocator:pal];
                kinds+=present_encode_m4(pcb,win,canvas,NULL,g_present_uv[0],&g_fx_present)==PRESENT_METALFX;[pcb endCommandBuffer];
                [g_q4 commit:&fcb count:1];[g_q4 commit:&pcb count:1];[g_q4 signalEvent:ev value:round];
                if (![ev waitUntilSignaledValue:round timeoutMS:10000]) { EXPECT("in-place present completes",1,0); break; }
                id<MTLCommandBuffer> cb=[g_q commandBuffer];id<MTLBlitCommandEncoder> bl=[cb blitCommandEncoder];
                [bl copyFromTexture:canvas sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(2*S,2*S,1) toBuffer:rb destinationOffset:0 destinationBytesPerRow:2*S*4 destinationBytesPerImage:4*S*S*4];
                [bl endEncoding];[cb commit];[cb waitUntilCompleted];
                const uint8_t *o=rb.contents;int bad=0;
                for (int y=4;y<2*S-4;y+=9) for (int x=4;x<2*S-4;x+=9) bad+=abs(o[4*(y*2*S+x)+1]-(int)tag)>3;
                stale+=bad!=0;
            }
            EXPECT("in-place presents go through MetalFX",ROUNDS,kinds);
            EXPECT("the scaler read the window texture in place: no input copy made",1,g_fx_present.in==nil&&g_fx_present.in_place_n>=ROUNDS);
            EXPECT("the scaler wrote the canvas: no present pass, no output texture made",1,g_fx_present.out==nil&&g_fx_present.direct_n>=ROUNDS);
            EXPECT("the scaler saw the whole frame still drawing at the present, rounds stale",0,stale);
            res_remove(win);res_remove(canvas);res_remove(args);
        }
        g_present_n=savedPresent;

        // Whole-window capture uses the same upscale and remains asynchronous; its completion includes the final BGRA readback.
        dispatch_semaphore_t grabbed=dispatch_semaphore_create(0);
        mtl_grab_next_present(^(CGImageRef img) {
            EXPECT("whole-window capture produces an image",1,img!=NULL);
            if (img) {
                EXPECT("whole-window image width",W,(int)CGImageGetWidth(img));
                CFDataRef data=CGDataProviderCopyData(CGImageGetDataProvider(img));const uint8_t *p=CFDataGetBytePtr(data);
                size_t off=96*CGImageGetBytesPerRow(img)+96*4;
                EXPECT("whole-window capture preserves sRGB bytes",1,abs(p[off]-200)<=3&&abs(p[off+1]-64)<=3&&abs(p[off+2]-128)<=3);
                CFRelease(data);
            }
            dispatch_semaphore_signal(grabbed);
        });
        grab_present(big,whole,CGSizeMake(W,H));
        EXPECT("whole-window capture callback completes",0,(int)dispatch_semaphore_wait(grabbed,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC)));
        res_remove(big);g_fx_mode=0;
    } else printf("no Metal 4 MetalFX spatial scaler on this GPU: the MetalFX present is not checked\n");
#endif
    int invalid[4][4]={{-1,0,4,4},{0,-1,4,4},{0,0,0,4},{7,0,4,4}};
    for(int i=0;i<4;i++) {
        MTLTextureDescriptor *dd=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:8 height:8 mipmapped:NO];dd.usage=MTLTextureUsageRenderTarget;dd.storageMode=MTLStorageModeShared;
        id<MTLTexture> dst=[g_dev newTextureWithDescriptor:dd];
        EXPECT("invalid crop is not encoded and does not fake success by stretching the whole image",0,ENCODE([g_q commandBuffer],src,dst,invalid[i]));
    }
    // Real QueuePresent entry: set crop and enqueue first, then immediately change the window; the present ticket must keep that frame's copy.
    PFNNVNDEVICEGETPROCADDRESSPROC get=(PFNNVNDEVICEGETPROCADDRESSPROC)h_nvnBootstrapLoader("nvnDeviceGetProcAddress");
    NVNT_nvnWindowSetCrop set=(NVNT_nvnWindowSetCrop)get(NULL,"nvnWindowSetCrop");
    NVNT_nvnQueuePresentTexture present=(NVNT_nvnQueuePresentTexture)get(NULL,"nvnQueuePresentTexture");
    NVNqueueBuilder builder={0}; NVNqueue queue={0};
    h_nvnQueueBuilderSetDefaults(&builder);
    EXPECT("fixture queue initialized",1,h_nvnQueueInitialize(&queue,&builder));
    uint64_t before, done;
    tex_t tex={.magic=MAGIC('T', 'E', 'X', 0), .serial =10001};tex.d.width=tex.d.height=8;tex.d.depth=tex.d.levels=1;tex.d.format=NVN_FORMAT_RGBA8;tex.d.target=NVN_TEXTURE_TARGET_2D;serial_put(tex.serial,src);
    win_t win={.ntex=1};win.tex[0]=(NVNtexture *)&tex;set((NVNwindow *)&win,4,4,4,4);
    mtl_present_progress(&before,&done);
    // Replay is held until the window changes: QueuePresent must take this frame's crop when it queues the frame, not when replay presents it
    nvn_queue_test_hold(1);
    present(&queue,(NVNwindow *)&win,0);set((NVNwindow *)&win,0,0,8,8);
    {   // without a working hold the crop check below would pass whenever replay ran first
        uint64_t held; usleep(20000); mtl_present_progress(&held,&done);
        EXPECT("the held replay queues no frame for the display",1,held==before);
    }
    nvn_queue_test_hold(0);
    uint64_t tk=display_ticket(win.ticket[0],before);
#ifdef CROP_LEGACY_HEADER
    EXPECT("old queue struct has no room for a four-value copy (struct check)",1,sizeof(pq_item)>=sizeof(tex_t)+sizeof(double)+sizeof(uint64_t)+sizeof br);
#else
    pthread_mutex_lock(&g_pq_mu);
    int saved=tk && memcmp(g_pq[(tk-1)%PQ].crop,br,sizeof br)==0;pthread_mutex_unlock(&g_pq_mu);
    EXPECT("real QueuePresent: the frame's crop copy does not change with the window",1,saved);
#endif
    h_nvnWindowFinalize((NVNwindow *)&win);
#ifndef CROP_LEGACY_HEADER
    {   // A window without a crop of its own presents by the vi layer crop (Link's Awakening in handheld mode: 1280x720 of its 1920x1080 window textures, cropped through vi::SetLayerCrop)
        int none[4]={0},lay[4]={0,4,4,4},over[4]={0,0,16,16},lc[4];
        memset(g_layer_crop,0,sizeof g_layer_crop);EXPECT("no window or layer crop: the whole texture",1,present_crop(none,8,8,lc)==none);
        memcpy(g_layer_crop,lay,sizeof lay);const int *r=present_crop(none,8,8,lc);EXPECT("no window crop: the layer crop",1,r==lc&&!memcmp(lc,lay,sizeof lay));
        EXPECT("the window's own crop wins over the layer crop",1,present_crop(br,8,8,lc)==br);
        memcpy(g_layer_crop,over,sizeof over);EXPECT("a layer crop larger than the texture: the whole texture",1,present_crop(none,8,8,lc)==none);
        memcpy(g_layer_crop,lay,sizeof lay);win_t w2={.ntex=1};w2.tex[0]=(NVNtexture *)&tex;
        mtl_present_progress(&before,&done);
        nvn_queue_test_hold(1);
        present(&queue,(NVNwindow *)&w2,0);memset(g_layer_crop,0,sizeof g_layer_crop);
        nvn_queue_test_hold(0);
        uint64_t t2=display_ticket(w2.ticket[0],before);
        pthread_mutex_lock(&g_pq_mu);int got=t2 && memcmp(g_pq[(t2-1)%PQ].crop,lay,sizeof lay)==0;pthread_mutex_unlock(&g_pq_mu);
        EXPECT("real QueuePresent: a window without a crop queues the layer crop",1,got);
        h_nvnWindowFinalize((NVNwindow *)&w2);
    }
    {   // The crop only picks texels; the picture has the layer's shape (Super Mario Galaxy 2's storybook cutscenes: 1200x960 of a 1920x1080 swapchain, shown at 16:9, issue #949)
        const int W=64,H=36,TW=64,TH=36;MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:TW height:TH mipmapped:NO];td.storageMode=MTLStorageModeShared;td.usage=MTLTextureUsageShaderRead;
        id<MTLTexture> sw=[g_dev newTextureWithDescriptor:td];uint8_t *sp=malloc(TW*TH*4);
        const int crop54[4]={0,0,40,32};   // 5:4 in the top-left corner: red inside, green outside
        for(int y=0;y<TH;y++)for(int x=0;x<TW;x++)memcpy(sp+4*(y*TW+x),colors[x>=crop54[2]||y>=crop54[3]],4);
        [sw replaceRegion:MTLRegionMake2D(0,0,TW,TH) mipmapLevel:0 withBytes:sp bytesPerRow:TW*4];free(sp);res_add(sw);res_commit();
        double sa,sb;
        mtl_present_layer(0,0);present_shape(sw,&sa,&sb);EXPECT("no sized layer: the display's width",1920,(int)sa);EXPECT("no sized layer: the display's height",1080,(int)sb);
        for(int m4=0;m4<2;m4++) {
            int outH[2]={H,40};   // 16:9 fills; a 16:10 canvas keeps the bars above and below
            for(int k=0;k<2;k++) {
                MTLTextureDescriptor *od=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:W height:outH[k] mipmapped:NO];od.storageMode=MTLStorageModeShared;od.usage=MTLTextureUsageRenderTarget;
                id<MTLTexture> ot=[g_dev newTextureWithDescriptor:od];res_add(ot);res_commit();
                if(m4){EXPECT("Metal 4 present of a 5:4 crop",1,present_offscreen_wait(sw,crop54,ot)!=PRESENT_FAILED);}
                else{id<MTLCommandBuffer> cb=[g_q commandBuffer];EXPECT("classic present of a 5:4 crop",1,present_encode(cb,sw,ot,crop54));[cb commit];[cb waitUntilCompleted];}
                uint8_t *o=malloc(W*outH[k]*4);[ot getBytes:o bytesPerRow:W*4 fromRegion:MTLRegionMake2D(0,0,W,outH[k]) mipmapLevel:0];
                int bad=0,top=(outH[k]-H)/2;static const uint8_t black[4]={0,0,0,255};
                for(int y=0;y<outH[k];y++)for(int x=0;x<W;x++)bad+=memcmp(o+4*(y*W+x),y<top||y>=top+H?black:colors[0],4)!=0;
                EXPECT(k?"5:4 crop on a 16:10 canvas: 16:9 of red, black above and below":"5:4 crop on a 16:9 canvas: all red, no side bars",0,bad);free(o);res_remove(ot);
            }
        }
        mtl_present_layer(4,3);present_shape(sw,&sa,&sb);EXPECT("a sized layer gives its own shape",4*(int)sb,3*(int)sa);mtl_present_layer(0,0);
        MTLTextureDescriptor *td2=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1920 height:1344 mipmapped:NO];td2.storageMode=MTLStorageModePrivate;td2.usage=MTLTextureUsageShaderRead;
        id<MTLTexture> tall=[g_dev newTextureWithDescriptor:td2];
        present_shape(tall,&sa,&sb);EXPECT("a taller texture without DM_SCREEN_ASPECT: 16:9",1080,(int)sb);
        mtl_present_screen(1920,1344);present_shape(tall,&sa,&sb);EXPECT("DM_SCREEN_ASPECT: a texture that follows it keeps the taller shape",1344,(int)sb);
        present_shape(sw,&sa,&sb);EXPECT("DM_SCREEN_ASPECT: a 16:9 texture of a build without stubs stays 16:9",1080,(int)sb);mtl_present_screen(0,0);
        // The front end's layout and the mouse follow the same shape, not the crop's (front_picture_shape): a real present of the 5:4 crop
        tex_t st={.magic=MAGIC('T', 'E', 'X', 0), .serial =10002};st.d.width=TW;st.d.height=TH;st.d.depth=st.d.levels=1;st.d.format=NVN_FORMAT_RGBA8;st.d.target=NVN_TEXTURE_TARGET_2D;serial_put(st.serial,sw);
        win_t w3={.ntex=1};w3.tex[0]=(NVNtexture *)&st;set((NVNwindow *)&w3,crop54[0],crop54[1],crop54[2],crop54[3]);
        mtl_present_progress(&before,&done);
        present(&queue,(NVNwindow *)&w3,0);display_ticket(w3.ticket[0],before);
        h_nvnWindowFinalize((NVNwindow *)&w3);
        EXPECT("the shape reported to the front end is the layer's, width",1920,g_shape_w);EXPECT("the shape reported to the front end is the layer's, height",1080,g_shape_h);
        res_remove(sw);
    }
    {   // Native HDR10 (DM_HDR): the four picture/drawable combinations, the SDR screenshot and the MetalFX guard
        setenv("DM_HDR","auto",1);   // read once, on first use
        mtl_present_layer(1,1);   // the square fixtures fill the canvas
        id<MTLTexture> sdr=tex_fill(MTLPixelFormatRGBA8Unorm,0xff408020u), pqw=tex_fill(MTLPixelFormatRGB10A2Unorm,pq_texel(520,520,520));
        uint8_t *sdr_before=present_to(sdr,16,16,0);
        EXPECT("not told: an RGB10A2 window is not PQ",0,present_pq(pqw));
        { float px[4]; present_px(pqw,MTLPixelFormatBGRA8Unorm,16,16,0,px); EXPECT("not told: RGB10A2 presented raw (520/1023 -> 130)",130,(int)px[1]); }
        // The front end has made the PQ layer and the game has been told HDR (hle_vi.c).
        dm_hdr_boot(); dm_hdr_screen(16.0,8.0,1000);
        EXPECT("layer wanted",1,dm_hdr_layer_tick(0,1000));
        EXPECT("layer ready",1,dm_hdr_layer_tick(1,1000));
        uint16_t peak=0; EXPECT("vi answers HDR",1,dm_hdr_answer(&peak)); EXPECT("peak 800 nits",800,peak);
        EXPECT("told: RGB10A2 is PQ",1,present_pq(pqw)); EXPECT("told: RGBA8 is not",0,present_pq(sdr));
        // PQ window -> PQ drawable: no conversion, the game's codes go to the display unchanged.
        { float px[4]; for(int m4=0;m4<2;m4++){ present_px(pqw,MTLPixelFormatRGB10A2Unorm,16,16,m4,px);
              EXPECT(m4?"M4: PQ -> PQ keeps paper-white code":"classic: PQ -> PQ keeps paper-white code",1,near(px[1],520/1023.0f,0.002));
              EXPECT(m4?"M4: PQ -> PQ keeps alpha 1":"classic: PQ -> PQ keeps alpha 1",1,px[3]>0.99f); } }
        // Apple's example uses BGR10A2Unorm for BGRA-ordered content; the game's window is RGB10A2 with R in
        // bits 0-9. Distinct codes per channel prove no implicit swizzle or conversion in the PQ passthrough,
        // so there is no reason to change the layer to Apple's example format and break validated ordering.
        { id<MTLTexture> rgb=tex_fill(MTLPixelFormatRGB10A2Unorm,pq_texel(520,594,100));
          float px[4]; for(int m4=0;m4<2;m4++){ present_px(rgb,MTLPixelFormatRGB10A2Unorm,16,16,m4,px);
              EXPECT(m4?"M4: PQ passthrough keeps R":"PQ passthrough keeps R",520,(int)(px[0]*1023.0f+0.5f));
              EXPECT(m4?"M4: PQ passthrough keeps G":"PQ passthrough keeps G",594,(int)(px[1]*1023.0f+0.5f));
              EXPECT(m4?"M4: PQ passthrough keeps B":"PQ passthrough keeps B",100,(int)(px[2]*1023.0f+0.5f));
              EXPECT(m4?"M4: PQ passthrough keeps alpha":"PQ passthrough keeps alpha",3,(int)(px[3]*3.0f+0.5f)); }
          res_remove(rgb); }
        // The fifth combination: an HDR10 picture into a PQ drawable with the headroom-aware roll-off.
        // Present params must report mode 4 and the knee's PQ code; the GPU must lower only the highlight,
        // leaving paper white untouched (no double tone map of ordinary picture levels).
        { dm_hdr_headroom_set(2.0); dm_hdr_meta_set(HDR_META_EXT,0,2000);
          float p[8]; int variant=present_params(pqw,MTLPixelFormatRGB10A2Unorm,p);
          EXPECT("roll-off variant uses the HDR conversion shader",PV_HDR,variant);
          EXPECT("roll-off present mode",4,(int)p[0]);
          EXPECT("roll-off knee is 1.5x paper white",150,(int)p[2]);
          EXPECT("roll-off target is paper white x headroom",200,(int)p[3]);
          EXPECT("roll-off knee code is the PQ encoding of the knee",1,near(present_pq_code(p[2]),p[5],0.0001));
          id<MTLTexture> bright=tex_fill(MTLPixelFormatRGB10A2Unorm,pq_texel(1023,1023,1023));
          float px[4]; for(int m4=0;m4<2;m4++){ present_px(bright,MTLPixelFormatRGB10A2Unorm,16,16,m4,px);
              EXPECT(m4?"M4: roll-off lowers a peak the screen cannot show":"classic: roll-off lowers a peak the screen cannot show",1,px[1]<1023/1023.0f-0.01);
              EXPECT(m4?"M4: roll-off keeps the hue (equal channels)":"classic: roll-off keeps the hue (equal channels)",1,near(px[0],px[1],0.002)&&near(px[2],px[1],0.002)); }
          { float paper[4]; present_px(pqw,MTLPixelFormatRGB10A2Unorm,16,16,0,paper);
            EXPECT("roll-off leaves paper white unchanged",1,near(paper[1],520/1023.0f,0.002)); }
          res_remove(bright); dm_hdr_headroom_set(8.0); dm_hdr_meta_set(HDR_META_EXT,0,0); }
        // HDR crop / scaling characterisation: a flat PQ source must stay flat through a crop, a
        // non-integer scale and letterboxing, with black bars (code 0) where no source texels are sampled.
        { int crop[4]={2,2,4,4};
          for(int m4=0;m4<2;m4++){ uint32_t v=present_pq_at(pqw,crop,32,32,16,16,m4);
              EXPECT(m4?"M4: HDR cropped centre code":"classic: HDR cropped centre code",1,(int)((v>>10)&0x3ff)==520);
              EXPECT(m4?"M4: HDR crop keeps alpha 3":"classic: HDR crop keeps alpha 3",3,(int)(v>>30)); }
          uint32_t ni=present_pq_at(pqw,NULL,21,13,10,6,0);
          EXPECT("non-integer HDR scale keeps the flat source code",1,(int)((ni>>10)&0x3ff)==520);
          mtl_present_layer(16,9);   // a 16:9 picture in a square canvas: bars above and below
          uint32_t bar=present_pq_at(pqw,NULL,32,32,16,2,0), mid=present_pq_at(pqw,NULL,32,32,16,16,0);
          EXPECT("HDR letterbox bar is black PQ code 0",0,(int)((bar>>10)&0x3ff));
          EXPECT("HDR letterbox centre keeps paper white",1,(int)((mid>>10)&0x3ff)==520);
          mtl_present_layer(1,1); }
        // Real CAMetalLayer lifecycle on ONE layer, mutated the way front_hdr_apply mutates the game's layer:
        // SDR -> HDR -> SDR -> HDR -> SDR, with a real drawable each time. Check the layer properties, the
        // drawable format, the VI answer and the picture actually written. No mock compositor is involved.
        { int64_t now=6000;
          CAMetalLayer *l=hdr_test_layer(0);
          for(int step=0;step<5;step++) {
              int pq = step==0 ? 0 : step==1 ? 1 : step==2 ? 0 : step==3 ? 1 : 0;   // the last is the rapid pair's SDR
              hdr_test_layer_set(l,pq);
              id<CAMetalDrawable> dr=[l nextDrawable];
              EXPECT("real drawable available",1,dr!=nil);
              EXPECT("drawable format follows the layer",(int)(pq?MTLPixelFormatRGB10A2Unorm:MTLPixelFormatBGRA8Unorm),(int)dr.texture.pixelFormat);
              EXPECT("EDR flag follows the layer",pq,(int)l.wantsExtendedDynamicRangeContent);
              CGColorSpaceRef wantCS=CGColorSpaceCreateWithName(pq?kCGColorSpaceITUR_2100_PQ:kCGColorSpaceSRGB);
              CFStringRef wantName=CGColorSpaceGetName(wantCS), gotName=CGColorSpaceGetName(l.colorspace);
              EXPECT("PQ colour space only on the HDR layer",1,gotName&&wantName&&CFStringCompare(gotName,wantName,0)==kCFCompareEqualTo);
              CGColorSpaceRelease(wantCS);
              dm_hdr_layer_tick(pq,now+=100);
              uint16_t pk=0; int on=dm_hdr_answer(&pk);
              EXPECT("VI answer matches a ready PQ layer",pq,on);
              uint32_t v=present_into_drawable(pqw,dr,NULL);
              if(pq) EXPECT("HDR drawable keeps the game's PQ code",1,(int)((v>>10)&0x3ff)==520);
              else   EXPECT("SDR drawable gets the tone-mapped picture",1,near((v>>16&0xff),240,4));
          }
          // Stale drawables: the SAME layer changes after nextDrawable; the pass must use the drawable's own
          // format, not the layer's current one, so an in-flight HDR frame is never written as SDR or back.
          hdr_test_layer_set(l,0); id<CAMetalDrawable> stale_sdr=[l nextDrawable];
          hdr_test_layer_set(l,1);   // the layer switches before the old drawable is presented
          EXPECT("a drawable keeps its format after the layer switches to HDR",(int)MTLPixelFormatBGRA8Unorm,(int)stale_sdr.texture.pixelFormat);
          uint32_t v=present_into_drawable(pqw,stale_sdr,NULL);
          EXPECT("a drawable taken before the HDR switch is still tone-mapped to SDR",1,near((v>>16&0xff),240,4));
          id<CAMetalDrawable> stale_pq=[l nextDrawable];
          hdr_test_layer_set(l,0);   // and back again with a PQ drawable still in flight
          EXPECT("a drawable keeps its format after the layer switches to SDR",(int)MTLPixelFormatRGB10A2Unorm,(int)stale_pq.texture.pixelFormat);
          v=present_into_drawable(pqw,stale_pq,NULL);
          EXPECT("a drawable taken before the SDR restore keeps its PQ code",1,(int)((v>>10)&0x3ff)==520);
          dm_hdr_layer_tick(1,now+=100);   // leave the state as HDR_ACTIVE for the tests that follow
        }
        // PQ window -> SDR target: paper white at ordinary SDR white, never the raw PQ bytes.
        { float px[4]; EXPECT("PQ -> SDR variant",PV_HDR,present_variant(1,MTLPixelFormatBGRA8Unorm));
          for(int m4=0;m4<2;m4++){ present_px(pqw,MTLPixelFormatBGRA8Unorm,16,16,m4,px);
              EXPECT(m4?"M4: PQ -> SDR paper white":"classic: PQ -> SDR paper white",1,near(px[1],240,4));
              EXPECT(m4?"M4: PQ -> SDR writes opaque alpha":"classic: PQ -> SDR writes opaque alpha",1,px[3]>0.99f); } }
        // SDR window -> PQ drawable (the frames before the game switches): the paper white lands at EDR 1.0.
        { float px[4]; EXPECT("SDR -> PQ variant",PV_HDR,present_variant(0,MTLPixelFormatRGB10A2Unorm));
          for(int m4=0;m4<2;m4++){ present_px(sdr,MTLPixelFormatRGB10A2Unorm,16,16,m4,px);
              double lin=hdr_sdr_decode(0x80/255.0,2.2), nits=lin*hdr_paper_white_parse(NULL), want[3],v[3]={lin,lin,lin};
              hdr_bt709_to_2020(v,want); (void)nits;
              EXPECT(m4?"M4: SDR -> PQ white nits":"classic: SDR -> PQ white nits",1,near(px[1],hdr_pq_code(lin*100.0),0.03));
              EXPECT(m4?"M4: SDR -> PQ writes opaque alpha":"classic: SDR -> PQ writes opaque alpha",1,px[3]>0.99f); } }
        // The ordinary SDR picture stays byte-identical with HDR enabled and the game told.
        EXPECT("SDR -> SDR variant unchanged",PV_SDR,present_variant(0,MTLPixelFormatBGRA8Unorm));
        { uint8_t *o=present_to(sdr,16,16,0); EXPECT("HDR on: SDR present byte-identical",0,memcmp(o,sdr_before,16*16*4)); free(o); }
        // Screenshots of an HDR10 window are SDR PNGs; DM_HDR_SHOT_RAW keeps the exact PQ words beside it.
        { char dir[]="/tmp/t_hdr_crop_XXXXXX"; if(mkdtemp(dir)) { char path[256]; snprintf(path,sizeof path,"%s/shot.png",dir);
              setenv("DM_HDR_SHOT_RAW","1",1); shot(pqw,path,1,NULL);
              CGImageSourceRef is=CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:@(path)],NULL);
              CGImageRef im=is?CGImageSourceCreateImageAtIndex(is,0,NULL):NULL;
              EXPECT("HDR screenshot written",1,im!=NULL);
              if(im){ CFDataRef dd=CGDataProviderCopyData(CGImageGetDataProvider(im)); const uint8_t *b=CFDataGetBytePtr(dd); size_t bpr=CGImageGetBytesPerRow(im); const uint8_t *c=b+4*bpr+4*4;
                  EXPECT("HDR screenshot: 8-bit SDR",8,(int)CGImageGetBitsPerComponent(im));
                  EXPECT("HDR screenshot: paper white about 240, not PQ's 130",1,near(c[1],240,4)); CFRelease(dd);CGImageRelease(im); }
              if(is)CFRelease(is);
              char raw[256]; snprintf(raw,sizeof raw,"%s.raw",path); FILE *f=fopen(raw,"rb");
              EXPECT("raw RGB10A2 diagnostic written",1,f!=NULL); if(f){ char head[64]=""; fgets(head,sizeof head,f); EXPECT("raw header",1,strstr(head,"rgb10a2 8 8")!=NULL); fclose(f); unlink(raw); }
              unsetenv("DM_HDR_SHOT_RAW"); unlink(path); rmdir(dir); } }
        // One Upscaling preference for both colour modes: MetalFX selected (g_fx_mode=1, DM_HDR_UPSCALE unset)
        // sends a PQ picture through the HDR linear-light scaler, never the SDR perceptual scaler or bilinear.
        { g_fx_mode=1; unsetenv("DM_HDR_UPSCALE"); mtl_hdr_fx_reset();
          uint64_t was=g_present_n; g_present_n=g_fx_hdr.made_at+FX_REMAKE_PRESENTS;
          MTLTextureDescriptor *cd=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGB10A2Unorm width:32 height:32 mipmapped:NO];
          cd.storageMode=MTLStorageModeShared; cd.usage=MTLTextureUsageRenderTarget; id<MTLTexture> canvas=[g_dev newTextureWithDescriptor:cd]; res_add(canvas); res_commit();
          id<MTL4CommandAllocator> al=[g_dev newCommandAllocator]; id<MTL4CommandBuffer> cb=[g_dev newCommandBuffer]; id<MTLSharedEvent> ev=[g_dev newSharedEvent];
          [cb beginCommandBufferWithAllocator:al]; int kind=present_encode_m4(cb,pqw,canvas,NULL,g_present_uv[0],&g_fx_present); [cb endCommandBuffer];
          [g_q4 commit:&cb count:1]; [g_q4 signalEvent:ev value:1];
          EXPECT("HDR MetalFX present completes",1,[ev waitUntilSignaledValue:1 timeoutMS:10000]);
          EXPECT("MetalFX selection uses the HDR scaler for a PQ picture",PRESENT_METALFX,kind);
          EXPECT("HDR scaler is in HDR mode",(int)MTLFXSpatialScalerColorProcessingModeHDR,(int)g_fx_hdr.sc.colorProcessingMode);
          uint32_t px=0; [canvas getBytes:&px bytesPerRow:4 fromRegion:MTLRegionMake2D(16,16,1,1) mipmapLevel:0];
          EXPECT("HDR MetalFX output keeps the PQ code",1,near((px>>10&0x3ff)/1023.0f,520/1023.0f,0.002));
          res_remove(canvas); g_fx_mode=0; mtl_hdr_fx_reset(); g_present_n=was; }
        // Four-way selection matrix: the player's Upscaling row drives SDR and HDR alike; Standard never
        // incurs the HDR decode/scaler work, MetalFX never silently falls back, and an explicit HDR-only
        // diagnostic overrides the player choice deterministically.
        { dm_hdr_fx_test_fault=0; int hu=-1;
          EXPECT("matrix: SDR Standard is bilinear",PRESENT_STANDARD,selection_present(sdr,MTLPixelFormatBGRA8Unorm,16,16,0,NULL,&hu));
          EXPECT("matrix: SDR Standard does no HDR float work",0,hu);
          EXPECT("matrix: SDR MetalFX is perceptual MetalFX",PRESENT_METALFX,selection_present(sdr,MTLPixelFormatBGRA8Unorm,16,16,1,NULL,&hu));
          EXPECT("matrix: SDR MetalFX does no HDR float work",0,hu);
          EXPECT("matrix: HDR Standard is PQ bilinear",PRESENT_STANDARD,selection_present(pqw,MTLPixelFormatRGB10A2Unorm,16,16,0,NULL,&hu));
          EXPECT("matrix: HDR Standard does no HDR decode or scaler work",0,hu);
          EXPECT("matrix: HDR MetalFX is linear-light MetalFX",PRESENT_METALFX,selection_present(pqw,MTLPixelFormatRGB10A2Unorm,16,16,1,NULL,&hu));
          EXPECT("matrix: HDR MetalFX engages the HDR float scaler",1,hu);
          EXPECT("matrix: DM_HDR_UPSCALE=off forces HDR bilinear",PRESENT_STANDARD,selection_present(pqw,MTLPixelFormatRGB10A2Unorm,16,16,1,"off",&hu));
          EXPECT("matrix: off override does no HDR float work",0,hu);
          EXPECT("matrix: DM_HDR_UPSCALE=hdrfx forces HDR MetalFX on Standard",PRESENT_METALFX,selection_present(pqw,MTLPixelFormatRGB10A2Unorm,16,16,0,"hdrfx",&hu));
          EXPECT("matrix: hdrfx override engages the HDR float scaler",1,hu);
          // No scaling needed (1:1): neither colour mode runs a scaler even when MetalFX is selected.
          EXPECT("matrix: SDR MetalFX at 1:1 is bilinear",PRESENT_STANDARD,selection_present(sdr,MTLPixelFormatBGRA8Unorm,8,8,1,NULL,&hu));
          EXPECT("matrix: HDR MetalFX at 1:1 is bilinear",PRESENT_STANDARD,selection_present(pqw,MTLPixelFormatRGB10A2Unorm,8,8,1,NULL,&hu));
          EXPECT("matrix: HDR MetalFX at 1:1 does no HDR float work",0,hu);
          // Resolution change: a new output size still takes the HDR MetalFX path and engages the scaler.
          EXPECT("matrix: HDR MetalFX after an output resize",PRESENT_METALFX,selection_present(pqw,MTLPixelFormatRGB10A2Unorm,32,32,1,NULL,&hu));
          EXPECT("matrix: HDR MetalFX after resize engages the scaler",1,hu);
          dm_hdr_fx_test_fault=0; unsetenv("DM_HDR_UPSCALE"); g_fx_mode=0; mtl_hdr_fx_reset(); mtl_present_layer(1,1); }
        // Linear-light HDR scaler: check what the API actually produces. The source has a 203-nit patch on a
        // 10-nit background, so any code outside that range is overshoot.
        { setenv("DM_HDR_UPSCALE","hdrfx",1); mtl_hdr_fx_reset(); mtl_present_layer(16,9);   // fill the 16:9 canvas, no black bars in the readback
          MTLTextureDescriptor *sd=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGB10A2Unorm width:64 height:36 mipmapped:NO];
          sd.storageMode=MTLStorageModeShared; sd.usage=MTLTextureUsageShaderRead;
          id<MTLTexture> px=[g_dev newTextureWithDescriptor:sd]; uint32_t words[64*36];
          for(int y=0;y<36;y++)for(int x=0;x<64;x++){int c=(x>24&&x<40&&y>10&&y<26)?594:100;words[y*64+x]=pq_texel(c,c,c);}
          [px replaceRegion:MTLRegionMake2D(0,0,64,36) mipmapLevel:0 withBytes:words bytesPerRow:64*4];res_add(px);res_commit();
          MTLTextureDescriptor *cd=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGB10A2Unorm width:128 height:72 mipmapped:NO];
          cd.storageMode=MTLStorageModeShared; cd.usage=MTLTextureUsageRenderTarget; id<MTLTexture> canvas=[g_dev newTextureWithDescriptor:cd];res_add(canvas);res_commit();
          id<MTL4CommandAllocator> al=[g_dev newCommandAllocator];id<MTL4CommandBuffer> cb=[g_dev newCommandBuffer];id<MTLSharedEvent> ev=[g_dev newSharedEvent];
          [cb beginCommandBufferWithAllocator:al];int kind=present_encode_m4(cb,px,canvas,NULL,g_present_uv[0],&g_fx_present);[cb endCommandBuffer];
          [g_q4 commit:&cb count:1];[g_q4 signalEvent:ev value:1];
          EXPECT("HDR MetalFX experiment completes",1,[ev waitUntilSignaledValue:1 timeoutMS:10000]);
          EXPECT("HDR picture uses the experimental HDR scaler",PRESENT_METALFX,kind);
          EXPECT("HDR scaler is in HDR mode",(int)MTLFXSpatialScalerColorProcessingModeHDR,(int)g_fx_hdr.sc.colorProcessingMode);
          uint32_t out[128*72];[canvas getBytes:out bytesPerRow:128*4 fromRegion:MTLRegionMake2D(0,0,128,72) mipmapLevel:0];
          uint32_t lo=1023,hi=0;for(int i=0;i<128*72;i++){uint32_t c=out[i]&0x3ff;if(c<lo)lo=c;if(c>hi)hi=c;}
          printf("HDR MetalFX experiment: output PQ codes %u..%u (source 100..594); %s\n",lo,hi,
                 (hi>594+8||lo<100-8) ? "overshoot observed (why the experiment stays off)" : "no overshoot on this pattern");
          // Flat patches are exact to quantisation; excursions are confined to a few pixels where a 16x
          // input step meets the reconstruction filter. Tolerances: 2 codes for 10-bit quantisation and the
          // half-float round trip; 700/60 codes for this worst-case step (the old direct-PQ scaler reached
          // 813 at the same pattern). Ringing must decay to the source level within six output pixels.
          { uint32_t bg=out[4*4]&0x3ff, fg=out[36*128+64]&0x3ff;
            EXPECT("linear HDR scaler keeps the flat background",1,abs((int)bg-100)<=2);
            EXPECT("linear HDR scaler keeps the flat patch",1,abs((int)fg-594)<=2);
            EXPECT("linear HDR scaler reduces highlight overshoot",1,hi<=700&&hi>0);
            EXPECT("linear HDR scaler keeps low levels bounded",1,lo>=60&&lo<1023);
            EXPECT("linear HDR scaler preserves alpha",1,(out[4*4]>>30)==3&&(out[36*128+64]>>30)==3&&(out[36*128+50]>>30)==3);
            EXPECT("edge ringing decays to the source level",1,abs((int)(out[36*128+44]&0x3ff)-100)<=1&&abs((int)(out[36*128+56]&0x3ff)-593)<=1); }
          // Measurement, not a requirement: this SDK overshoots the source range on PQ codes, which is why
          // the experimental path is off. A future implementation that eliminates it must NOT fail this
          // test -- improved image quality is a reason to re-enable the path, not a regression.
          EXPECT("HDR MetalFX experiment produced valid 10-bit samples",1,lo<=1023&&hi>=0);
          res_remove(px);res_remove(canvas);unsetenv("DM_HDR_UPSCALE");mtl_hdr_fx_reset();mtl_present_layer(1,1); }
        // Independent multi-level pattern: 10, 100, 203, 400, 1000 and 2000 nits (codes computed outside
        // this tree, as in t_hdr.c's reference table), a saturated BT.2020 patch and a one-pixel highlight
        // line. Flat areas must survive the float intermediate exactly; only sharp edges may ring.
        { setenv("DM_HDR_UPSCALE","hdrfx",1); mtl_hdr_fx_reset(); mtl_present_layer(16,9);
          const int want[6]={307,520,594,668,769,846};
          uint32_t words[64*36];
          for(int y=0;y<36;y++)for(int x=0;x<64;x++){
              int b=x/11; if(b>5)b=5; int c=want[b];
              if(y>=28 && b==3) c=want[b];                       // same luminance band
              uint32_t pix=pq_texel(c,c,c);
              if(y>=28 && b==3) pix=pq_texel(594,307,769);        // saturated region, same peak channel
              if(y==8 && x>=11 && x<22) pix=pq_texel(846,846,846); // one-pixel bright line on the 100-nit band
              words[y*64+x]=pix; }
          MTLTextureDescriptor *sd=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGB10A2Unorm width:64 height:36 mipmapped:NO];
          sd.storageMode=MTLStorageModeShared; sd.usage=MTLTextureUsageShaderRead;
          id<MTLTexture> src=[g_dev newTextureWithDescriptor:sd];
          [src replaceRegion:MTLRegionMake2D(0,0,64,36) mipmapLevel:0 withBytes:words bytesPerRow:64*4]; res_add(src); res_commit();
          MTLTextureDescriptor *cd=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGB10A2Unorm width:128 height:72 mipmapped:NO];
          cd.storageMode=MTLStorageModeShared; cd.usage=MTLTextureUsageRenderTarget;
          id<MTLTexture> canvas=[g_dev newTextureWithDescriptor:cd]; res_add(canvas); res_commit();
          id<MTL4CommandAllocator> al=[g_dev newCommandAllocator]; id<MTL4CommandBuffer> cb=[g_dev newCommandBuffer]; id<MTLSharedEvent> ev=[g_dev newSharedEvent];
          [cb beginCommandBufferWithAllocator:al];
          int kind=present_encode_m4(cb,src,canvas,NULL,g_present_uv[0],&g_fx_present); [cb endCommandBuffer];
          [g_q4 commit:&cb count:1]; [g_q4 signalEvent:ev value:1];
          EXPECT("multi-level MetalFX present completes",1,[ev waitUntilSignaledValue:1 timeoutMS:10000]&&kind==PRESENT_METALFX);
          uint32_t out[128*72]; [canvas getBytes:out bytesPerRow:128*4 fromRegion:MTLRegionMake2D(0,0,128,72) mipmapLevel:0];
          for(int band=0;band<6;band++){ int sx=(band*11+5)*2, got=out[20*128+sx]&0x3ff;
              EXPECT("MetalFX flat-band error within one 10-bit code",1,abs(got-want[band])<=1); }
          uint32_t sat=out[60*128+(3*11+5)*2];
          EXPECT("MetalFX keeps saturated R",1,abs((int)(sat&0x3ff)-594)<=1);
          EXPECT("MetalFX keeps saturated G",1,abs((int)((sat>>10)&0x3ff)-307)<=1);
          EXPECT("MetalFX keeps saturated B",1,abs((int)((sat>>20)&0x3ff)-769)<=1);
          uint32_t hi=0; for(int x=24;x<44;x++){uint32_t c=out[18*128+x]&0x3ff; if(c>hi)hi=c;}
          EXPECT("one-pixel highlight ringing is bounded",1,hi<=846+80);
          res_remove(src); res_remove(canvas); unsetenv("DM_HDR_UPSCALE"); mtl_hdr_fx_reset(); mtl_present_layer(1,1); }
        // The linear path must honour the same crop and non-integer scale as the bilinear path: the
        // decoder gets the crop rectangle, the scaler the cropped size, and the present maps its output 1:1.
        { setenv("DM_HDR_UPSCALE","hdrfx",1); mtl_hdr_fx_reset();
          int cr[4]={1,1,6,6};   // the fixture's PQ window is 8x8
          uint32_t v=present_pq_at(pqw,cr,21,13,10,6,1);
          EXPECT("linear HDR scaler keeps a flat PQ code through crop and non-integer scale",1,abs((int)(v>>10&0x3ff)-520)<=2);
          unsetenv("DM_HDR_UPSCALE"); mtl_hdr_fx_reset(); }
        // Headroom roll-off with opt-in MetalFX. The mode-4 guard is gone: the shoulder now runs ONCE in
        // fs_hdr_fx after scaling. For each macOS-reported potential/current pair, paper white must stay at
        // code 520 and a 2000-nit highlight must either pass unchanged (no roll-off) or land on the target.
        { uint32_t words[64*36];
          for(int y=0;y<36;y++)for(int x=0;x<64;x++){int c=x<32?520:846;words[y*64+x]=pq_texel(c,c,c);}
          MTLTextureDescriptor *sd=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGB10A2Unorm width:64 height:36 mipmapped:NO];
          sd.storageMode=MTLStorageModeShared; sd.usage=MTLTextureUsageShaderRead;
          id<MTLTexture> src=[g_dev newTextureWithDescriptor:sd];res_add(src);res_commit();
          [src replaceRegion:MTLRegionMake2D(0,0,64,36) mipmapLevel:0 withBytes:words bytesPerRow:64*4];
          MTLTextureDescriptor *cd=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGB10A2Unorm width:128 height:72 mipmapped:NO];
          cd.storageMode=MTLStorageModeShared; cd.usage=MTLTextureUsageRenderTarget;
          id<MTLTexture> canvas=[g_dev newTextureWithDescriptor:cd];res_add(canvas);res_commit();
          const double pots[]={2,2,2,4,8,16}, curs[]={1,1.1,1.5,2,4,8};
          int roll_seen=0;
          for(unsigned i=0;i<sizeof pots/sizeof *pots;i++){
              int64_t t=12000+(int64_t)i*1000;
              dm_hdr_screen(pots[i],curs[i],t); dm_hdr_screen(pots[i],curs[i],t+500);
              dm_hdr_layer_tick(1,t+600);
              setenv("DM_HDR_PEAK","2000",1); uint16_t pk=0; dm_hdr_answer(&pk);
              dm_hdr_meta_set(HDR_META_EXT,0,4000);
              int kind=hdr_fx_rolloff_present(src,canvas);
              uint32_t paper=0,hi=0;
              [canvas getBytes:&paper bytesPerRow:4 fromRegion:MTLRegionMake2D(32,36,1,1) mipmapLevel:0];
              [canvas getBytes:&hi bytesPerRow:4 fromRegion:MTLRegionMake2D(96,36,1,1) mipmapLevel:0];
              float knee=0,target=0,source=0; int roll=dm_hdr_rolloff(&knee,&target,&source); roll_seen+=roll;
              char label[96]; snprintf(label,sizeof label,"MetalFX used with potential %.1f current %.1f",pots[i],curs[i]);
              EXPECT(label,PRESENT_METALFX,kind);
              snprintf(label,sizeof label,"paper white at potential %.1f current %.1f",pots[i],curs[i]);
              EXPECT(label,1,abs((int)(paper>>10&0x3ff)-520)<=2);
              int got=(int)(hi>>10&0x3ff), want=roll?(int)(hdr_pq_code(target)*1023.0):846;
              snprintf(label,sizeof label,"highlight target at current %.1f",curs[i]);
              EXPECT(label,1,got>0&&got<=1023&&abs(got-want)<=4);
              if (i==2) {   // the bilinear fallback must still apply exactly one shoulder when roll-off is active
                  dm_hdr_fx_test_fault=1;
                  int k2=hdr_fx_rolloff_present(src,canvas); uint32_t h2=0;
                  [canvas getBytes:&h2 bytesPerRow:4 fromRegion:MTLRegionMake2D(96,36,1,1) mipmapLevel:0];
                  dm_hdr_fx_test_fault=0;
                  EXPECT("roll-off decode failure uses bilinear",PRESENT_STANDARD,k2);
                  EXPECT("bilinear fallback applies one shoulder",1,abs((int)(h2>>10&0x3ff)-want)<=4);
              }
          }
          EXPECT("headroom shoulder was active and used MetalFX in several configurations",1,roll_seen>=4);
          unsetenv("DM_HDR_PEAK"); dm_hdr_meta_set(HDR_META_EXT,0,0);
          dm_hdr_fx_test_fault=0; mtl_hdr_fx_reset(); unsetenv("DM_HDR_UPSCALE");
          res_remove(src);res_remove(canvas); }
        // Failure paths: a decode or scaler failure must select bilinear PQ presentation, keep the exact
        // source code and recover on the next frame. No failure may be reported as a MetalFX present.
        { uint32_t code=0;
          int k=hdr_fx_fault_present(pqw,0,&code,1);
          EXPECT("no fault: opt-in path uses MetalFX",PRESENT_METALFX,k);
          EXPECT("no fault: PQ code preserved",1,abs((int)(code>>10&0x3ff)-520)<=2);
          k=hdr_fx_fault_present(pqw,1,&code,1);
          EXPECT("decode failure falls back to bilinear",PRESENT_STANDARD,k);
          EXPECT("decode failure keeps PQ code",1,abs((int)(code>>10&0x3ff)-520)<=2);
          k=hdr_fx_fault_present(pqw,2,&code,1);
          EXPECT("decode texture failure falls back",PRESENT_STANDARD,k);
          EXPECT("decode texture failure keeps PQ code",1,abs((int)(code>>10&0x3ff)-520)<=2);
          k=hdr_fx_fault_present(pqw,4,&code,1);
          EXPECT("refused scaler falls back",PRESENT_STANDARD,k);
          EXPECT("refused scaler keeps PQ code",1,abs((int)(code>>10&0x3ff)-520)<=2);
          k=hdr_fx_fault_present(pqw,8,&code,1);
          EXPECT("scaler encode failure falls back",PRESENT_STANDARD,k);
          EXPECT("encode failure keeps PQ code",1,abs((int)(code>>10&0x3ff)-520)<=2);
          k=hdr_fx_fault_present(pqw,0,&code,1);
          EXPECT("recovery after failures uses MetalFX again",PRESENT_METALFX,k);
          EXPECT("recovery keeps PQ code",1,abs((int)(code>>10&0x3ff)-520)<=2);
          dm_hdr_fx_test_fault=0; mtl_hdr_fx_reset(); unsetenv("DM_HDR_UPSCALE"); }
        // Automatic recovery in one uninterrupted session: no reset between frames. A transient decode
        // failure falls back for that frame and the next frame uses MetalFX again. A refused descriptor is
        // different: its exact configuration stays in the refusal cache until a reset or a size change, so
        // retrying a scaler MetalFX already rejected would stall every frame. That policy is intentional.
        { uint32_t code=0;
          dm_hdr_fx_test_fault=0; mtl_hdr_fx_reset(); setenv("DM_HDR_UPSCALE","hdrfx",1);
          EXPECT("uninterrupted: first frame uses MetalFX",PRESENT_METALFX,hdr_fx_fault_present(pqw,0,&code,0));
          EXPECT("uninterrupted: first frame PQ code",1,abs((int)(code>>10&0x3ff)-520)<=2);
          EXPECT("uninterrupted: transient decode failure falls back",PRESENT_STANDARD,hdr_fx_fault_present(pqw,1,&code,0));
          EXPECT("uninterrupted: fallback PQ code",1,abs((int)(code>>10&0x3ff)-520)<=2);
          EXPECT("uninterrupted: next frame recovers without reset",PRESENT_METALFX,hdr_fx_fault_present(pqw,0,&code,0));
          EXPECT("uninterrupted: recovered PQ code",1,abs((int)(code>>10&0x3ff)-520)<=2);
          mtl_hdr_fx_reset();   // drop the scaler so the refused descriptor has to be rebuilt
          EXPECT("refused descriptor falls back",PRESENT_STANDARD,hdr_fx_fault_present(pqw,4,&code,0));
          EXPECT("refusal stays cached without reset",PRESENT_STANDARD,hdr_fx_fault_present(pqw,0,&code,0));
          EXPECT("reset retries the refused descriptor",PRESENT_METALFX,hdr_fx_fault_present(pqw,0,&code,1));
          dm_hdr_fx_test_fault=0; mtl_hdr_fx_reset(); unsetenv("DM_HDR_UPSCALE"); }
        // Indicative steady-state GPU cost of the present at 2x scaling, measured on this GPU. This is a
        // synthetic flat picture, NOT a gameplay benchmark: it excludes game rendering and compositing,
        // so it cannot be used to choose the production path on its own.
        {
          const int outs[][2]={{1920,1080},{2560,1440},{3840,2160},{5120,2880}};
          for(unsigned s=0;s<sizeof outs/sizeof *outs;s++){
              int w=outs[s][0], h=outs[s][1];
              MTLTextureDescriptor *bd=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGB10A2Unorm width:w/2 height:h/2 mipmapped:NO];
              bd.storageMode=MTLStorageModeShared; bd.usage=MTLTextureUsageShaderRead;
              id<MTLTexture> half=[g_dev newTextureWithDescriptor:bd]; res_add(half); res_commit();
              uint32_t *halfw=malloc((size_t)(w/2)*(h/2)*sizeof(uint32_t));
              for(int i=0;i<(w/2)*(h/2);i++) halfw[i]=pq_texel(520,520,520);
              [half replaceRegion:MTLRegionMake2D(0,0,w/2,h/2) mipmapLevel:0 withBytes:halfw bytesPerRow:(w/2)*4];
              double bp=present_gpu_median_ms(half,0,12,w,h), fp=present_gpu_median_ms(half,1,12,w,h);
              printf("present GPU median (%dx%d -> %dx%d, flat PQ, 12 presents): bilinear %.3f ms, linear MetalFX %.3f ms\n",w/2,h/2,w,h,bp,fp);
              char label[96]; snprintf(label,sizeof label,"valid GPU timing at %dx%d",w,h);
              EXPECT(label,1,bp>0.0&&fp>0.0);
              free(halfw); res_remove(half);
          }
          unsetenv("DM_HDR_UPSCALE"); mtl_hdr_fx_reset(); }
        // Reconstruction sharpness: a vertical step (codes 100 -> 594 in HDR, bytes 51 -> 204 in SDR) is
        // upscaled 2x by each path; report the 10%-90% transition width in output pixels.
        { uint32_t pw[64*36]; uint8_t sb[64*36*4];
          for(int y=0;y<36;y++)for(int x=0;x<64;x++){ int c=x<32?100:594;
              pw[y*64+x]=pq_texel(c,c,c);
              uint8_t lv=x<32?51:204; uint8_t *p=sb+(y*64+x)*4; p[0]=p[1]=p[2]=lv; p[3]=255; }
          MTLTextureDescriptor *pd=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGB10A2Unorm width:64 height:36 mipmapped:NO];
          pd.storageMode=MTLStorageModeShared; pd.usage=MTLTextureUsageShaderRead;
          id<MTLTexture> pqsrc=[g_dev newTextureWithDescriptor:pd]; res_add(pqsrc); res_commit();
          [pqsrc replaceRegion:MTLRegionMake2D(0,0,64,36) mipmapLevel:0 withBytes:pw bytesPerRow:64*4];
          MTLTextureDescriptor *sd=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:64 height:36 mipmapped:NO];
          sd.storageMode=MTLStorageModeShared; sd.usage=MTLTextureUsageShaderRead;
          id<MTLTexture> sdrsrc=[g_dev newTextureWithDescriptor:sd]; res_add(sdrsrc); res_commit();
          [sdrsrc replaceRegion:MTLRegionMake2D(0,0,64,36) mipmapLevel:0 withBytes:sb bytesPerRow:64*4];
          double eb=present_edge_width(pqsrc,0), ef=present_edge_width(pqsrc,1), es=present_edge_width(sdrsrc,2);
          printf("2x step 10-90%% edge width: HDR bilinear %.1f px, linear HDR MetalFX %.1f px, SDR MetalFX %.1f px\n",eb,ef,es);
          EXPECT("linear HDR MetalFX is at least as sharp as HDR bilinear",1,eb>=0&&ef>=0&&ef<=eb);
          unsetenv("DM_HDR_UPSCALE"); unsetenv("DM_PRESENT_UPSCALE"); g_fx_mode=0; mtl_hdr_fx_reset(); mtl_present_layer(1,1);
          res_remove(pqsrc); res_remove(sdrsrc); }
        res_remove(sdr); res_remove(pqw); free(sdr_before); mtl_present_layer(0,0);
    }
#endif
    h_nvnQueueFinalize(&queue);
    printf("== %d checks, %d failed ==\n",cases,failed);return failed!=0;
} }
