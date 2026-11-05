# Native-resolution quality comparisons

Run `06-RunQuality.cmd`, or use built-in Windows PowerShell 5.1. The supplied FFmpeg builds perform decoding, tone mapping, PNG generation and pixel analysis; no additional scripting runtime is required.

```powershell
.\scripts\Run-Quality.ps1 `
    -ClipId hlg-iec-4k,hdr10-iec-4k,hdr10plus-hdclub-4k,dovi-p5-sol-levante `
    -ImplementationId emby-embytonemap-high,emby-embytonemap-fast,emby-embytonemap-opencl `
    -SignedGain 2
```

Stock `libplacebo` runs first for every clip and curve, even when the implementation selection omits it. Other outputs receive scores only after that reference completes. Missing executables, unsupported signals, failed source validation and failed device initialization produce diagnostics without scores. Every process runs sequentially under the shared suite lock.

Reference validation also checks the native rendering log. Libplacebo can report Vulkan allocation or shader failures, emit blank frames, and still return exit code zero. Such a reference is rejected before image sampling or analysis.

## Options

`-UserConfigPath` selects the configuration. `-MaxFrames` changes the raw keyframe extraction limit (default 30). `-SeekSeconds` overrides the clip's quality seek; otherwise `qualitySeekSeconds` takes precedence over `seekSeconds` in the manifest. `-SignedGain` controls the signed-image amplification, defaults to 2 and accepts integers 1 through 32; it does not change metrics or absolute images.

`-DryRun` writes commands and eligibility rows without hashing or decoding media, initializing a device or producing scores. `-OutputPath` writes an additional report at the specified path.

Fresh generation is the default. `-ReferenceReportPath` reuses a stored stock reference only if its binary and source hashes, seek, decoder request, frame limit and retained stride, processing arguments, native dimensions, gains and logs all match. Reference assets are fingerprinted before and after reuse; mismatches reject the scores.

## Frame selection and comparison

`Get-TestMedia.ps1 -VerifyOnly` verifies the original file's pinned SHA-256 and runs a minimal decode check. Expected HDR properties come from the manifest. Ordinary FFmpeg stream headers supply stream observations; these checks do not verify individual decoded-frame HDR10+ or Dolby Vision metadata.

Every mapper reads the pinned original compressed bitstream. `-skip_frame nokey` precedes `-i`, so the decoder outputs keyframes only, and `-frames:v` stops extraction after the frame limit. There are no `select` or `trim` filters, input `-t` or timestamp rebasing. All Quality scale operations add `+accurate_rnd`.

After generation, sampling keeps keyframes 1, 4, 7, ...; HLG starts at 282 seconds, and HDR10 starts at 160 seconds and keeps 1, 6, 11, ... instead. Retained PNGs are renamed `000001.png` onward. Short sources yield fewer keyframes without duplication.

Reports record the generated frame count separately from the retained count, together with each image's stored and source keyframe index. Matching source hashes, seeks, decoder selection, sampling rules, counts and native dimensions are checked before comparison. Matching keyframe ordinals does not prove exact source-time correspondence across builds.

The fixed stock FFmpeg compares the stored 8-bit RGB PNGs afterward. The numbers therefore include each build's decoder behavior and PNG conversion; they do not directly measure the mapper's NV12 planes. Saved graphs and stream observations show how each image was produced.

## Numbers and difference images

Both stored PNGs undergo the same explicit conversion to 8-bit full-range BT.709 `yuv444p`, keeping native dimensions and full-resolution Y/U/V planes. FFmpeg computes PSNR Y/U/V/average, combined chroma PSNR, SSIM Y/U/V/all, the maximum absolute difference per plane, and the fraction of nonidentical samples per plane. Infinite PSNR is stored as the JSON string `"inf"`.

Scores describe agreement with libplacebo, not absolute perceptual quality. Curves, gamut mapping, decoder behavior and colour conversion can change agreement, so images, graphs and settings remain evidence alongside the numbers.

The signed PNG is implementation minus reference in the analysis YUV. `grainextract` sets neutral code 128, and the same configurable gain applies to Y, U and V. At the default gain 2, positive and negative one-code errors become 130 and 126, while equality stays 128. Large errors clip in this visualization; metrics are unaffected. Chroma errors can produce coloured areas.

The raw absolute PNG contains the exact, unamplified absolute differences of the stored RGB codes. Equality is black, and a one-code difference of either sign stays code 1, so close results can look almost black. A separate absolute display PNG uses gain 8: each channel becomes `min(255, 8 * abs(test - reference))`. The gain is the same for all channels and frames, without scene normalization; the raw image and the metrics stay unchanged. Reference images compare libplacebo with itself, so both of its absolute images are black.

## Reports

Actual runs write `results/quality/<run-id>/report.json` and `results/quality.json` under the configured results root, then export the viewer data using the same configuration. Each FFmpeg invocation keeps one `ffmpeg-*.txt` log with its full command and diagnostics, plus a native HTML graph where the build supports it. Reports keep the parsed metrics, binary hashes and versions, devices, stream observations and sequence requests.

The runner checks each generating executable's hash before and after generation, and the stock analysis binary's hash around image analysis. A replaced executable rejects the affected work rather than attributing new images to the previous build.
