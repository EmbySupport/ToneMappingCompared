# Test media

The tests use four original 3840×2160 HEVC Main 10 videos, one per signal. [media.json](../config/media.json) pins each file's size and SHA-256; it also contains disabled clips, which are not used.

| Manifest ID | Signal | Duration | Quality start | Source |
| --- | --- | ---: | ---: | --- |
| `hlg-iec-4k` | HLG, 4K59.94 HEVC Main 10 | 613 s | 282 s | [IEC broadcast HLG](https://assets.iec.ch/public/tc100/IEC_Broadcast_UHD_5994p_HLG_HEVC_AAC_v1-0.MP4) |
| `hdr10-iec-4k` | HDR10, 4K59.94 HEVC Main 10 | 613 s | 160 s | [IEC broadcast HDR10](https://assets.iec.ch/public/tc100/IEC_Broadcast_UHD_5994p_HDR10_HEVC_AAC_v1-0.MP4) |
| `dovi-p5-sol-levante` | Dolby Vision P5, 4K24 HEVC Main 10 | 263.08 s | 90 s | [Dolby / Netflix Sol Levante](https://github.com/DolbyLaboratories/dolby-vision-contents/tree/957c53ac160e11ae581aa1f4fe811a8ad6cf27df/SolLevante_Netflix) |
| `hdr10plus-hdclub-4k` | HDR10+, 4K23.976 HEVC Main 10 | 50.05 s | 0 s | [HDClub HDR10+ profile B test](https://www.hdclub.ua/files/avpedia_test/hdr10-plus_profile-b_eac3joc.mkv) |

Performance runs start at the beginning of each clip; only the Dolby Vision isolated test samples its eight states from 90 seconds on. HLG quality starts at 282 seconds, so its ten images run to 309 seconds and end before the grey countdown at about 313 seconds.

- The IEC's [published specifications](https://assets.iec.ch/public/tc100/IEC62087-2_2023-ED2_Test-Clip-Details_r8.pdf?2024051246=) describe the two IEC clips.
- Sol Levante is pinned to the official Dolby repository's commit `957c53ac160e11ae581aa1f4fe811a8ad6cf27df`; its direct media URL retrieves the real Git LFS video without Git LFS software. It is Dolby Vision profile 5 with RPUs and must not be treated as a conventional HDR10 base layer.
- The HDClub clip carries per-frame HDR10+ (SMPTE 2094-40) metadata, mastering display metadata (1000 nits) and content light level metadata (MaxCLL 999, MaxFALL 968). It has a keyframe every 2.002 seconds, 25 in total, so Quality keeps 9 images from it. Its EAC3 audio track is not used.

## Download and validation

Use `01-DownloadTestMedia.cmd`, or built-in Windows PowerShell:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Get-TestMedia.ps1

# List without downloading or executing a binary.
.\scripts\Get-TestMedia.ps1 -List

# Set up one clip, or recheck existing originals.
.\scripts\Get-TestMedia.ps1 -ClipId hdr10-iec-4k
.\scripts\Get-TestMedia.ps1 -VerifyOnly
```

Downloads go to a partial file first; the size, SHA-256 and required stream properties must match before it is renamed into `media`. A file that is already present is only verified. `-ReplaceInvalid` replaces an existing invalid download once the new one validates. The default timeout is 600 seconds; `-TimeoutSeconds` accepts up to 3600.

Validation decodes one frame of the original bitstream with the configured stock FFmpeg and compares codec, pixel format, dimensions and the announced colour tags with the manifest. Each validated file receives a sibling `.validation.json`; logs go to `<tempOutputPath>/media-validation/`. These checks do not prove per-frame HDR10+ or Dolby Vision metadata delivery; the tone mappers' own preflights report whether they apply it.

All tone mapping decodes the original compressed media. Decoded intermediates could discard the HDR10+ and Dolby Vision metadata being tested.
