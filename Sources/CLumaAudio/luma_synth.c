#include "include/CLumaAudio.h"

#include "luma_synth.h"

#include <math.h>
#include <stdatomic.h>
#include <string.h>

#define VOICE_COUNT 16
#define COMMAND_CAPACITY 256
#define PATTERN_CAPACITY 256
#define SAMPLE_RATE 48000
#define TWO_PI 6.283185307179586f

typedef enum {
    COMMAND_NOTE_ON,
    COMMAND_NOTE_OFF,
    COMMAND_PATCH,
} CommandKind;

typedef struct {
    int kind;
    int voice;
    float frequency;
    float velocity;
    LumaSynthPatch patch;
} Command;

typedef enum {
    STAGE_IDLE,
    STAGE_ATTACK,
    STAGE_DECAY,
    STAGE_SUSTAIN,
    STAGE_RELEASE,
} EnvelopeStage;

typedef struct {
    int stage;
    float frequency;
    float velocity;
    float phase;
    float detuned_phase;
    float envelope;
    float lowpass;
    float bandpass;
    LumaSynthPatch patch;
} Voice;

// Written only by the control thread, read only by the audio thread.
static _Atomic unsigned int g_command_head;
static _Atomic unsigned int g_command_tail;
static Command g_commands[COMMAND_CAPACITY];
static _Atomic unsigned int g_next_voice;

typedef struct {
    float frequency;
    float velocity;
    int steps;
} PatternStep;

typedef struct {
    PatternStep steps[PATTERN_CAPACITY];
    int count;
    float step_seconds;
    int loops;
} Pattern;

// Two patterns, so the control thread can shape the next one while the audio
// thread performs the current. A commit offers an index the audio thread
// adopts at the cycle boundary, which keeps an edit musical rather than
// jumping mid-bar.
static Pattern g_patterns[2];
static int g_staging;
static _Atomic int g_offered_pattern = -1;

// Touched only by the audio thread once started.
static Voice g_voices[VOICE_COUNT];
static int g_performing = -1;
static int g_step_index;
static int g_frames_until_step;
static unsigned int g_sequenced_voice;
static LumaSynthPatch g_patch;
static float g_level = 0.6f;
static unsigned int g_noise_seed = 22222;

static void push_command(Command command);
static void drain_commands(void);
static void advance_sequencer(void);
static void start_voice(Voice *voice, float frequency, float velocity);
static float render_voice(Voice *voice);

void
luma_audio_set_level(float level)
{
    g_level = level;
}

void
luma_audio_set_patch(const LumaSynthPatch *patch)
{
    Command command = { .kind = COMMAND_PATCH, .patch = *patch };
    push_command(command);
}

int
luma_audio_note_on(float frequency_hz, float velocity)
{
    int voice = (int)(atomic_fetch_add(&g_next_voice, 1) % VOICE_COUNT);
    Command command = {
        .kind = COMMAND_NOTE_ON,
        .voice = voice,
        .frequency = frequency_hz,
        .velocity = velocity,
    };
    push_command(command);
    return voice;
}

void
luma_audio_note_off(int voice)
{
    Command command = { .kind = COMMAND_NOTE_OFF, .voice = voice };
    push_command(command);
}

void
luma_audio_pattern_begin(void)
{
    g_patterns[g_staging].count = 0;
}

void
luma_audio_pattern_add(float frequency_hz, float velocity, int steps)
{
    Pattern *pattern = &g_patterns[g_staging];
    if (pattern->count == PATTERN_CAPACITY)
        return;

    pattern->steps[pattern->count++] = (PatternStep){
        .frequency = frequency_hz,
        .velocity = velocity,
        .steps = steps < 1 ? 1 : steps,
    };
}

void
luma_audio_pattern_commit(float step_seconds, int loops)
{
    Pattern *pattern = &g_patterns[g_staging];
    pattern->step_seconds = step_seconds;
    pattern->loops = loops;

    atomic_store(&g_offered_pattern, g_staging);
    g_staging ^= 1;
}

void
luma_audio_pattern_stop(void)
{
    atomic_store(&g_offered_pattern, -2);
}

void
luma_audio_render_offline(float *frames, int frame_count, int channels)
{
    luma_synth_mix(frames, frame_count, channels);
}

// Drops the command when the ring is full rather than blocking the caller;
// a lost blip is cheaper than a stalled UI thread.
static void
push_command(Command command)
{
    unsigned int head = atomic_load_explicit(&g_command_head, memory_order_relaxed);
    unsigned int tail = atomic_load_explicit(&g_command_tail, memory_order_acquire);
    if (head - tail >= COMMAND_CAPACITY)
        return;

    g_commands[head % COMMAND_CAPACITY] = command;
    atomic_store_explicit(&g_command_head, head + 1, memory_order_release);
}

void
luma_synth_mix(float *frames, int frame_count, int channels)
{
    drain_commands();

    for (int frame = 0; frame != frame_count; frame++) {
        advance_sequencer();

        float sample = 0.0f;
        for (int index = 0; index != VOICE_COUNT; index++) {
            Voice *voice = &g_voices[index];
            if (voice->stage != STAGE_IDLE)
                sample += render_voice(voice);
        }
        sample *= g_level;
        if (sample > 1.0f)
            sample = 1.0f;
        if (sample < -1.0f)
            sample = -1.0f;

        for (int channel = 0; channel != channels; channel++)
            frames[frame * channels + channel] = sample;
    }
}

// Steps the pattern one frame on, triggering whatever the grid lands on. The
// clock is the audio device's own, so a phrase keeps time whatever the host
// is doing.
static void
advance_sequencer(void)
{
    if (g_frames_until_step > 0) {
        g_frames_until_step--;
        return;
    }

    int offered = atomic_load(&g_offered_pattern);
    if (offered == -2) {
        atomic_store(&g_offered_pattern, -1);
        g_performing = -1;
    } else if (offered >= 0 && (g_performing < 0 || g_step_index == 0)) {
        atomic_store(&g_offered_pattern, -1);
        g_performing = offered;
        g_step_index = 0;
    }

    if (g_performing < 0)
        return;

    const Pattern *pattern = &g_patterns[g_performing];
    if (g_step_index >= pattern->count) {
        g_step_index = 0;
        if (!pattern->loops) {
            g_performing = -1;
            return;
        }
        return;
    }

    const PatternStep *step = &pattern->steps[g_step_index++];
    if (step->frequency > 0.0f) {
        Voice *voice = &g_voices[g_sequenced_voice++ % VOICE_COUNT];
        start_voice(voice, step->frequency, step->velocity);
    }
    g_frames_until_step = (int)(step->steps * pattern->step_seconds * SAMPLE_RATE);
}

static void
drain_commands(void)
{
    unsigned int head = atomic_load_explicit(&g_command_head, memory_order_acquire);
    unsigned int tail = atomic_load_explicit(&g_command_tail, memory_order_relaxed);

    for (; tail != head; tail++) {
        const Command *command = &g_commands[tail % COMMAND_CAPACITY];
        switch (command->kind) {
            case COMMAND_PATCH:
                g_patch = command->patch;
                break;
            case COMMAND_NOTE_ON:
                start_voice(&g_voices[command->voice], command->frequency, command->velocity);
                break;
            case COMMAND_NOTE_OFF:
                g_voices[command->voice].stage = STAGE_RELEASE;
                break;
        }
    }

    atomic_store_explicit(&g_command_tail, tail, memory_order_release);
}

static void
start_voice(Voice *voice, float frequency, float velocity)
{
    voice->stage = STAGE_ATTACK;
    voice->frequency = frequency;
    voice->velocity = velocity;
    voice->phase = 0.0f;
    voice->detuned_phase = 0.0f;
    voice->envelope = 0.0f;
    voice->lowpass = 0.0f;
    voice->bandpass = 0.0f;
    voice->patch = g_patch;
}

static float oscillator(int waveform, float phase);
static void advance_envelope(Voice *voice);
static float filtered(Voice *voice, float sample);

static float
render_voice(Voice *voice)
{
    const LumaSynthPatch *patch = &voice->patch;

    float sample = oscillator(patch->waveform, voice->phase);
    voice->phase += voice->frequency / SAMPLE_RATE;
    voice->phase -= (float)(int)voice->phase;

    if (patch->detune_semitones != 0.0f) {
        float detuned = voice->frequency * powf(2.0f, patch->detune_semitones / 12.0f);
        sample = (sample + oscillator(patch->waveform, voice->detuned_phase)) * 0.5f;
        voice->detuned_phase += detuned / SAMPLE_RATE;
        voice->detuned_phase -= (float)(int)voice->detuned_phase;
    }

    advance_envelope(voice);
    return filtered(voice, sample) * voice->envelope * voice->velocity * patch->gain;
}

static float
oscillator(int waveform, float phase)
{
    switch (waveform) {
        case LUMA_WAVEFORM_TRIANGLE:
            return 4.0f * fabsf(phase - 0.5f) - 1.0f;
        case LUMA_WAVEFORM_SAW:
            return 2.0f * phase - 1.0f;
        case LUMA_WAVEFORM_SQUARE:
            return phase < 0.5f ? 1.0f : -1.0f;
        case LUMA_WAVEFORM_NOISE:
            g_noise_seed = g_noise_seed * 1664525u + 1013904223u;
            return (float)(g_noise_seed >> 8) / 8388608.0f - 1.0f;
        default:
            return sinf(TWO_PI * phase);
    }
}

static void
advance_envelope(Voice *voice)
{
    const LumaSynthPatch *patch = &voice->patch;

    switch (voice->stage) {
        case STAGE_ATTACK:
            voice->envelope += 1.0f / fmaxf(patch->attack_seconds * SAMPLE_RATE, 1.0f);
            if (voice->envelope >= 1.0f) {
                voice->envelope = 1.0f;
                voice->stage = STAGE_DECAY;
            }
            break;
        case STAGE_DECAY:
            voice->envelope -= (1.0f - patch->sustain_level) / fmaxf(patch->decay_seconds * SAMPLE_RATE, 1.0f);
            if (voice->envelope <= patch->sustain_level) {
                voice->envelope = patch->sustain_level;
                voice->stage = patch->sustain_level <= 0.0f ? STAGE_IDLE : STAGE_SUSTAIN;
            }
            break;
        case STAGE_RELEASE:
            voice->envelope -= patch->sustain_level / fmaxf(patch->release_seconds * SAMPLE_RATE, 1.0f);
            if (voice->envelope <= 0.0f) {
                voice->envelope = 0.0f;
                voice->stage = STAGE_IDLE;
            }
            break;
    }
}

// Chamberlin state variable, taking the lowpass tap.
static float
filtered(Voice *voice, float sample)
{
    const LumaSynthPatch *patch = &voice->patch;
    if (patch->cutoff_hz <= 0.0f)
        return sample;

    float f = 2.0f * sinf((float)M_PI * fminf(patch->cutoff_hz, SAMPLE_RATE * 0.45f) / SAMPLE_RATE);
    float q = 1.0f - fminf(patch->resonance, 0.98f);

    float highpass = sample - voice->lowpass - q * voice->bandpass;
    voice->bandpass += f * highpass;
    voice->lowpass += f * voice->bandpass;
    return voice->lowpass;
}
