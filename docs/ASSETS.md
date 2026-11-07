# assets

every 3d model / texture / hdri / sound in the project + its license. cc0 preferred

| file | used for | source | author | license |
|---|---|---|---|---|
| `Apps/VisionOS/Resources/range_sky.jpg` | range backdrop (360 photo of a golf hole at sunset, tonemapped 8k jpg) | [Sunset Fairway](https://polyhaven.com/a/sunset_fairway) | Greg Zaal | CC0 |
| `Apps/VisionOS/Resources/range_ibl.hdr` | image based lighting for the range | same as above, 2k hdr | Greg Zaal | CC0 |
| `Apps/VisionOS/Resources/grass_diff.jpg` | 3d grass around the tee + putting green (tinted in code, its leafy/brown raw) | [Leafy Grass](https://polyhaven.com/a/leafy_grass) 2k | Charlotte Baglioni | CC0 |
| `Apps/VisionOS/Resources/grass_nor.jpg` | ground normal map (gl) | Leafy Grass 1k | Charlotte Baglioni | CC0 |
| `Apps/VisionOS/Resources/grass_rough.jpg` | ground roughness | Leafy Grass 1k | Charlotte Baglioni | CC0 |
| `Apps/VisionOS/Resources/Sounds/impact.wav` | club hitting ball | made by `tools/make_sounds.py` (synth) | me | ours |
| `Apps/VisionOS/Resources/Sounds/land.wav` | ball landing | `tools/make_sounds.py` | me | ours |
| `Apps/VisionOS/Resources/Sounds/ambience.wav` | wind + birds loop | `tools/make_sounds.py` | me | ours |
| `Apps/VisionOS/Resources/Sounds/tick.wav`, `tock.wav` | tempo trainer | `tools/make_sounds.py` | me | ours |

## swapping stuff

- sounds: tweak + rerun `python3 tools/make_sounds.py` (needs numpy), or drop real recordings in w/ the same names. freesound.org has cc0 golf impacts if the synth ones sound fake

- range backdrop: drop a new equirect jpg (`range_sky.jpg`) + hdr (`range_ibl.hdr`) in Resources. if the new photo has ground in it, turn `RangeScene.skyYaw` so its fairway runs down the target line + retint `groundTint` to its grass. old pure sky (kloofendal 48d partly cloudy, cc0) was swapped out nov 7
- grass: same, tint + tile size in `RangeScene.grassMaterial(...)`
- better grass later: poly haven "aerial_grass_rock" or a real fairway texture. for 3d models (clubs, tee markers, range mats) try poly haven models or sketchfab cc0
