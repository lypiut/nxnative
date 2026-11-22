// Shared HDR state. The front end writes the screen's readings and the layer state on its main thread, vi
// reads them on the game's threads every frame, the present thread reports the picture's encoding; all of it
// is atomic so no transition needs a lock on the presentation thread.
#include "../../host/dm.h"
#include "hdr.h"
#include <pthread.h>
#include <stdatomic.h>
#include <time.h>

#ifndef DM_GAME_HDR
#define DM_GAME_HDR 0
#endif

static int64_t hdr_now_ms(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts)) return 0;
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static _Atomic int g_boot;                 // modules loaded: a profile with hdr on can make the HDR layer
static _Atomic int g_asked;                // a game asked vi for its HDR status
static _Atomic int g_pref = -1, g_pw = -1; // read once
static _Atomic int g_capable = -1, g_cap_pending = -1;   // -1: no screen reading yet
static _Atomic int64_t g_cap_since;
static _Atomic uint32_t g_potential, g_headroom;   // f32 bits
static _Atomic int g_want, g_layer_ready, g_told, g_sdr_requested;
static _Atomic int g_sdr_run = 1000;
static _Atomic uint32_t g_declared_hi, g_told_peak;
static _Atomic int g_state = HDR_ST_SDR_READY;
static _Atomic int g_logged_state = -1;

static void f32_store(_Atomic uint32_t *a, float f) { uint32_t b; memcpy(&b, &f, 4); atomic_store(a, b); }
static float f32_load(_Atomic uint32_t *a) { uint32_t b = atomic_load(a); float f; memcpy(&f, &b, 4); return f; }
// Any thread may log (vi, the present thread and the front end), so the switch must not be lazily
// initialised through a plain static: two first calls raced. Publish it atomically instead.
static _Atomic int g_hdr_log = -1;
__attribute__((weak)) void dm_hdr_settle_request(void) {}   // front_mac.m supplies the main-thread reevaluation
static int hdr_log_on(void) {
    int v = atomic_load(&g_hdr_log);
    if (v < 0) {
        const char *e = getenv("DM_HDR_LOG");
        int want = e && *e && strcmp(e, "0");
        if (atomic_compare_exchange_strong(&g_hdr_log, &v, want)) v = want;
        else v = atomic_load(&g_hdr_log);
    }
    return v;
}
#define HDR_LOG(...) do { if (hdr_log_on()) LOG("[hdr] " __VA_ARGS__); } while (0)

void dm_hdr_boot(void) {
    if (!atomic_exchange(&g_boot, 1) && hdr_log_on())
        LOG("[hdr] game profile supports native HDR (DM_GAME_HDR=%d), DM_HDR=%s", DM_GAME_HDR, dm_hdr_pref() ? "auto" : "0");
}

int dm_hdr_pref(void) {
    int p = atomic_load(&g_pref);
    if (p >= 0) return p;
    int bad = 0, dflt = DM_GAME_HDR ? HDR_PREF_AUTO : HDR_PREF_OFF;
    p = hdr_pref_parse(getenv("DM_HDR"), dflt, &bad);
    int was = -1;
    if (atomic_compare_exchange_strong(&g_pref, &was, p)) {
        const char *e = getenv("DM_HDR");
        if (bad) LOG("[RED] [hdr] DM_HDR=%s: auto or 0; keeping %s", e, p ? "auto" : "0");
        HDR_LOG("DM_HDR=%s%s: %s", e && *e ? e : "unset", e && *e ? "" : " (game profile default)",
                p ? "HDR on a screen that can show it" : "never HDR");
    }
    return atomic_load(&g_pref);
}

int dm_hdr_paper_white(void) {
    int v = atomic_load(&g_pw);
    if (v > 0) return v;
    const char *e = getenv("DM_HDR_PAPER_WHITE");
    v = hdr_paper_white_parse(e);
    if (v < 0) { LOG("[RED] [hdr] DM_HDR_PAPER_WHITE=%s: nits from %d to %d; keeping %d", e, HDR_PAPER_WHITE_MIN, HDR_PAPER_WHITE_MAX, HDR_PAPER_WHITE_DEFAULT); v = HDR_PAPER_WHITE_DEFAULT; }
    atomic_store(&g_pw, v);
    HDR_LOG("paper white %d nits (PQ code %.4f): mapped to the screen's SDR white", v, hdr_pq_code(v));
    return v;
}

void dm_hdr_headroom_set(double current) {
    f32_store(&g_headroom, isfinite(current) && current > 0 ? (float)current : 1.0f);
}
float dm_hdr_headroom(void) {
    float h = f32_load(&g_headroom);
    return h > 0 ? h : 1.0f;
}

void dm_hdr_screen(double potential, double current, int64_t now_ms) {
    if (!now_ms) now_ms = hdr_now_ms();
    f32_store(&g_potential, (float)(isfinite(potential) && potential > 0 ? potential : 0));
    dm_hdr_headroom_set(current);
    int now = hdr_capable(potential), held = atomic_load(&g_capable);
    // A window dragged across the edge between two screens must not flip the layer on every event: a
    // capability change has to hold for half a second (the first reading is taken as it is).
    int pending = atomic_load(&g_cap_pending);
    if (held < 0) { atomic_store(&g_capable, now); atomic_store(&g_cap_pending, -1); }
    else if (now == held) atomic_store(&g_cap_pending, -1);
    else if (pending != now) { atomic_store(&g_cap_pending, now); atomic_store(&g_cap_since, now_ms); }
    else if (now_ms - atomic_load(&g_cap_since) >= HDR_SETTLE_MS) {
        atomic_store(&g_capable, now); atomic_store(&g_cap_pending, -1);
        HDR_LOG("potential EDR headroom %.2f: HDR %s", potential, now ? "available" : "unavailable");
    }
}
int dm_hdr_capable(void) { return atomic_load(&g_capable) > 0; }
// A pending change is settled by a bounded one-shot timer in the front end, not by a poll that only runs
// while HDR is already on: SDR -> HDR would otherwise never complete after a single screen notification.
int dm_hdr_pending(int64_t *due_ms) {
    int p = atomic_load(&g_cap_pending);
    if (p < 0) return 0;
    if (due_ms) *due_ms = atomic_load(&g_cap_since) + HDR_SETTLE_MS;
    return 1;
}

int dm_hdr_layer_tick(int layer_pq, int64_t now_ms) {
    if (!now_ms) now_ms = hdr_now_ms();
    int capable = atomic_load(&g_capable);
    int want = dm_hdr_pref() == HDR_PREF_AUTO && capable && (atomic_load(&g_boot) || atomic_load(&g_asked));
    atomic_store(&g_want, want);
    int ready = want && layer_pq;
    atomic_store(&g_layer_ready, ready);
    int sdr_run = atomic_load(&g_sdr_run);
    // Keep the PQ layer until the game has put two non-PQ windows on screen: its status answer may have
    // changed before it rebuilt its window, and an HDR window must never reach an SDR drawable.
    int keep = layer_pq && sdr_run < 2;
    int layer = want || keep;
    int state = !want ? (keep ? HDR_ST_SDR_REQUESTED : HDR_ST_SDR_READY) :
                !layer_pq ? HDR_ST_HDR_REQUESTED : !ready ? HDR_ST_HDR_LAYER_READY :
                atomic_load(&g_told) ? HDR_ST_HDR_ACTIVE : HDR_ST_HDR_LAYER_READY;
    atomic_store(&g_state, state);
    // The layer is still PQ after HDR ended: remember that the two-picture exit condition is outstanding so
    // dm_hdr_present() can ask the front end for ONE reevaluation once it is satisfied.
    atomic_store(&g_sdr_requested, state == HDR_ST_SDR_REQUESTED);
    int logged = atomic_exchange(&g_logged_state, state);
    if (logged != state && hdr_log_on()) {
        static const char *names[] = {"SDR_READY", "HDR_REQUESTED", "HDR_LAYER_READY", "HDR_ACTIVE", "SDR_REQUESTED"};
        LOG("[hdr] state %s: DM_HDR=%s, capable=%d, boot=%d, asked=%d, potential %.2f, current headroom %.2f, layer %s, told %s",
            names[state], dm_hdr_pref() ? "auto" : "0", capable, atomic_load(&g_boot), atomic_load(&g_asked),
            f32_load(&g_potential), dm_hdr_headroom(), layer_pq ? "PQ" : "SDR", atomic_load(&g_told) ? "HDR" : "SDR");
    }
    (void)now_ms;
    return layer;
}
int dm_hdr_state(void) { return atomic_load(&g_state); }
int dm_hdr_on(void) { return atomic_load(&g_want); }
int dm_hdr_ready(void) { return atomic_load(&g_layer_ready); }
void dm_hdr_present(int pq) {
    if (pq) { atomic_store(&g_sdr_run, 0); atomic_store(&g_sdr_requested, 0); }
    else if (atomic_load(&g_sdr_run) < 1000) {
        int n = atomic_fetch_add(&g_sdr_run, 1) + 1;
        // No repeating poll exists once HDR is off. The present that satisfies the two-SDR-picture rule
        // requests a single main-thread tick, so the layer is restored without another display event.
        if (n >= 2 && atomic_exchange(&g_sdr_requested, 0)) dm_hdr_settle_request();
    }
}

// The automatic peak follows the current headroom, in steps with a hold, so a changing brightness slider
// moves the game's tone map only once the display has settled. A fixed DM_HDR_PEAK overrides it.
static pthread_mutex_t g_peak_mu = PTHREAD_MUTEX_INITIALIZER;
static uint16_t g_peak, g_peak_candidate;
static int64_t g_peak_since;
static uint16_t hdr_auto_peak(double headroom, int64_t now_ms) {
    uint16_t cand = hdr_peak_nits(headroom, dm_hdr_paper_white());
    pthread_mutex_lock(&g_peak_mu);
    if (!g_peak) g_peak = cand;
    else if (cand == g_peak) { g_peak_candidate = 0; g_peak_since = 0; }
    else if (cand != g_peak_candidate) { g_peak_candidate = cand; g_peak_since = now_ms; }
    else if (now_ms - g_peak_since >= HDR_PEAK_HOLD_MS) { g_peak = cand; g_peak_candidate = 0; g_peak_since = 0; }
    uint16_t r = g_peak;
    pthread_mutex_unlock(&g_peak_mu);
    return r;
}
static uint16_t hdr_fixed_peak(int *set) {
    const char *e = getenv("DM_HDR_PEAK"); char *end = NULL;
    *set = 0;
    if (!e || !*e || !strcmp(e, "auto")) return 0;
    unsigned long v = strtoul(e, &end, 10);
    if (*end || v == 0) return 0;
    *set = 1;
    return (uint16_t)(v > 65535 ? 65535 : v);
}
int dm_hdr_answer(uint16_t *peak) {
    int on = dm_hdr_ready();
    uint16_t pk = 0;
    if (on) {
        atomic_store(&g_asked, 1);
        int fixed = 0;
        pk = hdr_fixed_peak(&fixed);
        if (!fixed) pk = hdr_auto_peak(dm_hdr_headroom(), hdr_now_ms());
        atomic_store(&g_told_peak, pk);
        atomic_store(&g_told, 1);
        static _Atomic uint16_t logged;
        if (pk != atomic_load(&logged) && atomic_exchange(&logged, pk) != pk)
            HDR_LOG("vi answers HDR, output format 1, peak %u nits, paper white %d nits", pk, dm_hdr_paper_white());
    }
    if (peak) *peak = pk;
    return on;
}
int dm_hdr_told(void) { return atomic_load(&g_told); }

float dm_hdr_source_peak(void) {
    uint32_t d = atomic_load(&g_declared_hi), told = atomic_load(&g_told_peak);
    if (told && (!d || told < d)) d = told;
    return (float)d;
}
// Without CAEDRMetadata (the default: PR #1176 saw fullscreen rectangles of stale frames with it), a game
// that declares more than the screen can show right now gets a controlled roll-off above a knee that never
// touches its reference white.
int dm_hdr_rolloff(float *knee, float *target, float *source) {
    float h = dm_hdr_headroom(), d = dm_hdr_source_peak();
    if (!(isfinite(h) && h > 0) || !(d > 0)) return 0;
    float pw = (float)dm_hdr_paper_white(), t = pw * h, k = fmaxf(pw, 0.75f * t);
    // The knee is at or above paper white, so it never moves the game's reference white. It only has to be
    // BELOW the target for the shoulder to have a range; the old "knee > 0.9 * target" guard suppressed the
    // roll-off entirely on a display whose current headroom was close to 1x, even with a fixed peak above
    // it, contradicting the DM_HDR_PEAK contract. Keep the layer untouched when there is no room at all.
    if (d <= 1.05f * t || !(k < t)) return 0;
    *knee = k; *target = t; *source = d;
    return 1;
}

static _Atomic int g_meta[7];   // std lo/hi, ext lo/hi, gamut, tone, any-seen
void dm_hdr_meta_set(int which, int a, int b) {
    switch (which) {
    case HDR_META_STD: atomic_store(&g_meta[0], a); atomic_store(&g_meta[1], b); break;
    case HDR_META_EXT: atomic_store(&g_meta[2], a); atomic_store(&g_meta[3], b); atomic_store(&g_declared_hi, (uint32_t)(b > 0 ? b : 0)); break;
    case HDR_META_GAMUT: atomic_store(&g_meta[4], a); break;
    case HDR_META_TONE: atomic_store(&g_meta[5], a); break;
    default: return;
    }
    atomic_store(&g_meta[6], 1);
}
void dm_hdr_meta_get(dm_hdr_meta *m) {
    int v[7]; for (int i = 0; i < 7; i++) v[i] = atomic_load(&g_meta[i]);
    *m = (dm_hdr_meta){v[0], v[1], v[2], v[3], v[4], v[5], v[6]};
}
