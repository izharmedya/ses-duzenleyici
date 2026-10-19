#ifndef RTAtomicBridge_h
#define RTAtomicBridge_h

#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <CoreAudio/CoreAudioTypes.h>

_Static_assert(__atomic_always_lock_free(sizeof(uint32_t), 0),
               "The real-time bridge requires lock-free 32-bit atomics");

#ifdef __cplusplus
extern "C" {
#endif

typedef struct RTTapSharedState {
    // Atomik kontrol alanları (Main thread yazar, IOProc okur)
    uint32_t targetGainBits;
    uint32_t isMuted;
    uint32_t isActive;

    // Başlatma öncesi doğrulanmış sabit stream yönlendirme (routing) indisleri
    int32_t tapInBufferLeft;
    int32_t tapInChannelLeft;
    int32_t tapInBufferRight;
    int32_t tapInChannelRight;

    int32_t outBufferLeft;
    int32_t outChannelLeft;
    int32_t outBufferRight;
    int32_t outChannelRight;
    uint32_t isOutputStereo;

    // Yalnızca IOProc tarafından kullanılan anlık rampa kazancı
    float currentGain;

    // Atomik telemetri alanları (IOProc yazar, Main thread okur)
    uint32_t totalCallbackCount;
    uint32_t silentCallbackCount;
    uint32_t nonSilentCallbackCount;
    uint32_t lastPeakBits;
} RTTapSharedState;

static inline uint32_t rt_float_to_bits(float v) {
    uint32_t bits = 0;
    memcpy(&bits, &v, sizeof(uint32_t));
    return bits;
}

static inline float rt_bits_to_float(uint32_t bits) {
    float v = 0.0f;
    memcpy(&v, &bits, sizeof(float));
    return v;
}

static inline RTTapSharedState * _Nullable rt_tap_state_create(float initialGain, bool initialMuted) {
    RTTapSharedState *state = (RTTapSharedState *)calloc(1, sizeof(RTTapSharedState));
    if (state == NULL) {
        return NULL;
    }
    uint32_t gainBits = rt_float_to_bits(initialGain);
    __atomic_store_n(&state->targetGainBits, gainBits, __ATOMIC_RELAXED);
    __atomic_store_n(&state->isMuted, initialMuted ? 1u : 0u, __ATOMIC_RELAXED);
    __atomic_store_n(&state->isActive, 0u, __ATOMIC_RELAXED);

    state->tapInBufferLeft = -1;
    state->tapInChannelLeft = 0;
    state->tapInBufferRight = -1;
    state->tapInChannelRight = 0;

    state->outBufferLeft = -1;
    state->outChannelLeft = 0;
    state->outBufferRight = -1;
    state->outChannelRight = 0;
    state->isOutputStereo = 0u;

    state->currentGain = initialMuted ? 0.0f : initialGain;

    __atomic_store_n(&state->totalCallbackCount, 0u, __ATOMIC_RELAXED);
    __atomic_store_n(&state->silentCallbackCount, 0u, __ATOMIC_RELAXED);
    __atomic_store_n(&state->nonSilentCallbackCount, 0u, __ATOMIC_RELAXED);
    __atomic_store_n(&state->lastPeakBits, 0u, __ATOMIC_RELAXED);
    return state;
}

static inline void rt_tap_state_destroy(RTTapSharedState * _Nullable state) {
    if (state != NULL) {
        free(state);
    }
}

static inline void rt_tap_state_configure_routing(
    RTTapSharedState * _Nonnull state,
    int32_t tapInBufferLeft,
    int32_t tapInChannelLeft,
    int32_t tapInBufferRight,
    int32_t tapInChannelRight,
    int32_t outBufferLeft,
    int32_t outChannelLeft,
    int32_t outBufferRight,
    int32_t outChannelRight,
    bool isOutputStereo
) {
    state->tapInBufferLeft = tapInBufferLeft;
    state->tapInChannelLeft = tapInChannelLeft;
    state->tapInBufferRight = tapInBufferRight;
    state->tapInChannelRight = tapInChannelRight;
    state->outBufferLeft = outBufferLeft;
    state->outChannelLeft = outChannelLeft;
    state->outBufferRight = outBufferRight;
    state->outChannelRight = outChannelRight;
    state->isOutputStereo = isOutputStereo ? 1u : 0u;
    __atomic_thread_fence(__ATOMIC_RELEASE);
}

static inline void rt_tap_state_set_gain(RTTapSharedState * _Nonnull state, float gain) {
    float clamped = fmaxf(0.0f, fminf(1.5f, gain));
    __atomic_store_n(&state->targetGainBits, rt_float_to_bits(clamped), __ATOMIC_RELEASE);
}

static inline float rt_tap_state_get_gain(const RTTapSharedState * _Nonnull state) {
    uint32_t bits = __atomic_load_n(&state->targetGainBits, __ATOMIC_ACQUIRE);
    return rt_bits_to_float(bits);
}

static inline void rt_tap_state_set_muted(RTTapSharedState * _Nonnull state, bool muted) {
    __atomic_store_n(&state->isMuted, muted ? 1u : 0u, __ATOMIC_RELEASE);
}

static inline bool rt_tap_state_get_muted(const RTTapSharedState * _Nonnull state) {
    return __atomic_load_n(&state->isMuted, __ATOMIC_ACQUIRE) != 0u;
}

static inline void rt_tap_state_set_active(RTTapSharedState * _Nonnull state, bool active) {
    __atomic_store_n(&state->isActive, active ? 1u : 0u, __ATOMIC_RELEASE);
}

static inline bool rt_tap_state_get_active(const RTTapSharedState * _Nonnull state) {
    return __atomic_load_n(&state->isActive, __ATOMIC_ACQUIRE) != 0u;
}

static inline uint32_t rt_tap_state_get_total_callbacks(const RTTapSharedState * _Nonnull state) {
    return __atomic_load_n(&state->totalCallbackCount, __ATOMIC_ACQUIRE);
}

static inline uint32_t rt_tap_state_get_silent_callbacks(const RTTapSharedState * _Nonnull state) {
    return __atomic_load_n(&state->silentCallbackCount, __ATOMIC_ACQUIRE);
}

static inline uint32_t rt_tap_state_get_nonsilent_callbacks(const RTTapSharedState * _Nonnull state) {
    return __atomic_load_n(&state->nonSilentCallbackCount, __ATOMIC_ACQUIRE);
}

static inline float rt_tap_state_get_last_peak(const RTTapSharedState * _Nonnull state) {
    uint32_t bits = __atomic_load_n(&state->lastPeakBits, __ATOMIC_ACQUIRE);
    return rt_bits_to_float(bits);
}

/// Finite sample değerlerini donanım çıkışının [-1, 1] aralığında tutar.
/// Bu basit sınırlandırma sıçramasızdır ama türevi süreksizdir; gerçek zamanlı yolda tanh/alloc kullanmaz.
static inline float rt_soft_limit_sample(float sample, float appliedGain) {
    (void)appliedGain;
    if (!isfinite(sample)) {
        return 0.0f;
    }
    if (sample > 1.0f) {
        return 1.0f;
    }
    if (sample < -1.0f) {
        return -1.0f;
    }
    return sample;
}

/// Gerçek zamanlı IOProc callback içinde çağrılan saf C ses işleme fonksiyonu.
/// Bellek ayırma, kilit, loglama veya Swift runtime çağrısı içermez.
static inline void rt_process_tap_buffers(
    RTTapSharedState * _Nonnull state,
    const AudioBufferList * _Nullable inInputData,
    AudioBufferList * _Nullable outOutputData
) {
    if (outOutputData == NULL) {
        return;
    }

    // Fiziksel mikrofon kanallarının veya eski verilerin çıkışa sızmasını önlemek için tüm çıkış tamponlarını sıfırla
    for (UInt32 i = 0; i < outOutputData->mNumberBuffers; ++i) {
        if (outOutputData->mBuffers[i].mData != NULL && outOutputData->mBuffers[i].mDataByteSize > 0) {
            memset(outOutputData->mBuffers[i].mData, 0, outOutputData->mBuffers[i].mDataByteSize);
        }
    }

    if (state == NULL || !rt_tap_state_get_active(state)) {
        return;
    }

    // Count every active I/O callback, including a malformed or empty buffer layout, so the
    // control plane can report a silent/unusable tap instead of leaving the source muted.
    __atomic_fetch_add(&state->totalCallbackCount, 1u, __ATOMIC_RELAXED);
    if (inInputData == NULL) {
        return;
    }

    int32_t inBufIdxL = state->tapInBufferLeft;
    int32_t inChanL = state->tapInChannelLeft;
    int32_t inBufIdxR = state->tapInBufferRight;
    int32_t inChanR = state->tapInChannelRight;

    int32_t outBufIdxL = state->outBufferLeft;
    int32_t outChanL = state->outChannelLeft;
    int32_t outBufIdxR = state->outBufferRight;
    int32_t outChanR = state->outChannelRight;

    if (inBufIdxL < 0 || (UInt32)inBufIdxL >= inInputData->mNumberBuffers ||
        inBufIdxR < 0 || (UInt32)inBufIdxR >= inInputData->mNumberBuffers ||
        outBufIdxL < 0 || (UInt32)outBufIdxL >= outOutputData->mNumberBuffers) {
        return;
    }

    const AudioBuffer *inBufL = &inInputData->mBuffers[inBufIdxL];
    const AudioBuffer *inBufR = &inInputData->mBuffers[inBufIdxR];
    AudioBuffer *outBufL = &outOutputData->mBuffers[outBufIdxL];

    if (inBufL->mData == NULL || inBufR->mData == NULL || outBufL->mData == NULL) {
        return;
    }

    int32_t inStrideL = (int32_t)inBufL->mNumberChannels;
    int32_t inStrideR = (int32_t)inBufR->mNumberChannels;
    int32_t outStrideL = (int32_t)outBufL->mNumberChannels;

    if (inStrideL <= inChanL || inStrideR <= inChanR || outStrideL <= outChanL ||
        inStrideL <= 0 || inStrideR <= 0 || outStrideL <= 0) {
        return;
    }

    int32_t inFramesL = (int32_t)(inBufL->mDataByteSize / (sizeof(float) * (size_t)inStrideL));
    int32_t inFramesR = (int32_t)(inBufR->mDataByteSize / (sizeof(float) * (size_t)inStrideR));
    int32_t outFramesL = (int32_t)(outBufL->mDataByteSize / (sizeof(float) * (size_t)outStrideL));

    int32_t frames = inFramesL < inFramesR ? inFramesL : inFramesR;
    if (outFramesL < frames) {
        frames = outFramesL;
    }

    const float *srcL = (const float *)inBufL->mData;
    const float *srcR = (const float *)inBufR->mData;
    float *dstL = (float *)outBufL->mData;

    float *dstR = NULL;
    int32_t outStrideR = 0;

    if (state->isOutputStereo != 0u &&
        outBufIdxR >= 0 &&
        (UInt32)outBufIdxR < outOutputData->mNumberBuffers) {
        AudioBuffer *outBufR = &outOutputData->mBuffers[outBufIdxR];
        if (outBufR->mData != NULL && (int32_t)outBufR->mNumberChannels > outChanR && outBufR->mNumberChannels > 0) {
            outStrideR = (int32_t)outBufR->mNumberChannels;
            int32_t outFramesR = (int32_t)(outBufR->mDataByteSize / (sizeof(float) * (size_t)outStrideR));
            if (outFramesR < frames) {
                frames = outFramesR;
            }
            dstR = (float *)outBufR->mData;
        }
    }

    if (frames <= 0) {
        return;
    }

    bool muted = __atomic_load_n(&state->isMuted, __ATOMIC_ACQUIRE) != 0u;
    float targetGain = muted ? 0.0f : rt_bits_to_float(__atomic_load_n(&state->targetGainBits, __ATOMIC_ACQUIRE));
    float currentGain = state->currentGain;
    float maxPeak = 0.0f;

    if (dstR != NULL) {
        for (int32_t f = 0; f < frames; ++f) {
            currentGain += (targetGain - currentGain) * 0.008f;
            float rawL = srcL[f * inStrideL + inChanL];
            float rawR = srcR[f * inStrideR + inChanR];

            float absL = fabsf(rawL);
            float absR = fabsf(rawR);
            float peak = absL > absR ? absL : absR;
            if (peak > maxPeak) {
                maxPeak = peak;
            }

            dstL[f * outStrideL + outChanL] = rt_soft_limit_sample(rawL * currentGain, currentGain);
            dstR[f * outStrideR + outChanR] = rt_soft_limit_sample(rawR * currentGain, currentGain);
        }
    } else {
        for (int32_t f = 0; f < frames; ++f) {
            currentGain += (targetGain - currentGain) * 0.008f;
            float rawL = srcL[f * inStrideL + inChanL];
            float rawR = srcR[f * inStrideR + inChanR];
            float mono = (rawL + rawR) * 0.5f;

            float peak = fabsf(mono);
            if (peak > maxPeak) {
                maxPeak = peak;
            }

            dstL[f * outStrideL + outChanL] = rt_soft_limit_sample(mono * currentGain, currentGain);
        }
    }

    if (fabsf(targetGain - currentGain) < 0.0001f) {
        currentGain = targetGain;
    }
    state->currentGain = currentGain;

    __atomic_store_n(&state->lastPeakBits, rt_float_to_bits(maxPeak), __ATOMIC_RELAXED);

    if (maxPeak < 0.000001f) {
        uint32_t prevSilent = __atomic_load_n(&state->silentCallbackCount, __ATOMIC_RELAXED);
        if (prevSilent < 100000u) {
            __atomic_store_n(&state->silentCallbackCount, prevSilent + 1u, __ATOMIC_RELEASE);
        }
    } else {
        __atomic_store_n(&state->silentCallbackCount, 0u, __ATOMIC_RELEASE);
        __atomic_fetch_add(&state->nonSilentCallbackCount, 1u, __ATOMIC_RELEASE);
    }
}

#ifdef __cplusplus
}
#endif

#endif /* RTAtomicBridge_h */
