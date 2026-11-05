# assets

every 3d model / texture / hdri / sound in the project + its license. cc0 preferred

| file | used for | source | author | license |
|---|---|---|---|---|
| `Apps/VisionOS/Resources/sky_8k.jpg` | visible sky sphere (tonemapped jpg, recompressed q80) | [Kloofendal 48d Partly Cloudy (Pure Sky)](https://polyhaven.com/a/kloofendal_48d_partly_cloudy_puresky) | Greg Zaal, Jarod Guest | CC0 |
| `Apps/VisionOS/Resources/sky_2k.hdr` | image based lighting | same as above, 2k hdr | Greg Zaal, Jarod Guest | CC0 |
| `Apps/VisionOS/Resources/grass_diff.jpg` | ground color (tinted green in code, its leafy/brown raw) | [Leafy Grass](https://polyhaven.com/a/leafy_grass) 2k | Charlotte Baglioni | CC0 |
| `Apps/VisionOS/Resources/grass_nor.jpg` | ground normal map (gl) | Leafy Grass 1k | Charlotte Baglioni | CC0 |
| `Apps/VisionOS/Resources/grass_rough.jpg` | ground roughness | Leafy Grass 1k | Charlotte Baglioni | CC0 |
| `Apps/VisionOS/Resources/Sounds/impact.wav` | club hitting ball | made by `tools/make_sounds.py` (synth) | me | ours |
| `Apps/VisionOS/Resources/Sounds/land.wav` | ball landing | `tools/make_sounds.py` | me | ours |
| `Apps/VisionOS/Resources/Sounds/ambience.wav` | wind + birds loop | `tools/make_sounds.py` | me | ours |
| `Apps/VisionOS/Resources/Sounds/tick.wav`, `tock.wav` | tempo trainer | `tools/make_sounds.py` | me | ours |

## swapping stuff

- sounds: tweak + rerun `python3 tools/make_sounds.py` (needs numpy), or drop real recordings in w/ the same names. freesound.org has cc0 golf impacts if the synth ones sound fake

- sky: drop a new equirect jpg/hdr in Resources w/ same names, or change names in `RangeScene.addSky()`
- grass: same, tint + tile size in `RangeScene.grassMaterial(...)`
- better grass later: poly haven "aerial_grass_rock" or a real fairway texture. for 3d models (clubs, tee markers, range mats) try poly haven models or sketchfab cc0
