# Dolby Vision P5 isolated performance

Dolby Vision carries dynamic metadata that changes from scene to scene, and a tone mapper has to follow those changes. A single-frame loop keeps the metadata constant and leaves that work out of the measurement.

## Observed change rate

From our observations, the metadata changes in a way that matters for tone mapping on roughly 3 to 8% of the frames of typical content, around 5% in the middle, which is about once every 20 frames. Some content barely changes at all. A fixed rate of one change per 20 frames is an approximation; it does not recreate the exact rate of every source.

## Eight-state workload

The workload takes eight frames from different scenes of the original Dolby Vision source, using every fifth keyframe from the clip's sampling position, and repeats each of them exactly 20 times. The resulting 160-frame sequence has a metadata change every 20 frames. Each frame keeps its decoded Dolby Vision side data and any required input preparation. Hardware implementations upload the states once before repetition and keep the mapper's output on the GPU through `wrapped_avframe` to the null muxer.

For the pinned Sol Levante input, the sampling position is 90 seconds; the eight states come from source seconds 92, 102, 112, 122, 132, 142, 152 and 162. A ninth keyframe, at 172 seconds, provides the frame-rate filter's lookahead; only the first 160 repeated frames form the loop buffer.

Before timing, a reference run with Emby's CPU tone mapper verifies that the sampled sequence produces the expected metadata changes over six bounded passes (`loop=5`, 960 frames). If the first window does not, nearby windows are tried. If every window shows no changes at all, the source is treated as static and timed with a single-frame loop; otherwise the eight-state method cannot be used for that source. The debug logs of this check stay in the work folder and are not part of the published results.

## Fixed paired timing

The policy is `fixed-workload`. The short window is one 160-frame pass. The long window's frame count is fixed for each implementation in [performance-workloads.json](../config/performance-workloads.json), in whole 160-frame passes, together with the sampling position and keyframe stride, so every machine runs the same windows. Timing uses `loop=-1` for an infinite state loop, stopped by the recorded output frame limit.

Supply `-DoviShortFrames` and `-DoviLongFrames` together to fix reproducible window sizes. Both counts must be multiples of 160, and the long count must be larger. Such rows record the policy `explicit-windows` and are neither resized nor gated by duration.

For each of three valid pairs, calculate the incremental per-frame cost:

`cost = (rtimeLong - rtimeShort) / (framesLong - framesShort)`

Use the median of the three costs; reported FPS is its reciprocal. Retain the requested and actual short/long frame counts and observed durations with the implementation/device result. Reject incorrect output counts and nonpositive paired times, while preserving those attempts and their reasons. Report spread as `(max FPS - min FPS) / max FPS * 100`.

The pair subtraction removes common startup and preparation costs. Loop dispatch, tone mapping including following the metadata changes, and required output conversion remain in the measured cost. No per-iteration upload or hardware readback is added.

## Recorded methods and fallback

An eight-state result records `isolatedMethod.mode = dovi-eight-state`, its state/loop/timing counts, aggregation, the outcome of the sequence check, and `isolatedMethod.timingPolicy` with `shortFrames` and `longFrames`. The row's `timing` holds its fixed workload; each sample holds its observed durations and paired difference. The viewer distinguishes these rows from single-frame loops with constant metadata.

`single-frame-static-metadata` is used only when the sequence check finds no metadata changes for that source. Its result keeps a clear method label rather than dropping the filter from the comparison.
