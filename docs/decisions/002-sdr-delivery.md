# SDR delivery from HDR input

P1.04, September 13, 2026. Status: implemented; shared native/FFmpeg synthetic
fixtures pass. Actual phone footage/display acceptance remains pending.
Do not advertise broad iPhone HDR support from this fixture evidence.

The original stays immutable, with inspected transfer, primaries, matrix and
range. Supported inputs are Rec.2020 nonconstant-luminance PQ/HLG with valid color
metadata. HEVC alone does not imply HDR. Dolby Vision and ambiguous HDR metadata
are rejected with a recoverable message; retain the selected original. A
Photos-rendered SDR copy is a distinct selected asset with its own timing.

The delivery policy is Rec.709 SDR, H.264, video range, no HDR metadata. Conversion
occurs before SDR annotations. Preview and final export use the same conversion
within each renderer. No full-HDR output is promised. Platform tone curves can
differ; gray-ramp detail, annotation colors and per-platform preview/export
consistency are measured separately, not inferred from codec tags.

FFmpeg uses its existing zscale/tonemap filters: linearize at nominal 100-nit SDR
white, convert primaries, Mobius transition 0.3 with highlight desaturation 2 and
fixed nominal peak 10 (1000 nits). Compose drawings in sRGB RGB, then transform
to Rec.709 transfer/matrix and limited-range YUV420. Fixed settings avoid content
analysis changing the image between preview and final output. This is a bounded
1000-nit delivery policy; higher-peak mastering is not a reference-grade grade.
Existing SDR FFmpeg conversion remains unchanged.

Native uses AVFoundation's built-in compositor with all three composition color
properties explicitly Rec.709. Apple documents HDR-to-SDR conversion before
compositing for this configuration. Core Image works in sRGB for drawing colors;
its output is converted to the writer's declared Rec.709 space. Do not attach
HDR tags to this output or apply another tone map in Core Image.

New HDR projects require `media.hdr-to-sdr.v1`. Older clients reject rather than
overwrite/render them incompletely. Job policy `hdr-rec709-v1` is immutable;
prior SDR job inputs retain `supported-sdr-v1`. Rollback means retain this project
and recover a prior compatible copy, never strip its capability to force export.

Fixtures are synthetic 10-bit HEVC PQ/HLG gray ramps with known code values,
ordinary MP4 containers, SHA-256 and sampled locations. Reproduce with
`python scripts/generate_hdr_fixtures.py`. Python and XCTest decode the same tiny
movies, import, draw, export, sample boundaries, compare preview/output and
recheck the source hash. Real phone footage, displays and lower-resource-device
performance remain explicit hardware gates.

Primary references checked September 13:

- [Apple: HDR editing and explicit SDR composition properties](https://developer.apple.com/videos/play/wwdc2020/10009/)
- [FFmpeg: linear-light tone mapping options](https://ffmpeg.org/ffmpeg-filters.html#tonemap)
- [FFmpeg: zscale color conversions](https://ffmpeg.org/ffmpeg-filters.html#zscale)
