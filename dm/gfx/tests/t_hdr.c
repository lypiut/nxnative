// Native HDR10: pure colour and decision helpers (nvn/hdr.h) and the shared state (hdr.c). CPU only; the
// GPU side of the same conversions is exercised by t_present_crop.
#include "../nvn/hdr.h"
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
static int failed, cases;
static _Atomic int thread_bad;
static _Atomic int settle_calls;
void dm_hdr_settle_request(void) { atomic_fetch_add(&settle_calls, 1); }   // strong override of hdr.c's weak no-op

// vi, the front end and the present thread all touch the shared state. Keep every writer busy at once and
// check only interleaving-independent invariants; the atomics must never publish a nonsensical combination.
static void *hdr_worker(void *arg) {
    int id = (int)(intptr_t)arg;
    for (int i = 0; i < 2000; i++) {
        dm_hdr_screen(i & 1 ? 2.0 : 1.0, 1.0 + (i & 7) * 0.1, i * 100 + id);
        dm_hdr_layer_tick(i & 1, i * 100 + id);
        dm_hdr_headroom_set(1.0 + (i & 7));
        uint16_t pk = 0; int on = dm_hdr_answer(&pk);
        int capable = dm_hdr_capable();
        if ((capable != 0 && capable != 1) || !(dm_hdr_headroom() > 0) ||
            (on && (pk < HDR_PAPER_WHITE_MIN && pk != 0)) || dm_hdr_pref() != HDR_PREF_AUTO)
            atomic_store(&thread_bad, 1);
    }
    return NULL;
}
#define EXPECT(n, w, v) do { long a = (w), b = (v); cases++; printf("%s expected %ld → got %ld %s\n", n, a, b, a == b ? "✓" : "✗"); failed += a != b; } while (0)
#define NEAR(n, w, v, tol) do { double a = (w), b = (v); cases++; int ok = fabs(a - b) <= (tol); printf("%s expected %.6g → got %.6g %s\n", n, a, b, ok ? "✓" : "✗"); failed += !ok; } while (0)

// Independent references. The nits/code pairs below were computed outside this tree with double-precision
// maths from the SMPTE ST 2084 equations, then rounded to 10-bit codes; the matrix is derived from the
// BT.2020 and BT.709 chromaticities (and printed by the same derivation), not copied from hdr.h. They make
// the assertions below compare the production helpers with a second implementation and with quantisation.
static const double REF_PQ[][3] = {
    {0,       0.000000731, 0},          {10,   0.299699092, 307},
    {50,      0.440281573, 450},        {100,  0.508078422, 520},
    {203,     0.580688881, 594},        {400,  0.652578598, 668},
    {1000,    0.751827096, 769},        {1600, 0.803099453, 822},
    {2000,    0.827424645, 846},        {4000, 0.902572393, 923},
    {10000,   1.0,         1023},
};
static const double REF_2020_TO_709[3][3] = {
    { 1.660491, -0.587641, -0.072850},
    {-0.124550,  1.132900, -0.008349},
    {-0.018151, -0.100579,  1.118730},
};
static uint32_t ref_pack10(int r, int g, int b, int a) {
    return (uint32_t)r | (uint32_t)g << 10 | (uint32_t)b << 20 | (uint32_t)a << 30;
}

int main(void) {
    int bad;
    // DM_HDR: auto / 0, unset uses the profile default (DM_GAME_HDR), anything else is reported.
    EXPECT("unset: profile default auto", HDR_PREF_AUTO, hdr_pref_parse(NULL, HDR_PREF_AUTO, &bad)); EXPECT("not bad", 0, bad);
    EXPECT("unset: profile default off", HDR_PREF_OFF, hdr_pref_parse(NULL, HDR_PREF_OFF, &bad));
    EXPECT("empty: default", HDR_PREF_AUTO, hdr_pref_parse("", HDR_PREF_AUTO, &bad));
    EXPECT("auto", HDR_PREF_AUTO, hdr_pref_parse("auto", HDR_PREF_OFF, &bad)); EXPECT("auto not bad", 0, bad);
    EXPECT("0", HDR_PREF_OFF, hdr_pref_parse("0", HDR_PREF_AUTO, &bad)); EXPECT("0 not bad", 0, bad);
    const char *wrong[] = {"1", "on", "Auto", "yes", "2", " auto"};
    for (unsigned i = 0; i < sizeof wrong / sizeof *wrong; i++) {
        EXPECT(wrong[i], HDR_PREF_AUTO, hdr_pref_parse(wrong[i], HDR_PREF_AUTO, &bad));
        EXPECT("reported", 1, bad);
    }
    // Paper white.
    EXPECT("paper white default", HDR_PAPER_WHITE_DEFAULT, hdr_paper_white_parse(NULL));
    EXPECT("paper white 250", 250, hdr_paper_white_parse("250"));
    EXPECT("paper white 79 refused", -1, hdr_paper_white_parse("79"));
    EXPECT("paper white 1001 refused", -1, hdr_paper_white_parse("1001"));
    EXPECT("paper white junk refused", -1, hdr_paper_white_parse("2x"));
    // Apple's documented capability test: potential EDR headroom > 1.0, with no display-brand assumption
    // and no 4x XDR-derived threshold (https://developer.apple.com/documentation/metal/determining-support-for-edr-values).
    const double potentials[] = {1.0, 1.1, 1.5, 2.0, 3.0, 4.0, 8.0, 16.0, 0, -1, NAN, INFINITY, -INFINITY};
    const int capable[] =       {0,   1,   1,   1,   1,   1,   1,   1,   0,  0,  0,   0,       0};
    for (unsigned i = 0; i < sizeof potentials / sizeof *potentials; i++) {
        char name[96]; snprintf(name, sizeof name, "potential %.1f capability", potentials[i]);
        EXPECT(name, capable[i], hdr_capable(potentials[i]));
    }
    EXPECT("nextafter(1.0) is capable (strict >)", 1, hdr_capable(nextafter(1.0, 2.0)));
    EXPECT("just below 1.0 is not capable", 0, hdr_capable(nextafter(1.0, 0.0)));
    EXPECT("potential capability independent of current headroom", 1, hdr_decide(HDR_PREF_AUTO, hdr_capable(1.1)));
    // setting x capability
    EXPECT("auto x capable", 1, hdr_decide(HDR_PREF_AUTO, 1));
    EXPECT("auto x not capable", 0, hdr_decide(HDR_PREF_AUTO, 0));
    EXPECT("0 x capable", 0, hdr_decide(HDR_PREF_OFF, 1));
    EXPECT("0 x not capable", 0, hdr_decide(HDR_PREF_OFF, 0));
    const double screens[] = {16, 2, 16, 1, 16};
    const int want[] = {1, 1, 1, 0, 1};   // 2x potential is EDR-capable under Apple's > 1.0 test
    for (int pref = HDR_PREF_OFF; pref <= HDR_PREF_AUTO; pref++) {
        hdr_decision d = {.pref = pref};
        for (unsigned i = 0; i < sizeof screens / sizeof *screens; i++) {
            char name[80]; snprintf(name, sizeof name, "screen %u (%.0f), pref %d", i, screens[i], pref);
            EXPECT(name, pref ? want[i] : 0, hdr_decision_screen(&d, screens[i]));
            EXPECT("setting unchanged", pref, d.pref);
        }
    }
    // Capability is debounced state. A SINGLE screen notification records a pending change; the caller's
    // bounded one-shot timer re-reads the same values at the due time. No continuing poll is required, and
    // none of these steps calls dm_hdr_layer_tick (which is the only place the layer's want flag changes).
    setenv("DM_HDR", "auto", 1);
    int64_t due = 0;
    dm_hdr_screen(1.0, 1.0, 1000);
    EXPECT("first reading commits SDR", 0, dm_hdr_capable());
    EXPECT("no pending at SDR", 0, dm_hdr_pending(NULL));
    dm_hdr_screen(2.0, 1.1, 1100);              // 2x potential capability, only 1.1x current brightness
    EXPECT("pending after one notification", 1, dm_hdr_pending(&due));
    EXPECT("settle due after 500 ms", 1600, (int)due);
    EXPECT("capability held back until settled", 0, dm_hdr_capable());
    NEAR("current headroom is independent of potential", 1.1, dm_hdr_headroom(), 1e-6);
    dm_hdr_screen(2.0, 1.5, 1400);
    EXPECT("still held back before due", 0, dm_hdr_capable());
    dm_hdr_screen(2.0, 1.5, 1600);
    EXPECT("committed at the one-shot timer", 1, dm_hdr_capable());
    EXPECT("pending cleared after commit", 0, dm_hdr_pending(NULL));
    NEAR("current headroom updated independently", 1.5, dm_hdr_headroom(), 1e-6);
    dm_hdr_screen(1.0, 1.0, 2000);              // HDR -> SDR, also with one notification
    EXPECT("SDR change pending", 1, dm_hdr_pending(&due));
    EXPECT("SDR settle due", 2500, (int)due);
    EXPECT("HDR capability held while pending", 1, dm_hdr_capable());
    dm_hdr_screen(1.0, 1.0, 2500);
    EXPECT("SDR committed at the timer", 0, dm_hdr_capable());
    dm_hdr_screen(16.0, 8.0, 3000); dm_hdr_screen(16.0, 8.0, 3500);
    EXPECT("high-headroom display capable", 1, dm_hdr_capable());
    dm_hdr_screen(0.0, 1.0, 3600);              // window temporarily offscreen: explicit SDR, no main-screen fallback
    EXPECT("offscreen change pending", 1, dm_hdr_pending(NULL));
    dm_hdr_screen(0.0, 1.0, 4100);
    EXPECT("offscreen window is SDR", 0, dm_hdr_capable());
    dm_hdr_screen(1.1, 1.0, 4200); dm_hdr_screen(1.0, 1.0, 4300); dm_hdr_screen(1.1, 1.0, 4400);
    EXPECT("rapid change restarts the hold", 1, dm_hdr_pending(&due));
    EXPECT("rapid change due from the last event", 4900, (int)due);
    EXPECT("rapid change not committed early", 0, dm_hdr_capable());
    dm_hdr_screen(1.1, 1.0, 4900);
    EXPECT("third-party low-potential display is EDR capable", 1, dm_hdr_capable());
    dm_hdr_screen(1.0, 1.0, 6600); dm_hdr_screen(1.0, 1.0, 7100);   // leave SDR for the state sequence below
    EXPECT("reset to SDR", 0, dm_hdr_capable());
    EXPECT("reset clears pending", 0, dm_hdr_pending(NULL));

    // Three distinct Apple values: potential is capability, current is available brightness, reference is
    // only for calibrated reference rendering (0 when unsupported). Consumer presentation uses current.
    const double refs[] = {0, 50, 200, 16, NAN, INFINITY};
    for (unsigned i = 0; i < sizeof refs / sizeof *refs; i++) {
        char name[96]; snprintf(name, sizeof name, "reference %.0f is not a general ceiling", refs[i]);
        NEAR(name, 1.1, hdr_output_headroom(1.1, refs[i]), 0);
    }
    NEAR("HDR-capable at current headroom 1.0", 1.0, hdr_output_headroom(1.0, 16.0), 0);
    NEAR("non-finite current is unknown (1x)", 1.0, hdr_output_headroom(NAN, 0), 0);
    NEAR("zero current is unknown (1x)", 1.0, hdr_output_headroom(0, 0), 0);

    // Peak: paper white x current headroom, within [paper white, 1600], stepped to 10 nits.
    EXPECT("100 x 8 = 800", 800, hdr_peak_nits(8, 100));
    EXPECT("100 x 16 capped at 1600", 1600, hdr_peak_nits(16, 100));
    EXPECT("headroom 1: paper white", 100, hdr_peak_nits(1, 100));
    EXPECT("headroom below 1: paper white", 100, hdr_peak_nits(0.5, 100));
    EXPECT("NaN headroom: paper white", 100, hdr_peak_nits(NAN, 100));
    EXPECT("Inf headroom: unknown, paper white", 100, hdr_peak_nits(INFINITY, 100));
    EXPECT("stepping to 10 nits", 810, hdr_peak_nits(8.13, 100));

    // PQ (SMPTE ST 2084) at known values, and its inverse.
    const double pq[][2] = {{0, 0}, {0.508078, 100}, {0.580689, 203}, {0.751827, 1000}, {1.0, 10000}};
    for (unsigned i = 0; i < sizeof pq / sizeof *pq; i++) {
        char name[64]; snprintf(name, sizeof name, "PQ %.6f -> %.0f nits", pq[i][0], pq[i][1]);
        NEAR(name, pq[i][1], hdr_pq_nits(pq[i][0]), fmax(pq[i][1] * 1e-3, 1e-3));
        NEAR("PQ inverse", pq[i][0], hdr_pq_code(pq[i][1]), 1e-4);
    }
    NEAR("PQ code < 0 -> 0 nits", 0, hdr_pq_nits(-0.1), 0);
    NEAR("PQ code > 1 -> 10000 nits", 10000, hdr_pq_nits(1.5), 1e-6);
    NEAR("PQ nits < 0 -> 0", 0, hdr_pq_code(-5), 0);
    NEAR("NaN code -> 0 nits", 0, hdr_pq_nits(NAN), 0);
    // Independent PQ reference: all nine standard luminances, their ideal code and their 10-bit code.
    // Decoding a 10-bit code cannot be more accurate than half a code step; the tolerance is derived from
    // the neighbouring reference codes' nits so it is justified by quantisation, not chosen to make it pass.
    for (unsigned i = 0; i < sizeof REF_PQ / sizeof *REF_PQ; i++) {
        double nits = REF_PQ[i][0], ideal = REF_PQ[i][1], code10 = REF_PQ[i][2];
        char name[96];
        snprintf(name, sizeof name, "ref PQ %.0f nits -> code %.6f", nits, ideal);
        NEAR(name, ideal, hdr_pq_code(nits), 2e-6);
        snprintf(name, sizeof name, "ref 10-bit code %.0f -> about %.0f nits", code10, nits);
        NEAR(name, nits, hdr_pq_nits(code10 / 1023.0), fmax(nits * 0.012, 1.0));
        snprintf(name, sizeof name, "ref round trip %.0f nits", nits);
        NEAR(name, ideal, hdr_pq_code(hdr_pq_nits(ideal)), 2e-5);
    }
    // Near black and monotonicity across the whole 10-bit range.
    EXPECT("PQ code 0 -> exactly 0 nits", 1, hdr_pq_nits(0) == 0);
    EXPECT("PQ code 1 near black is tiny but positive", 1, hdr_pq_nits(1 / 1023.0) > 0 && hdr_pq_nits(1 / 1023.0) < 0.1);
    int monotonic = 1; double prev = -1;
    for (int code = 0; code <= 1023; code++) { double n = hdr_pq_nits(code / 1023.0); if (n < prev) monotonic = 0; prev = n; }
    EXPECT("PQ decode is monotonic over all 1024 codes", 1, monotonic);
    EXPECT("PQ code NaN -> 0", 1, isnan(hdr_pq_nits(NAN)) == 0 && hdr_pq_nits(NAN) == 0);
    // The opt-in MetalFX path decodes PQ to linear nits divided by paper white (fs_pq_decode), scales in
    // that unit, and encodes once in fs_hdr_fx. The round trip must be lossless to 10-bit quantisation.
    double rt_worst = 0;
    for (int code = 1; code <= 1023; code++) {
        double paper_whites = hdr_pq_nits(code / 1023.0) / 100.0;
        double back = hdr_pq_code(paper_whites * 100.0) * 1023.0;
        double err = fabs(back - code);
        if (err > rt_worst) rt_worst = err;
    }
    EXPECT("PQ -> paper-white-normalised linear -> PQ round trip within half a code", 1, rt_worst <= 0.5);
    EXPECT("PQ nits Inf -> 1.0 code", 1, hdr_pq_code(INFINITY) == 1.0);
    // RGB10A2 unpack: R bits 0-9, G 10-19, B 20-29; distinct channels catch a swapped field.
    double c[3];
    hdr_rgb10a2_codes(ref_pack10(1023, 594, 10, 3), c);
    NEAR("RGB10A2 R", 1.0, c[0], 1e-9);
    NEAR("RGB10A2 G", 594 / 1023.0, c[1], 1e-9);
    NEAR("RGB10A2 B", 10 / 1023.0, c[2], 1e-9);
    hdr_rgb10a2_codes(ref_pack10(10, 1023, 594, 0), c);
    NEAR("RGB10A2 channel order R", 10 / 1023.0, c[0], 1e-9);
    NEAR("RGB10A2 channel order G", 1.0, c[1], 1e-9);
    NEAR("RGB10A2 channel order B", 594 / 1023.0, c[2], 1e-9);
    hdr_rgb10a2_codes(ref_pack10(594, 594, 594, 0) | 2u << 30, c);
    NEAR("RGB10A2 alpha does not leak into R", 594 / 1023.0, c[0], 1e-9);

    // Primaries: a grey's rows sum to 1; BT.2020 red is outside BT.709 (negative G and B in linear sRGB).
    double grey[3] = {0.5, 0.5, 0.5}, out[3];
    hdr_bt2020_to_709(grey, out);
    for (int i = 0; i < 3; i++) NEAR("BT.2020 grey -> same grey", 0.5, out[i], 2e-3);
    // Compare the production matrix element by element with the independently derived one, then apply
    // both to a non-grey, out-of-gamut colour so a transposed or scaled matrix cannot pass a grey-only test.
    for (int i = 0; i < 3; i++) for (int j = 0; j < 3; j++)
        NEAR("2020->709 matrix element", REF_2020_TO_709[i][j], HDR_BT2020_TO_709[i][j], 1e-6);
    double red[3] = {1, 0, 0}; hdr_bt2020_to_709(red, out);
    NEAR("BT.2020 red R > 1", REF_2020_TO_709[0][0], out[0], 1e-5);
    EXPECT("BT.2020 red G < 0", 1, out[1] < 0);
    EXPECT("BT.2020 red B < 0", 1, out[2] < 0);
    double mixed[3] = {0.75, 0.9, 0.1}, ref_mixed[3];
    for (int i = 0; i < 3; i++) { double v = 0; for (int j = 0; j < 3; j++) v += REF_2020_TO_709[i][j] * mixed[j]; ref_mixed[i] = v; }
    hdr_bt2020_to_709(mixed, out);
    for (int i = 0; i < 3; i++) NEAR("mixed BT.2020 -> BT.709 against independent matrix", ref_mixed[i], out[i], 1e-9);
    hdr_bt2020_to_709(red, out);
    double back[3]; hdr_bt709_to_2020(out, back);
    NEAR("round trip BT.2020 R", 1, back[0], 1e-3);
    NEAR("round trip BT.2020 G", 0, back[1], 1e-3);
    // SDR gamma decode / encode, and the PQ encoding of SDR white at the paper white.
    NEAR("gamma 2.2 decode 1", 1, hdr_sdr_decode(1, 2.2), 1e-9);
    NEAR("gamma 2.2 decode 0.5", pow(0.5, 2.2), hdr_sdr_decode(0.5, 2.2), 1e-9);
    NEAR("gamma 2.2 round trip", 0.5, hdr_sdr_encode(hdr_sdr_decode(0.5, 2.2), 2.2), 1e-9);
    NEAR("sRGB piecewise: 0.04045 -> 0.00313", 0.0031308, hdr_sdr_decode(0.04045, 0), 1e-5);
    NEAR("SDR white at 100 nits is the independent paper-white PQ code", REF_PQ[3][1], hdr_pq_code(hdr_sdr_decode(1, 2.2) * 100), 1e-6);
    EXPECT("decode NaN -> 0", 1, hdr_sdr_decode(NAN, 2.2) == 0);
    // HDR -> SDR shoulder: unchanged below the knee, continuous, never above 1.
    NEAR("shoulder below knee", 0.5, hdr_sdr_shoulder(0.5), 0);
    NEAR("shoulder continuous at knee", 0.75, hdr_sdr_shoulder(0.75), 1e-9);
    NEAR("shoulder paper white (externally computed rational shoulder)", 0.875318066, hdr_sdr_shoulder(1), 1e-6);
    NEAR("shoulder 2x paper white (externally computed)", 0.959218352, hdr_sdr_shoulder(2), 1e-6);
    EXPECT("shoulder at 50x never exceeds 1", 1, hdr_sdr_shoulder(50) <= 1);
    EXPECT("shoulder of NaN is NaN", 1, isnan(hdr_sdr_shoulder(NAN)));

    // Shared state: SDR at boot, HDR once the PQ layer is ready, SDR again after the game switches back,
    // then HDR when the window returns to an XDR screen. The setting is never changed by a screen event.
    setenv("DM_HDR", "auto", 1);
    dm_hdr_boot();
    EXPECT("setting read", HDR_PREF_AUTO, dm_hdr_pref());
    EXPECT("paper white 100", 100, dm_hdr_paper_white());
    EXPECT("no screen: off", 0, dm_hdr_on());
    uint16_t peak = 99;
    EXPECT("no screen: vi SDR", 0, dm_hdr_answer(&peak)); EXPECT("SDR peak 0", 0, peak);
    EXPECT("not told", 0, dm_hdr_told());
    dm_hdr_screen(16, 8, 1000);
    EXPECT("capability pending: still off", 0, dm_hdr_on());
    dm_hdr_screen(16, 8, 1500);   // the one-shot settle timer re-reads the unchanged screen
    EXPECT("layer wanted after hold", 1, dm_hdr_layer_tick(0, 1600));
    EXPECT("layer ready: vi HDR", 1, dm_hdr_layer_tick(1, 1600));
    EXPECT("on", 1, dm_hdr_on());
    EXPECT("vi answers HDR, 100 x 8 = 800", 1, dm_hdr_answer(&peak)); EXPECT("peak 800", 800, peak);
    EXPECT("game told", 1, dm_hdr_told());
    dm_hdr_present(1); dm_hdr_layer_tick(1, 1700);
    EXPECT("state HDR_ACTIVE", HDR_ST_HDR_ACTIVE, dm_hdr_state());
    // A screen change has to hold 500 ms; the PQ layer is then kept until two SDR presents.
    dm_hdr_screen(1, 1, 2000);
    EXPECT("capability change held back", 1, dm_hdr_on());
    dm_hdr_screen(1, 1, 2600);
    EXPECT("PQ layer kept for the game's SDR window", 1, dm_hdr_layer_tick(1, 2600));
    EXPECT("SDR screen: off", 0, dm_hdr_on());
    dm_hdr_present(0); dm_hdr_present(0);
    EXPECT("PQ layer given up after two SDR presents", 0, dm_hdr_layer_tick(1, 2700));
    EXPECT("vi SDR again", 0, dm_hdr_answer(&peak)); EXPECT("peak 0", 0, peak);
    EXPECT("setting unchanged", HDR_PREF_AUTO, dm_hdr_pref());
    // The SDR answer above must not clear the memory of what the game's RGB10A2 window holds: an HDR frame
    // may already be in flight, and present_pq() has to keep decoding those textures as PQ until the game
    // has rebuilt its window. Clearing here would reinterpret an in-flight HDR frame as gamma-coded SDR.
    EXPECT("an SDR answer keeps the source-encoding memory (in-flight HDR frames)", 1, dm_hdr_told());
    dm_hdr_screen(16, 8, 3000); dm_hdr_screen(16, 8, 3600);
    EXPECT("HDR again", 1, dm_hdr_layer_tick(1, 3600));
    EXPECT("vi HDR again", 1, dm_hdr_answer(&peak));
    EXPECT("setting still auto", HDR_PREF_AUTO, dm_hdr_pref());
    // State sequences: SDR_READY at boot, SDR_REQUESTED while the game rebuilds, HDR_ACTIVE after the answer.
    EXPECT("state after HDR answer", HDR_ST_HDR_ACTIVE, dm_hdr_state());
    dm_hdr_present(1);   // the last frame was the game's HDR window
    dm_hdr_screen(1, 1, 4000); dm_hdr_screen(1, 1, 4600);
    EXPECT("layer kept while the game rebuilds", 1, dm_hdr_layer_tick(1, 4600));
    EXPECT("state SDR_REQUESTED while the layer is still PQ", HDR_ST_SDR_REQUESTED, dm_hdr_state());
    dm_hdr_layer_tick(0, 4700);
    EXPECT("state SDR_READY", HDR_ST_SDR_READY, dm_hdr_state());
    // Headroom and the controlled roll-off: a current headroom below 1 reads as unknown (1x), and a game
    // that declares a peak above what the screen shows gets only its highlights compressed.
    dm_hdr_headroom_set(0.5); NEAR("headroom below 1 is kept (a dim screen)", 0.5, dm_hdr_headroom(), 1e-6);
    dm_hdr_headroom_set(16.0);
    dm_hdr_meta_set(HDR_META_EXT, 0, 2000);
    float knee = 0, target = 0, source = 0;
    dm_hdr_headroom_set(2.0);
    EXPECT("roll-off on a dim screen", 1, dm_hdr_rolloff(&knee, &target, &source));
    EXPECT("roll-off knee never below paper white", 1, knee >= 100 && knee <= target);
    EXPECT("roll-off target follows current headroom", 200, (int)target);
    dm_hdr_headroom_set(16.0);
    dm_hdr_meta_set(HDR_META_EXT, 0, 800);
    EXPECT("no roll-off once the game declares a peak within the screen", 0, dm_hdr_rolloff(&knee, &target, &source));
    dm_hdr_meta_set(HDR_META_EXT, 0, 0);
    // Low current headroom: the knee must be below the target, not arbitrarily far from it. With a fixed
    // peak above a 1.1x display the old "knee > 0.9 * target" guard gave no roll-off at all, so the game's
    // highlights clipped instead; paper white must still land exactly on itself.
    dm_hdr_screen(16.0, 8.0, 4800); dm_hdr_screen(16.0, 8.0, 5300);
    dm_hdr_layer_tick(1, 5400);
    setenv("DM_HDR_PEAK", "200", 1);
    uint16_t fixed = 0;
    EXPECT("fixed peak is answered to the game", 1, dm_hdr_answer(&fixed));
    EXPECT("fixed peak value", 200, fixed);
    dm_hdr_headroom_set(1.1f); dm_hdr_meta_set(HDR_META_EXT, 0, 2000);
    EXPECT("roll-off at 1.1x current headroom", 1, dm_hdr_rolloff(&knee, &target, &source));
    NEAR("low-headroom knee is paper white", 100, knee, 1e-4);
    NEAR("low-headroom target follows current headroom", 110, target, 1e-4);
    NEAR("low-headroom paper white is untouched", 100, hdr_shoulder(100, knee, target, source), 1e-4);
    NEAR("low-headroom highlight lands on target", 110, hdr_shoulder(200, knee, target, source), 1e-3);
    NEAR("low-headroom mid-highlight is between paper and target", 1, hdr_shoulder(150, knee, target, source) > 100 && hdr_shoulder(150, knee, target, source) < 110, 0);
    dm_hdr_headroom_set(1.0f);
    EXPECT("no roll-off when there is no range above paper white", 0, dm_hdr_rolloff(&knee, &target, &source));
    unsetenv("DM_HDR_PEAK");
    dm_hdr_meta_set(HDR_META_EXT, 0, 0);
    // HDR -> SDR exit: after the capability settles and the game answers SDR, the PQ layer is deliberately
    // kept for two SDR presents. The SECOND one must request exactly one main-thread reevaluation, with no
    // further display notification and no task per presented frame. A paused game (no presents) requests none.
    dm_hdr_screen(16.0, 8.0, 8000); dm_hdr_screen(16.0, 8.0, 8500);
    dm_hdr_layer_tick(1, 8600); dm_hdr_present(1);
    EXPECT("HDR again for the exit test", 1, dm_hdr_on());
    atomic_store(&settle_calls, 0);
    dm_hdr_screen(1.0, 1.0, 9000); dm_hdr_screen(1.0, 1.0, 9500);
    EXPECT("PQ layer kept after capability settled", 1, dm_hdr_layer_tick(1, 9600));
    EXPECT("state is SDR_REQUESTED", HDR_ST_SDR_REQUESTED, dm_hdr_state());
    EXPECT("no settle request while paused", 0, atomic_load(&settle_calls));
    dm_hdr_present(0);
    EXPECT("no request after the first SDR present", 0, atomic_load(&settle_calls));
    dm_hdr_present(0);
    EXPECT("one request after the second SDR present", 1, atomic_load(&settle_calls));
    dm_hdr_present(0); dm_hdr_present(0);
    EXPECT("no request for later SDR presents", 1, atomic_load(&settle_calls));
    dm_hdr_layer_tick(0, 9700);   // the front end's one reevaluation applies the SDR layer
    EXPECT("state is SDR_READY after the reevaluation", HDR_ST_SDR_READY, dm_hdr_state());
    atomic_store(&settle_calls, 0);
    dm_hdr_screen(16.0, 8.0, 10000); dm_hdr_screen(16.0, 8.0, 10500);
    dm_hdr_layer_tick(1, 10600); dm_hdr_present(1); dm_hdr_layer_tick(1, 10700);
    EXPECT("HDR re-entry clears the old exit request", 0, atomic_load(&settle_calls));
    dm_hdr_screen(1.0, 1.0, 11000); dm_hdr_screen(1.0, 1.0, 11500);
    EXPECT("second exit is SDR_REQUESTED", HDR_ST_SDR_REQUESTED, dm_hdr_layer_tick(1, 11600) ? dm_hdr_state() : HDR_ST_SDR_READY);
    dm_hdr_present(0); dm_hdr_present(0);
    EXPECT("a second transition requests again", 1, atomic_load(&settle_calls));
    dm_hdr_layer_tick(0, 11700);
    // Concurrent writers: vi, the front end and the present thread share the state and the log switch.
    pthread_t th[4];
    for (intptr_t i = 0; i < 4; i++) pthread_create(&th[i], NULL, hdr_worker, (void *)i);
    for (int i = 0; i < 4; i++) pthread_join(th[i], NULL);
    EXPECT("concurrent HDR state access keeps its invariants", 0, atomic_load(&thread_bad));
    printf("== %d checks, %d failed ==\n", cases, failed);
    return failed != 0;
}
