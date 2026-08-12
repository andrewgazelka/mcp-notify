# TTS models: what they can do, and what this project uses

Working notes on the local text-to-speech landscape as it applies to `notify`.
Everything in the "verified" sections was checked against source or weights on
this machine on 2026-08-11 and cites the file it came from. Anything I could not
check is labelled as such, because model knowledge goes stale quietly and this
file is meant to be trustworthy a year from now.

## What notify actually needs

`notify` speaks one-sentence status lines from a coding agent, each carrying an
explicit emotional valence word:

    relieved: the gate passed first try
    worrying: flat metrics after 8 minutes, investigating now
    delighted: 17x speedup, and the bench confirms it
    embarrassing: I claimed that file was unchanged and it was not

That usage sets the requirements, and they are unusual enough that general TTS
leaderboards do not answer them:

| Requirement | Why | Consequence |
|---|---|---|
| Time to first audio well under 1 s | Fired many times a minute, often mid-thought | Rules out anything without streaming or with heavy per-call setup |
| One consistent persona | It is a voice, not a narrator pool | Rules out models that drift or randomize identity per call |
| Never blocks the caller | Hard invariant of the tool | Architectural, not a model property |
| Never overlaps another utterance | Hard invariant of the tool | Architectural, not a model property |
| Expressive range | The valence word should be audible, not just lexical | This is the open question, see below |

## Current engine: Holler 0.6B

Apache-2.0, `sentiuminc/holler-0.6b`, a supervised finetune of Qwen3-TTS-12Hz-0.6B
with six curated American English voices. We use **Oliver** (deep, confident,
measured). 24 kHz output.

Measured on this machine (M5 Max), warm, at rate 1.5x, measured at the mixer tap
so the number includes CoreAudio's own latency:

    TTFA   median 305 ms   p95 ~400-500 ms
    load   447 ms
    RTF    ~1.1 including playback wait

### Verified facts about the Holler stack

Checked against the pinned checkouts (`holler` 0.10.0, `mlx-audio-swift`
0.31.3-holler.4) and the downloaded weights.

- **bf16 is really bf16.** `HollerModel.load()` defaults to the *6-bit* repo, so
  the bf16 repo must be named explicitly or you silently get the fast variant.
  We pass it explicitly. Safetensors header check: talker is 402/402 tensors
  BF16 with no `.scales`/`.biases`; codec decoder is 496/496 F32. No quantization
  block in either `config.json`, so the `quantize(...)` path never runs.
- **16 codebooks is the true maximum**, not a tunable we are under-using.
  `num_code_groups: 16` in both the talker and code-predictor configs, and
  `num_quantizers: 16` in the codec. Values below 16 are zero-padded into the
  residual quantizer rather than omitted. Holler's own docs describe 12
  codebooks as a quality loss taken for speed.
- **The streaming decoder is correct.** Every layer carries proper state across
  chunks: causal convs keep a `k-1` sample tail, the upsample block does correct
  overlap-add, the pre-transformer uses a KV cache with an offset-sliced causal
  mask. Chunked decode is equivalent to whole-sequence decode. There is in fact
  no whole-utterance path to compare against, since every path runs the same
  streaming step.
- **`streamingChunkTokens` is a dead parameter.** Chunk size is hardcoded to 3
  in `Qwen3TTS.swift`. The value is threaded through five layers and never read.
  Worse, it is *not* inert on the HollerKit side: it divides the silence-abort
  threshold, so raising it makes the abort trigger hair-fine and can truncate
  real speech. Leave it at 3.
- **Sampling is richer than HollerKit exposes.** The generate path implements
  top-k, top-p, min-p and repetition penalty, but `HollerConfiguration` only
  surfaces `temperature` and `topK`. top-p and min-p sit at their disabled
  defaults. Repetition penalty invisibly resolves to 1.05, not 1.0, which
  happens to match the reference config.
- **top-k and temperature drive all 16 codebooks identically**, including the
  fine residual levels, which are sampled stochastically rather than argmax'd.
  So raising temperature adds timbral roughness, not just prosodic variety, and
  there is no knob to decouple the two.
- **Generation is not reproducible.** `seed` is accepted by the parameter struct
  and ignored by this path, so the sampler draws from the global MLX RNG. Worth
  knowing before running any A/B: two renders of the same text differ.
- **24 kHz is baked into the weights.** The decoder's upsample factors multiply
  to exactly 1920 samples per token at 12.5 tokens/s. Raising it needs a
  different codec and a retrain, not a config change.

### The one real defect we found and fixed

`targetLUFS: -20.0` is **not** loudness normalization despite the name. It is a
per-chunk RMS compressor (one chunk = 240 ms) with a ~670 ms one-pole time
constant, up to +12 dB of boost, and a 0.9 peak ceiling that writes back into its
own gain state so a single loud transient durably pulls the level down and
recovers slowly. No K-weighting, no gated blocks, no integrated measurement.
Audibly: pumping, plus flattened emphasis.

For this project that is actively harmful, because prosodic loudness contour is
where the emotional valence lives. We disabled it and measured the raw output
instead (`notifyd --measure-levels`):

    median RMS  0.0751 (-22.5 dBFS)
    spread      0.0534 .. 0.0867 across 16 utterances
    worst peak  0.5241

Excluding a single 0.46 s utterance, the spread is under 2 dB. The model's raw
output is already consistent enough that no dynamics processing is justified, so
the compressor could only ever remove prosody. It is replaced by a **static gain
of 1.441x** (lands at a -20 LUFS speech target, worst-case peak 0.755, so ~2.4 dB
of headroom) plus a soft knee above 0.95 that should never engage.

### What Holler cannot do

**No expressive control of any kind.** Six fixed voices, stock Qwen3 tokenizer
with no emotion or nonverbal tokens (verified by reading `tokenizer_config.json`:
the only special tokens are structural ones like `<|audio_start|>`). You cannot
ask it to whisper, shout, laugh, or sound worried. Delivery is whatever the text
implies. For `notify` this is the main limitation, since the whole point of the
valence word is that the feeling should be audible.

## Playback chain quality

Independent of the model, three settings were being left at defaults:

- **`AVAudioUnitTimePitch` smoothness** (the deprecated `overlap` alias),
  range 3-32, default 8, now **32**. The header is explicit that higher means
  fewer artifacts at proportional CPU cost, and time-stretching speech to 1.5x
  is the most artifact-prone step in the pipeline.
- **Spectral coherence (peak locking)** and **transient preservation**, both
  reachable only through the raw AudioUnit rather than the Swift wrapper. Both
  document a default of 1; we set and then *verify* them, since a silently
  unapplied parameter degrades every utterance without ever failing.
- **Resampling.** 24 kHz Holler output was being converted to the 48 kHz device
  rate by the mixer's implicit input converter, which has no reachable quality
  setting. It is now an explicit `AVAudioConverter` pinned to the mastering
  algorithm at max quality, with one converter per utterance rather than per
  chunk (a fresh converter per chunk would put a discontinuity every 240 ms).

`notifyd --selftest-audio` prints all of these as actually configured.

Measured cost of all the above: none. TTFA median stayed at ~305 ms.

## Other engines

### dots.tts-soar (wired, not yet evaluated)

`rednote-hilab/dots.tts-soar` via `smcleod/dots.tts-soar-mlx`, 2B continuous
autoregressive, 48 kHz native, Apache-2.0. Clone-only, so it needs a reference
clip rather than a preset voice, which is why the plan bakes a shared Oliver
reference so the A/B isolates the model rather than the voice.

Known risk, not yet measured: no streaming, and it recomputes the speaker
embedding, reference VAE latents and patch prefill on every call, so its TTFA
*is* whole-clip generation time. Honest possible outcome is "nicer voice you
cannot afford".

### Why the "which model is SOTA" question has no clean answer

The benchmarks disagree with each other, which is the reason this project has a
multi-engine seam at all rather than a single chosen model:

| Signal | Winner | Note |
|---|---|---|
| Human blind Elo (Artificial Analysis) | Fish S2 Pro | ranks Qwen3-TTS *low* |
| UTMOS naturalness (tts-bench) | Qwen3-TTS 0.6B | ranks dots.tts *low* |
| Seed-TTS-Eval WER/SIM, EmergentTTS | dots.tts 2B | not in the human arena at all |

Fish S2 Pro is excluded on licence and runtime grounds: non-commercial research
licence, Python-only.

### Expressive / taggable models

Researched 2026-08-11. The short version: **the model that would solve this
exactly does not exist yet.** Qwen's own capability table lists
`Qwen3-TTS-25Hz-1.7B-VoiceEditing` with *both* cloning and instruct. It is
unreleased (QwenLM/Qwen3-TTS issue #34 still tracking it as of 2026-08-05).
Check monthly; it would obsolete this entire section.

#### Why Holler cannot be upgraded in place

Holler finetunes Qwen3-TTS-12Hz-0.6B-**Base**. In the released 12 Hz family the
capabilities are **disjoint**:

- **Base** clones, does not instruct. A Qwen maintainer (issue #25): "Since the
  control capability of the 12Hz base model is relatively unstable, our base
  model does not currently support instruct." Discussion #121 reports a Base
  finetune "completely fails to follow instructions".
- **CustomVoice / VoiceDesign** instruct, do not clone. Instruction control is
  **1.7B-only**; 0.6B-CustomVoice does not have it.

So you cannot have Oliver *and* per-line emotion in one Qwen3-TTS 12 Hz call.

#### The second-engine seam is cheaper than expected

`sentiuminc/mlx-audio-swift` @ `0.31.3-holler.4` is already resolved and compiled
in transitively via Holler, and it contains:

    Chatterbox  EchoTTS  FishSpeech  Llama  Marvis  MossTTSNano
    PocketTTS   Qwen3    Qwen3TTS    Soprano  StyleTTS2

Chatterbox (incl. Turbo), all three Qwen3-TTS variants, Orpheus, Fish S2 Pro,
Marvis, PocketTTS, Soprano and StyleTTS2/Kokoro are therefore **already
linkable with no `Package.swift` change at all**. A new engine conforming to
`SpeechEngine` maps straight onto their `generateStream`.

#### Ranked, for this use case

**1. Qwen3-TTS-12Hz-1.7B-CustomVoice.** Apache-2.0, 1.7B, 24 kHz. Already
vendored. Control is two channels rather than inline tags: a preset `speaker` ID
plus a free-text `instruct` string, which maps 1:1 onto a valence dictionary.

There is a **real bug in the vendored Swift port**: `Qwen3TTS.swift` (~line 458)
assigns the entire `voice` string to the speaker lookup and drops the instruct
on the floor, failing semi-silently with `[warning] speaker '...' not found in
spkId map`. But the layer beneath already takes `instruct:` and `speaker:` as
separate parameters and builds a proper instruct prefill (`<|im_start|>user\n
...<|im_end|>`) concatenated ahead of the role and text embeddings. So enabling
this is parameter threading, not a port.

Voice identity is the best of any candidate here: CustomVoice speakers are
**discrete learned speaker-ID embeddings**, not clip-derived x-vectors, so the
same ID is the same person every time. Cost: it is a *different* person from
Oliver, pinned once.

Honest caveats: instruct-following on this family is documented as weak and
wants temperature near 0.9 (versus our 0.7); issue #298 reports timbre and
emotion drift across runs. Expect "audibly different delivery per valence",
not acting. Latency roughly 2-3x Holler, so several hundred ms rather than 305.

**2. Chatterbox Turbo (Resemble AI).** MIT, ~350M, 24 kHz, also already
vendored, and it **can clone Oliver**, so the persona survives. Controls are
`exaggeration` (intensity) and `cfg_weight` (pacing), plus inline bracket tags.
chatterbox.cpp reports 279 ms first audio on an M4.

Ranked second on reliability, not capability: multiple reports that Turbo
**ignores `exaggeration` entirely**, tags are hit-or-miss, and issue #504 is a
hook leak that corrupts repeated short calls in a long-lived process, which is
exactly this workload. Costs nothing but a config change to try, so try it
first if keeping Oliver matters more than control fidelity.

**3. VibeVoice-Realtime-0.5B (Microsoft).** Best measured latency and best voice
determinism (26 baked voice caches, no cloning needed). **No tags at all**;
maintainer, issue #77: "Explicit speech tagging is not supported at the moment."
The sanctioned workaround is to precompute one voice cache per emotion from
emotionally distinct clips of the same speaker and select by valence word,
which is a free dict lookup at inference. Measured RTF 0.43 on an M2 Max (INT4).
Needs a new dependency and the cloning encoder is unofficial; code is MIT but
the model card layers research-only terms, and Microsoft pulled the TTS code in
Sept 2025 "due to widespread misuse".

**4. Do nothing to the engine.** Not a joke option; see "the free wins" below.

**Later:** CosyVoice3 (instruct text sometimes gets *read aloud*),
IndexTTS-2.5 (the emotion API you actually want, an 8-float vector over
`[happy, angry, sad, afraid, disgusted, melancholic, surprised, calm]`, but
RTF 1.71 on an M1 Max, non-streaming, a filed MPS memory leak on M4 Max 128 GB
that never releases until process exit, and a non-open bilibili licence).
Re-check when someone ports 2.5 to MLX.

#### Disqualified, with reasons

| Model | Why not |
|---|---|
| **Maya1** | The most tempting trap. Perfect on paper: Apache-2.0, `<description="...">` persona plus 17 single-token tags (`<laugh> <whisper> <sarcastic> <sigh>`...). Three independent hands-on tests converge on the same failure: **tags ignored, or the tag name spoken out loud.** No reference-audio cloning at all, so voice stability rests on a byte-identical description string. |
| **Dia 1.6B** | Best-documented tag set anywhere, but **0.1x realtime on an M2 Pro** (~60 s for a 6 s sentence), "different voices every time you run", and the seed fix has been broken since Apr 2025. Its own guidance says under-5 s input "will sound unnatural", which is our entire use case. Dia2 is CUDA-only. |
| **Orpheus 3B** | Real nonverbal tags, but ~2.4 RTF in MLX-Swift on an M3, i.e. slower than realtime, plus ~400 ms of leading background noise. |
| **Higgs Audio v3** | Inline control plus cloning, but RTF 0.78 on an M5 Pro with no streaming, so TTFA is the whole clip. Research/non-commercial licence. |
| **Sesame CSM-1B** | No tags. Maintainer: "There is no specific markup for this... would require fine tuning." |
| **Fish S2 Pro** | Non-commercial licence, and the vendored Swift API does not even use `voice`, so the persona cannot be pinned. |
| **Kokoro-82M** | Confirmed no tags, no emotion control. A less expressive Holler. |
| **ElevenLabs v3** | Best tag system by a distance. Cloud only, fails the local requirement outright. |

#### What was actually built: valence-keyed prosody

Implemented in `notifyd/Sources/notifyd/Valence.swift`, on by default,
`--no-prosody` or `NOTIFY_PROSODY=0` to disable for A/B.

Every notify line already opens with an explicit emotion word, which is a free
and perfectly reliable label sitting at the front of the utterance. Seven
families, each setting four things: the separator that replaces the colon,
terminal punctuation, sampling temperature, playback gain, and rate.

| Family | Words (examples) | Separator | Temp | Gain | Rate |
|---|---|---|---|---|---|
| bright | delighted, proud, satisfying, excited | `!` | 0.75 | +1.0 dB | 1.04x |
| settled | relieved, reassured, confident | `,` | 0.68 | +0.3 dB | 0.98x |
| tense | worrying, uneasy, concerning, anxious | `...` | 0.72 | +0.5 dB | 1.06x |
| flat | tedious, disappointing, dull | `.` | 0.62 | -1.0 dB | 0.96x |
| sharp | frustrating, annoyed, irritating | `.` | 0.70 | +1.2 dB | 1.02x |
| contrite | embarrassing, wrong, sorry, mistaken | `...` | 0.66 | -1.5 dB | 0.94x |
| alert | surprising, confusing, curious, puzzled | `,` | 0.74 | +0.8 dB | 1.02x |

Design constraints worth preserving:

- **It never changes a word.** It rewrites the separator, supplies terminal
  punctuation only when the line ends bare, and nudges three continuous
  parameters. If it starts editing prose it has become a different feature.
- **Unrecognised input degrades to exactly the old behaviour**, with a nil
  profile: no colon, a colon more than 40 characters in (`ratio 3:1` is
  content, not a valence prefix), or an unknown word.
- **The prefix may be a phrase.** Lines like `uneasy but glad I checked:` are
  normal, so every word before the colon is checked and the first recognised
  one wins.
- **Temperature range is deliberately narrow** (0.62 to 0.75). Holler applies
  temperature to all 16 RVQ codebooks including the fine acoustic levels, so
  past roughly 0.8 it buys timbral roughness rather than expression.
- **Gain is the most reliable lever.** Loudness is the strongest perceptual cue
  for arousal and it is exact and free, unlike whatever the model may or may not
  do with punctuation.
- **Gain is applied at playback, not in the engine**, so it cannot influence
  what the model generates.

Per-utterance temperature is safe despite being engine-global state, because
`SpeechQueue` serialises utterances: synthesis of the next cannot begin until
the current one has finished playing. `HollerModel.configuration` is a mutable
property on a final class and `stream()` snapshots it at call time, so it takes
effect on the next utterance with no reload.

Measured cost: none. TTFA median stayed at ~305 ms across repeated runs. One
run read 399 ms and was traced to a load average of 21.8 from unrelated work on
the machine, not to this change.

`notifyd --valence-demo` speaks one line per family; run it with and without
`--no-prosody`, since that A/B is the only thing that settles whether the table
is any good.

#### The free wins, which should be tried first

1. **The AGC fix above is the highest-value expressivity change already made.**
   Whatever prosodic range Holler has was being flattened by a per-chunk
   compressor. Re-listen before concluding the model is inexpressive.
2. **Text-side prosody.** Holler's Base lineage responds to punctuation,
   capitalization, ellipses and sentence shape, and we control the text
   completely. A valence-keyed transform (trailing exclamation for delighted,
   ellipsis and comma for worrying, short clause and full stop for
   embarrassing), plus per-valence temperature and gain now that the AGC is
   gone, costs **zero latency and zero dependencies**.

The honest framing: the valence word is already the *first token of every line*,
so a listener has the emotional frame before prosody could deliver it. Switching
engines buys redundant emphasis, paid for with 2-3x latency and a new voice.
Measure the free wins first.

## Method notes

Two mistakes made while producing these numbers, recorded so they are not
repeated:

- A lock-contention test used `flock(1)`, which **does not exist on macOS**.
  Every probe returned a false "HELD" from a command-not-found. A test whose
  failure mode is indistinguishable from success is not a test. Replaced with a
  `fcntl.flock` probe that self-tests both states before being trusted.
- The daemon installed a `DispatchSource` signal handler on `.main` after
  calling `signal(SIGTERM, SIG_IGN)`. Under Swift's async main the main dispatch
  queue is never serviced, so the handler could not run and SIGTERM was fully
  ignored, leaving the daemon killable only by SIGKILL. Three orphaned daemons
  accumulated before this was noticed. launchd stops agents with SIGTERM, so
  this would have made every reinstall leave the old binary running.
