// Native HDR10 output (DM_HDR): a game that renders HDR itself is told so through vi (hle_vi.c) while the
// window's screen can show it, and its HDR10 window (RGB10A2 holding SMPTE ST 2084 code values of BT.2020
// colours) is presented unchanged into an RGB10A2 / BT.2100 PQ CAMetalLayer (front_mac.m, nvn_mtl.m).
//
// The setting is read once; the screen only decides whether it is in effect, so moving a window between an
// HDR and an SDR screen, full screen changes or a brightness change switch HDR live without a restart. The
// pure colour and decision helpers are here (t_hdr.c tests them); the atomics shared by the front end, vi
// and the present thread are in hdr.c.
#pragma once
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

// Apple's documented EDR capability test: a potential headroom greater than 1.0 means the display supports
// EDR, whatever the display's brand or its current headroom. https://developer.apple.com/documentation/metal/determining-support-for-edr-values
// This is a capability, not available brightness: an HDR-capable display can currently report 1.0. The game
// window's own NSScreen supplies the value; a television macOS reports as SDR is respected as SDR.
#define HDR_CAPABLE_POTENTIAL 1.0
// A capability change must hold this long before the layer switches, so a window dragged across a screen
// edge does not toggle it on every notification. A pending change is settled by a one-shot timer (front_mac.m).
#define HDR_SETTLE_MS 500
// Paper white (vi::QueryDisplayHdrPaperWhite): 100 nits, which a PQ layer without metadata shows at the
// screen's ordinary SDR white. PR #1176 validated this mapping on macOS; 203 nits (BT.2408) made the whole
// picture about twice as bright as SDR on Ocarina of Time. A diagnostic override is kept for calibration.
#define HDR_PAPER_WHITE_DEFAULT 100
#define HDR_PAPER_WHITE_MIN 80
#define HDR_PAPER_WHITE_MAX 1000
// The peak told to the game and the step it moves in (PR #1176: a stepped answer with a hold avoids
// re-tone-mapping the game at every frame while the brightness slider moves).
#define HDR_PEAK_MAX_NITS 1600.0
#define HDR_PEAK_STEP 10.0
#define HDR_PEAK_HOLD_MS 1000

enum { HDR_PREF_OFF = 0, HDR_PREF_AUTO = 1 };

// DM_HDR: auto / 0, empty uses dflt (the game profile's DM_GAME_HDR). Anything else is reported once.
static inline int hdr_pref_parse(const char *e, int dflt, int *bad) {
    if (bad) *bad = 0;
    if (!e || !*e) return dflt;
    if (!strcmp(e, "auto")) return HDR_PREF_AUTO;
    if (!strcmp(e, "0") || !strcmp(e, "off")) return HDR_PREF_OFF;
    if (bad) *bad = 1;
    return dflt;
}
static inline int hdr_paper_white_parse(const char *e) {
    if (!e || !*e) return HDR_PAPER_WHITE_DEFAULT;
    char *end = NULL; long v = strtol(e, &end, 10);
    if (*end || v < HDR_PAPER_WHITE_MIN || v > HDR_PAPER_WHITE_MAX) return -1;
    return (int)v;
}
static inline int hdr_capable(double potential) {
    return isfinite(potential) && potential > HDR_CAPABLE_POTENTIAL;
}
// Apple exposes three different EDR values. Potential says whether the display can show EDR at all; current
// says how much range it can show right now; reference is the range a calibrated reference display can
// reproduce without its own tone mapping (0 when the hardware has no reference rendering). Consumer HDR
// presentation uses CURRENT. A reference display's smaller value is not a general ceiling: applying it to an
// HDR television would impose a reference-monitor workflow Apple only documents for colour-grading displays.
// https://developer.apple.com/documentation/appkit/nsscreen/maximumreferenceextendeddynamicrangecolorcomponentvalue
static inline double hdr_output_headroom(double current, double reference) {
    (void)reference;
    return isfinite(current) && current > 0 ? current : 1.0;
}
static inline int hdr_decide(int pref, int capable) { return pref == HDR_PREF_AUTO && capable; }
typedef struct { int pref, capable, on; double potential; } hdr_decision;
static inline int hdr_decision_screen(hdr_decision *d, double potential) {
    d->potential = potential; d->capable = hdr_capable(potential); d->on = hdr_decide(d->pref, d->capable);
    return d->on;
}
// The peak (nits) the game is told: paper white times the display's current headroom, never below the paper
// white or above the PQ panel's practical peak. A non-finite headroom is treated as unknown (1x).
static inline uint16_t hdr_peak_nits(double headroom, double paper_white) {
    if (!(isfinite(headroom) && headroom > 0)) headroom = 1.0;
    double v = paper_white * headroom;
    if (!(v >= paper_white)) v = paper_white;
    if (v > HDR_PEAK_MAX_NITS) v = HDR_PEAK_MAX_NITS;
    double step = round(v / HDR_PEAK_STEP) * HDR_PEAK_STEP;
    if (step < HDR_PEAK_STEP) step = HDR_PEAK_STEP;
    return (uint16_t)step;
}

// SMPTE ST 2084 (PQ) EOTF / inverse EOTF. Code values are normalised 0..1, luminance 0..10000 nits.
#define HDR_PQ_M1 (2610.0 / 16384.0)
#define HDR_PQ_M2 (2523.0 / 4096.0 * 128.0)
#define HDR_PQ_C1 (3424.0 / 4096.0)
#define HDR_PQ_C2 (2413.0 / 4096.0 * 32.0)
#define HDR_PQ_C3 (2392.0 / 4096.0 * 32.0)
static inline double hdr_pq_nits(double code) {
    if (!(code > 0)) return 0;
    if (code > 1) code = 1;
    double p = pow(code, 1.0 / HDR_PQ_M2), n = p - HDR_PQ_C1;
    if (n < 0) n = 0;
    double d = HDR_PQ_C2 - HDR_PQ_C3 * p;
    if (!(d > 1e-6)) d = 1e-6;
    return 10000.0 * pow(n / d, 1.0 / HDR_PQ_M1);
}
static inline double hdr_pq_code(double nits) {
    if (!(nits > 0)) return 0;
    double y = pow(fmin(nits, 10000.0) / 10000.0, HDR_PQ_M1);
    return pow((HDR_PQ_C1 + HDR_PQ_C2 * y) / (1.0 + HDR_PQ_C3 * y), HDR_PQ_M2);
}
// One RGB10A2Unorm texel (R bits 0-9, G 10-19, B 20-29, A 30-31) to normalised code values.
static inline void hdr_rgb10a2_codes(uint32_t texel, double out[3]) {
    for (int i = 0; i < 3; i++) out[i] = ((texel >> (10 * i)) & 0x3ff) / 1023.0;
}
// Linear-light primaries (ITU-R BT.2087; each row sums to 1, so grey stays grey). Apply to *linear* light,
// never to PQ code values.
static const double HDR_BT2020_TO_709[3][3] = {
    { 1.660491, -0.587641, -0.072850},
    {-0.124550,  1.132900, -0.008349},
    {-0.018151, -0.100579,  1.118730},
};
static const double HDR_BT709_TO_2020[3][3] = {
    { 0.627404,  0.329283,  0.043313},
    { 0.069097,  0.919540,  0.011362},
    { 0.016391,  0.088013,  0.895595},
};
static inline void hdr_bt2020_to_709(const double in[3], double out[3]) {
    for (int i = 0; i < 3; i++) {
        double v = 0; for (int j = 0; j < 3; j++) v += HDR_BT2020_TO_709[i][j] * in[j];
        out[i] = v;
    }
}
static inline void hdr_bt709_to_2020(const double in[3], double out[3]) {
    for (int i = 0; i < 3; i++) {
        double v = 0; for (int j = 0; j < 3; j++) v += HDR_BT709_TO_2020[i][j] * in[j];
        out[i] = v;
    }
}
// A pure power display curve (BT.709's 2.2, the Switch's own panel; g = 0 uses piecewise sRGB).
static inline double hdr_sdr_decode(double c, double g) {
    if (!(c > 0)) return 0;
    if (g > 0) return pow(c, g);
    return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4);
}
static inline double hdr_sdr_encode(double c, double g) {
    if (!(c > 0)) return 0;
    if (c > 1) c = 1;
    if (g > 0) return pow(c, 1.0 / g);
    return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1.0 / 2.4) - 0.055;
}
// Rational shoulder: unit slope at the knee, the source peak lands exactly on the target; the brightest
// channel sets the scale so the hue is kept. Used for HDR -> SDR screenshots and for a controlled roll-off.
static inline double hdr_shoulder(double m, double knee, double target, double source) {
    if (!(m > knee)) return m;
    double a = target - knee, x = m - knee;
    if (!(a > 0)) return target;
    double f = knee + x / (1.0 + x * (1.0 / a - 1.0 / fmax(source - knee, a)));
    return f > target ? target : f;
}
// An HDR10 window brought to an SDR PNG: linear BT.709 in paper whites, knee 0.75, target 1.
static inline double hdr_sdr_shoulder(double m) { return hdr_shoulder(m, 0.75, 1.0, 50.0); }

// ---------- Shared state (hdr.c; any thread) ----------
void dm_hdr_boot(void);                       // after the modules load: a profile with hdr on is present
int  dm_hdr_pref(void);                       // DM_HDR, read once (default DM_GAME_HDR)
int  dm_hdr_paper_white(void);                // nits (DM_HDR_PAPER_WHITE, default 100)
void dm_hdr_screen(double potential, double current, int64_t now_ms);   // front end, on screen events/ticks
int  dm_hdr_capable(void);                    // committed capability, after the debounce; for diagnostics/tests
int  dm_hdr_pending(int64_t *due_ms);         // 1 while a capability change awaits its one-shot settle timer
void dm_hdr_headroom_set(double current);     // current EDR headroom (the brightness slider sends no notice)
int  dm_hdr_layer_tick(int layer_pq, int64_t now_ms);   // front end: 1 if the window should have the PQ layer
void dm_hdr_present(int pq);                  // present thread: the picture just drawn was (not) the HDR window
// Called once when the second consecutive SDR present completes an HDR -> SDR transition. The Mac front end
// overrides the weak no-op with one main-thread reevaluation; no dispatch happens on other presents.
void dm_hdr_settle_request(void);
int  dm_hdr_on(void);                         // the setting and the screen allow HDR
int  dm_hdr_ready(void);                      // the PQ drawable is in place: vi may answer HDR
int  dm_hdr_answer(uint16_t *peak);           // vi::QueryDisplayHdrStatus
int  dm_hdr_told(void);                       // the game has been answered HDR: its RGB10A2 window is PQ
float dm_hdr_headroom(void);                  // current EDR headroom, at least 1
float dm_hdr_source_peak(void);               // the brightest level the game may draw, in nits (0 unknown)
int  dm_hdr_rolloff(float *knee, float *target, float *source);   // 1 if a controlled roll-off is needed
enum { HDR_ST_SDR_READY, HDR_ST_HDR_REQUESTED, HDR_ST_HDR_LAYER_READY, HDR_ST_HDR_ACTIVE, HDR_ST_SDR_REQUESTED };
int  dm_hdr_state(void);                      // the conceptual state, for diagnostics

enum { HDR_META_STD, HDR_META_EXT, HDR_META_GAMUT, HDR_META_TONE };
typedef struct { int std_lo, std_hi, ext_lo, ext_hi, gamut, tone, set; } dm_hdr_meta;
void dm_hdr_meta_set(int which, int a, int b);
void dm_hdr_meta_get(dm_hdr_meta *m);
