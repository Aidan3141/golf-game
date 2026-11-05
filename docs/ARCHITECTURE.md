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

- `FlightTuning` every flight knob in one struct (physics, swing->launch mapping, bounce/roll)
- `LaunchConditions(swing:)` game-y mapping: wrist speed -> ball speed, tempo off 3:1 -> more curve, low smoothness -> less distance + seeded random spread, pathBias -> slice/hook
- `FlightSimulator.simulate` steps gravity + drag + spin lift/curve at 240hz, then bounce + roll. returns points + carry/total/offline/apex. pure + deterministic so its unit tested

coords in swingkit: x right of target, y up, z downrange (meters). vision app maps to realitykit w/ downrange = -z

coming: swing detector (M4), coaching tips (M6)

## vision pro app

- `AppModel` holds range state, test swing sliders, last `Shot`. listens to a `SwingSource`
- `SwingSource` protocol, `MockSwingSource` feeds swings from the sliders. real network source plugs in here in M5
- `RangeScene` builds the range in code: sky sphere (8k jpg, inside out) + image based light from hdr, tinted grass w/ mowed stripes, tee box, staggered flags 50-250 yd w/ billboard labels
- `ClubRig` + `ClubSwingSystem` ghost club next to the ball. one rigid lever rotating in a tilted swing plane, timed by the swings backswing/downswing durations (so tempo shows), swing length from wrist speed, plane tilts a bit w/ pathBias. launches the ball at impact
- `BallFlightSystem` ecs system, plays a precomputed flight on the ball. grows the ball w/ distance so u can see it, drops trail segments, carry + rest markers

debug launch args (Debug builds only): `-autoShot` opens range + hits, `-hideWindow` closes the panel after, `-sideView` turns the world so the sim camera sees the arc, `-clubView` face-on look at the club

## 3d content

xcode 27 visionOS template no longer makes a reality composer pro package, so the range is built in code from primitives + textures in `Apps/VisionOS/Resources`. see `ASSETS.md`
