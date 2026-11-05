# Configuration

The suite runs with the Windows PowerShell 5.1 included in Windows 10 and 11. FFmpeg executables are configured explicitly and never taken from PATH.

Run `02-Configure.cmd` to create or edit `config/user.json`. It starts from the current file, or from [user.example.json](../config/user.example.json) on the first run; pressing Enter keeps a setting's current value. You can also edit the JSON file directly. `scripts/Initialize-Configuration.ps1 -UseDefaults` saves the current settings, or the example on the first run, without prompts. If `user.json` does not exist, the other scripts read the example configuration.

Relative paths resolve against the repository root. Use escaped backslashes for absolute Windows paths, such as `"F:\\Media\\HDR"`, or forward slashes. Paths are literal; environment variables, wildcards and `~` are not expanded. Drive-relative paths such as `F:media` and root-relative paths such as `\media` are rejected.

| Setting | Meaning |
| --- | --- |
| `schemaVersion` | Must be the integer `1`. |
| `binaries.stock/emby/jellyfin/plex.ffmpegPath` | Executable for that source, or `null` to disable the build. Plex's DLLs and codec modules must stay with its executable. |
| `paths.mediaPath` | Directory for the downloaded and verified original clips. |
| `paths.tempOutputPath` | Directory for intermediate outputs and work files. |
| `paths.resultsPath` | Directory for reports and comparison images. |
| `devices.vulkan` | Zero-based Vulkan device index. |
| `devices.cuda` | Zero-based NVIDIA CUDA device index. |
| `devices.opencl.platform`, `devices.opencl.device` | Quality OpenCL device: both nonnegative indices, or both `null` for vendor selection. |
| `devices.opencl.vendor` | Quality OpenCL device vendor: `intel`, `amd`, `nvidia` or `any`; default `intel`. |
| `devices.performanceOpencl.intel/amd` | Optional performance device settings per vendor: `platform` and `device` both indices or both `null`, and an optional `d3d11Adapter`. Performance tests run each OpenCL filter on Intel and AMD separately. |
| `exclude.software/intel/amd/nvidia` | Excludes all tests of that kind. The actual GPU is also checked against them before a run. |
| `benchmark.filterThreads` | Filter thread count; `0` lets FFmpeg choose. |
| `benchmark.repetitions` | Number of sequential repetitions; default 3. Dolby Vision isolated rows always use three. |
| `benchmark.transcodeDurationSeconds` | Full-transcode duration; default 30, clamped to the remaining clip length. |
| `benchmark.processTimeoutSeconds` | Process timeout; default 300. |
| `benchmark.keepOutputs` | Whether to keep the encoded transcode outputs. |

Omitted benchmark settings take the defaults. Invalid values fail before execution; missing executables and a missing media directory produce diagnostics.

## Catalog

[catalog.json](../config/catalog.json) lists every tested implementation: its source build, filter, backend, the signals it is tested with (`toneMappingTypes`), its test types, GPU vendors, filter options per signal and supported curves. Signal IDs are `hlg`, `hdr10`, `hdr10plus` and `dovi-p5`; test IDs are `performance-isolated`, `performance-transcode` and `quality`. Quality compares implementations using the same selected curve. A filter is identified by its source and name, and sometimes by its variant: `emby-embytonemap-high` and `emby-embytonemap-fast` share a filter but use its `high` and `fast` options. `tonemap_cuda` from Emby, Jellyfin and Plex has different interfaces and separate IDs.

- `embytonemap` and its GPU variants are tested with HLG, HDR10, HDR10+ and Dolby Vision P5.
- Jellyfin's `tonemapx`, `tonemap_opencl` and `tonemap_cuda` are tested with HLG, HDR10 and Dolby Vision P5, using the server's default `peak=100`. They have no HDR10+ metadata support.
- Plex's filters are tested with HDR10 only. Plex needs its official HEVC/H.264/x264 codec modules in `bin/plex/codecs`; they are verified before and after each run.
- Stock `tonemap_opencl` has no BT.2390, ST.2094 or HDR10+ options and covers HDR10 only.
- The older Intel-only Emby OpenCL filters require a confirmed Intel device.

Stock libplacebo is the fixed Quality reference and always runs first, from the stock build. Vulkan performance uses `emby-libplacebo` and `emby-embytonemap-vulkan` from the same Emby FFmpeg on the same GPU. A filter that ignores the selected signal's metadata is not tested with that signal. Every route must pass a runtime preflight before it can be scored; catalog entries describe the supplied builds, not whether a GPU, driver or decoder works.

Configuration values and catalog capabilities appear read-only on the viewer's Configuration page.
