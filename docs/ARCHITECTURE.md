# architecture

## data path

watch cant talk to vision pro directly (watchconnectivity is watch <-> paired iphone only), so iphone relays.

```
apple watch                 iphone                        vision pro
-----------                 ------                        ----------
motion capture (high rate)  watchconnectivity receiver    local network receiver
on-device swing detection → relay + swing history     →  launches ball
sends small SwingResult     debug charts                  coaching cards
```

- watch does all the analysis, only sends a small `SwingResult`. raw samples go via `transferFile`, debug only
- few hundred ms swing → ball latency is fine. watch haptic hits right away, ball launches after
- iphone → vision pro transport goes behind a protocol so it can be swapped (decided in M5, leaning network framework + bonjour)

## targets

| target | platform | bundle id | what |
|---|---|---|---|
| `GolfGame` | visionOS 27 | `com.aidanbulovic.golfgame` | main window + driving range immersive space |
| `GolfGame iPhone` | iOS 27 | `com.aidanbulovic.golfgame.phone` | relay, history, debug charts. embeds watch app |
| `GolfGame Watch` | watchOS 27 | `com.aidanbulovic.golfgame.phone.watchkitapp` | capture + detection |
| `SwingKit` | all + macOS | local pkg | shared models, wire format, detector, flight model, coaching |

project is generated w/ [xcodegen](https://github.com/yonaskolb/XcodeGen) from `project.yml`. edit that, run `xcodegen`, dont hand edit the xcodeproj (gets overwritten).

## layout

```
project.yml            xcodegen spec
Apps/VisionOS/         vision pro app
Apps/iOS/              iphone app
Apps/Watch/            watch app
Packages/SwingKit/     shared pkg + tests (`swift test` on mac)
docs/                  this + assets list
```

## swingkit

- `SwingResult` swing summary, `tempoRatio` = backswing / downswing (target ~3)
- `MotionSample` one raw sample, accel in g, gyro in rad/s
- `SwingPhase` detector states
- `MessageEnvelope` versioned wrapper for everything on the wire (json, iso8601 dates). bump `currentVersion` on breaking changes

coming: swing detector (M4), ball flight model + `FlightTuning` (M2), coaching tips (M6)

## 3d content

xcode 27 visionOS template no longer makes a reality composer pro package, scenes load from the app bundle. M1 range is just primitives in code. real scene + assets in M2/M7, see `ASSETS.md`
