# Results viewer

Run `07-OpenResults.cmd` to export the latest reports and open `index.html` directly in the Results view. The header switches between Results and Configuration. The page reads `results/results-data.js` through a local script tag, so it needs no server, installation or network access. To view the results of a different configuration, run `07-OpenResults.cmd -UserConfigPath config/my-user.json`.

The viewer shows only results for the enabled clips whose pinned SHA-256 matches the current manifest. Replacing a clip therefore requires new results before it appears again.

Selectors narrow from left to right: Comparison, Tone Mapping Type, Curve (Quality only), Processing and FFmpeg Source. Performance tables show FPS, Mapped FPS and Speed for full transcodes, Duration and Spread; the expandable method panels above each table explain how the test works. Skipped and failed routes are listed with their reason and logs.

Quality offers Table, Multi-image and Single-image views. The image series switches between the original SDR images, signed differences (gray means identical, default gain 2) and absolute differences (black means identical, default gain 8). The gain slider only changes the display; images and metrics stay unchanged. Captions show luma PSNR and SSIM, which measure agreement with the libplacebo reference. See [Quality comparisons](quality.md) for the meaning of each series and metric.

Results offer three actions: Command shows the copyable Windows PowerShell invocation and its settings, Log opens the FFmpeg log, and Graph opens FFmpeg's execution graph. The graph HTML loads its renderer from jsDelivr, so that view needs network access; everything else loads locally.

The Configuration page lists each filter's source, backend and supported signals, with a summary of its latest runs, and shows the current configuration read-only. Changes go through `02-Configure.cmd` or the JSON file.

To start over, run `08-ClearResults.cmd`. It clears generated reports, images, logs and graphs, removes work logs and validation caches, and resets the viewer data. Downloaded videos, configuration, code and binaries remain. Reload an already open viewer page afterwards.
