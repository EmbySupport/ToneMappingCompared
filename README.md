# Tone Mapping Compared

A Windows test suite that compares the HDR-to-SDR tone mapping filters of several FFmpeg builds: stock FFmpeg, Emby, Jellyfin and Plex. It measures performance (the tone mapper on its own, and complete transcodes) and quality (against a stock libplacebo reference), on public 4K HLG, HDR10, HDR10+ and Dolby Vision videos. `index.html` shows the results.

Plex is compared on HDR10 only. Plex also applies its tone mapping to HLG and HDR10+, but it decodes HLG incorrectly and ignores the HDR10+ metadata.

## Project scope

This is the public reproduction suite: users can run the tone-mapping comparisons, investigate their commands and logs, and inspect their own results in the local single-page UI.

The results published on [Emby Compared](https://emby.media/compared/) were produced with the same tone mapping tests. The website is maintained separately and also covers tonemap curves and subtitle burn-in, which are not part of this suite.

## Requirements

- Windows 10 or 11. The launchers use the Windows PowerShell 5.1 that comes with Windows; nothing else needs to be installed.
- The GPUs you want to test: Intel, AMD and/or NVIDIA. Vendors you don't have can be excluded in the configuration.

## Binaries

The FFmpeg builds are not part of the repository. Download the binary package from this repository's releases and extract its `bin` folder into the checkout:

```
bin\stock-ffmpeg.exe
bin\emby-ffmpeg.exe
bin\jellyfin-ffmpeg.exe
bin\plex\Plex Transcoder.exe   (with its DLLs and the codecs folder)
```

[bin/binaries-info.txt](bin/binaries-info.txt) lists the origin and version of each build. Other builds can be configured with `02-Configure.cmd`.

## Running the tests

Run the launchers in the repository root in this order:

1. `01-DownloadTestMedia.cmd` downloads the test videos into `media` and verifies their SHA-256.
2. `02-Configure.cmd` creates `config\user.json` with the binary paths, the GPU selection and exclusions.
3. `03-PreviewTests.cmd` lists the planned tests without running anything.
4. `04-CheckPipelines.cmd` runs a short check of every pipeline. Add `-TestType performance-transcode` or `-TestType quality` for the other routes.
5. `05-RunBenchmarks.cmd` runs the performance tests. `-TestType performance-isolated` or `-TestType performance-transcode` runs only one of them.
6. `06-RunQuality.cmd` compares the output of each filter with the libplacebo reference, curve by curve.
7. `07-OpenResults.cmd` refreshes the viewer data and opens `index.html`.
8. `08-ClearResults.cmd` removes all generated results and logs.

Runs are sequential, and only one suite run can be active at a time. Close other GPU workloads while measuring performance.

Each performance test processes a fixed number of frames, set per test in [config/performance-workloads.json](config/performance-workloads.json), so every machine runs the same workload.

## Documentation

- [Performance benchmarks](docs/benchmarks.md) and the [Dolby Vision method](docs/dolby-vision-isolated.md)
- [Quality comparisons](docs/quality.md)
- [Configuration](docs/configuration.md)
- [Test media](docs/test-media.md)
- [Results viewer](docs/viewer.md)
