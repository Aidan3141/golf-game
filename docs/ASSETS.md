# assets

every 3d model / texture / hdri / sound in the project + its license. cc0 preferred

| file | used for | source | author | license |
|---|---|---|---|---|
| `Apps/VisionOS/Resources/range_sky.jpg` | range sky (golden hour, no ground, tonemapped jpg downsized to 8k) | [Kloppenheim 06 (Pure Sky)](https://polyhaven.com/a/kloppenheim_06_puresky) | Greg Zaal, Jarod Guest | CC0 |
| `Apps/VisionOS/Resources/range_ibl.hdr` | image based lighting for the range | same as above, 2k hdr | Greg Zaal, Jarod Guest | CC0 |
| `Apps/VisionOS/Resources/grass_diff.jpg` | putting green (tinted in code, its leafy/brown raw) | [Leafy Grass](https://polyhaven.com/a/leafy_grass) 2k | Charlotte Baglioni | CC0 |
| `Apps/VisionOS/Resources/grass_vivid.jpg` | range grass + fairway stripes. grass_diff turned gray + bright so the tint is the real color (vivid green) | Leafy Grass 2k, edited | Charlotte Baglioni | CC0 |
| `Apps/VisionOS/Resources/grass_nor.jpg` | ground normal map (gl) | Leafy Grass 1k | Charlotte Baglioni | CC0 |
| `Apps/VisionOS/Resources/grass_rough.jpg` | ground roughness | Leafy Grass 1k | Charlotte Baglioni | CC0 |
| `Apps/VisionOS/Resources/Sounds/impact.wav` | club hitting ball | made by `tools/make_sounds.py` (synth) | me | ours |
| `Apps/VisionOS/Resources/Sounds/land.wav` | ball landing | `tools/make_sounds.py` | me | ours |
| `Apps/VisionOS/Resources/Sounds/ambience.wav` | wind + birds loop | `tools/make_sounds.py` | me | ours |
| `Apps/VisionOS/Resources/Sounds/tick.wav`, `tock.wav` | tempo trainer | `tools/make_sounds.py` | me | ours |

## swapping stuff

- sounds: tweak + rerun `python3 tools/make_sounds.py` (needs numpy), or drop real recordings in w/ the same names. freesound.org has cc0 golf impacts if the synth ones sound fake

- range sky: drop a new equirect jpg (`range_sky.jpg`) + hdr (`range_ibl.hdr`) in Resources, turn `RangeScene.skyYaw` to put the sun where u want it. use a pure sky (no ground) so the 3d grass can run flat to the horizon, a photo w/ its own ground (we tried sunset fairway) has hills that dont match a flat range + stuff floats
- grass: same, tint + tile size in `RangeScene.grassMaterial(...)`
- better grass later: poly haven "aerial_grass_rock" or a real fairway texture. for 3d models (clubs, tee markers, range mats) try poly haven models or sketchfab cc0
