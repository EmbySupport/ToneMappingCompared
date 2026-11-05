# Performance benchmarks

Run `05-RunBenchmarks.cmd`, or run the script with the Windows PowerShell included in Windows 10/11:

```cmd
%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\Run-Benchmarks.ps1 -TestType performance-isolated -ClipId hdr10-iec-4k -ImplementationId emby-embytonemap-high -Repetitions 3
```

For multiple IDs from a PowerShell prompt, pass an actual array (`-ImplementationId @('emby-embytonemap-high', 'stock-swscale')`). Windows PowerShell's `-File` launcher receives one string per option, so run an individual ID from a command prompt or use the default selection.

## Options

`-TestType` selects `performance-isolated`, `performance-transcode`, or `all` (default). `-ClipId` and `-ImplementationId` select manifest/catalog IDs. `-UserConfigPath` chooses a configuration file. `-Repetitions` and `-DurationSeconds` override configured values. `-FrameCount` overrides the configured isolated frame count; it does not apply to Dolby Vision eight-state rows, which take `-DoviShortFrames` and `-DoviLongFrames` instead. Every override is recorded with the result.

Performance runs start at the beginning of the clip, except Dolby Vision isolated runs, whose sampled states use the clip manifest's seek. `-SeekSeconds` overrides both.

`-DryRun` writes a command preview without starting media validation, FFmpeg or GPU work. `-OutputPath` additionally writes the report to a chosen path. `-StopOnError` stops on an invalid timing pair or failed execution, keeping the report and logs.

## Checks before scoring

Every run verifies the original file's pinned SHA-256 and a decode check, then checks each implementation's decoder, filters, options and a bounded processing run. Binary hashes are checked before preflight, before repetitions and after each process, so a replaced executable cannot produce a score under the previous build's identity. The actual device vendor must match the configuration and exclusions. Unsupported signals, disabled clips, missing binaries and failing routes become skipped or failed rows with their reason and logs. No frame-property filters, frame-time collection or extra hardware readbacks are added.

Only conversions required by a particular implementation are applied. There is no blanket source-format conversion or colour retagging, and metadata application controls follow the selected signal.

## Isolated test

Isolated measurements decode directly from the compressed original and prepare one frame for the tone mapper before looping it. Required input conversions, including stock tonemap's linear-float preparation, happen once before the loop. GPU frames are uploaded once before the loop and reach `wrapped_avframe` with `-f null`, without per-iteration uploads, downloads or pixel encoding.

Each sample pairs a run with one frame and a run with N frames. Per-frame cost is `(rtime(N) - rtime(1)) / (N - 1)`; reported FPS is its inverse. This removes startup, one-time setup, decoding, input preparation and the initial upload, while keeping loop dispatch, the tone mapper and any required output conversion. Stock tonemap's SDR output conversion stays in its measured chain. A repeated frame holds dynamic metadata constant; Dolby Vision uses an eight-state sequence instead, described in [Dolby Vision isolated performance](dolby-vision-isolated.md).

N is fixed for each case in [performance-workloads.json](../config/performance-workloads.json). Every machine processes the same workload; previous results, calibration runs and measured speed do not change N. Clearing results leaves the workload configuration intact. Each row records its workload in `timing`.

## Full transcode test

Full transcodes decode the first 30 seconds of the original, with the output frame count fixed for each case in the workload configuration, tone map at native resolution, scale to 720p and encode H.264 with low-effort settings. GPU routes stay on the GPU from decoder to encoder, with no `hwupload`, `hwdownload` or software scale: CUDA with NVENC, OpenCL with QSV on Intel or with AMF on AMD, and Vulkan with Vulkan Video. On AMD, Emby maps between AMF and OpenCL and scales with `vpp_amf`, like the Emby server; the other builds map between D3D11 and OpenCL and scale with `scale_d3d11`. Software implementations decode in software and encode with libx264 `ultrafast`. A route that a build cannot run is reported with its native error rather than replaced by a software path.

With one tone mapping pass per frame, fast GPU tone mappers are hidden behind the hardware decoder. GPU routes therefore repeat each decoded frame five times (`fps=source_fps*5`) before it is mapped into the tone mapper's API, and keep one of the five (`fps=source_fps/5`) after it is mapped back, right before the scaler. Mapping in, tone mapping and mapping back run five times per output frame; decoding, scaling and encoding run once. Software routes use a single pass.

FPS is output frames divided by FFmpeg's wall time. Mapped FPS counts the tone mapping passes: five times FPS on GPU routes. Speed is output frames divided by the nominal source frame rate and the wall time. Very fast tone mappers can still reach the limit of the decoder or encoder; their FPS is then a lower bound.

For software routes, a control run without the tone mapper is paired when it is meaningful, to estimate the tone mapper's CPU cost. That estimate requires identical frame counts and a positive CPU-time difference.

The Vulkan comparison uses libplacebo (`emby-libplacebo`) and `embytonemap_vulkan` from the same Emby FFmpeg on the same GPU. Stock libplacebo is the Quality reference only.

## Results and spread

Isolated and full transcode rows report the best valid sample; Dolby Vision eight-state rows report the median of three valid pairs. Spread is `(max FPS - min FPS) / max FPS x 100` across the valid samples. A Spread of 35% means the slowest valid repetition reached 65% of the fastest one's FPS. One valid repetition cannot show repeatability, even though its spread is zero. Small differences on a desktop can be noise.

Each run's report is saved under `results/performance/<UTC-run-id>/report.json`. `results/performance.json` is the published matrix: after every measured repetition, the run's rows replace the published rows with the same clip, implementation and test type. Published rows of other runs are kept while they use the current method and the binary that is currently configured for their source. Viewer data is exported with every publication. Reports contain copyable Windows PowerShell commands, one FFmpeg log per invocation, FFmpeg's execution graphs where available, binary hashes and versions, stream descriptions, device settings and every sample.

## Running conditions

All executions are sequential, and a suite lock prevents other benchmark, quality or preflight runs from starting at the same time. Before each process, the runner checks for other running `ffmpeg` processes and stops if it finds any. Implementation order and pair order alternate between repetitions. Transcode outputs are removed after timing unless `benchmark.keepOutputs` is true. Close other heavy workloads and keep power and thermal conditions consistent when comparing runs.
