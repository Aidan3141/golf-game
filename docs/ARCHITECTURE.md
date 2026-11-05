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
- iphone → vision pro: Network framework (NWListener on avp, NWBrowser on phone, bonjour `_golfgame._tcp`) w/ `includePeerToPeer` so it rides awdl and works w/o a shared wifi (campus wifi blocks bonjour). picked over multipeer bc its the modern api, plays nicer w/ swift 6, and does the same peer to peer trick. avp side is just a `SwingSource`, so swapping transports only touches `NetworkSwingReceiver` / `NetworkSwingSender`
- wire format: `MessageFramer` = 4 byte big endian length + json `MessageEnvelope`. `FrameDecoder` reassembles from a tcp byte stream. phone sends `hello` on connect + `ping` every 2s
- watch → phone: `sendMessage(["env": envelope])` when reachable, `transferUserInfo` as backup. sent the instant impact is detected, raw data follows separately
- live club: watch streams `club(angle, phase)` ~25hz while addressed/swinging (sendMessage, fire n forget), phone forwards, avp `LiveClubSystem` follows it w/ light smoothing. angle = rotation from the address pose along the swing axis (`SwingAngleTracker`, body frame so facing doesnt matter). mapped to the lever: x1.45 on the backswing side, x2.6 on the follow thru side
- phone relay only runs w/ the app open (idle timer off). background relay = later maybe

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

- `SwingDetector` (M4) feed it motion frames at any rate. works on rotation magnitude so wrist/hand dont matter. idle -> address (still 0.5s) -> backswing -> impact (peak >= 9 rad/s, confirmed once it drops) -> follow thru (1.2s refractory). at impact it looks back in a 4s buffer: top = slowest point 0.1-0.8s before impact, backswing hump before that, takeaway = where it was last still. rejects no backswing / no clear top / weird timing. all knobs in `SwingDetectorConfig`, tuned on 10 real swings in `Tests/SwingKitTests/Fixtures` (803hz accel / 201hz motion, ultra 4 left wrist)
- `faceAngle` = forearm roll at impact vs address (watch x axis w/ the swing axis projected out), degrees. avp maps it to pathBias: roll / 15deg x strength, w/ a flip toggle bc we dont know yet which sign is open
- smoothness = backswing jitter (raw vs 80ms avg) / hump speed. pathBias is 0 for now, no reliable signal yet

- `Coach.tip(for:flight:)` one plain english tip per shot, worst problem first: tempo (outside 2.6-3.4) > jerky takeaway > slice/hook (>12 yd offline, by hand) > low speed > pure/solid
- `SessionStats` avg tempo, tempo std dev (+ words for it), avg/best carry, avg smoothness

## vision pro app

- `AppModel` holds range state, test swing sliders, last `Shot`. listens to a `SwingSource`
- `SwingSource` protocol. `MockSwingSource` feeds swings from the sliders, `NetworkSwingReceiver` from the phone. live (network) shots launch the ball right away + the club just does the follow thru, slider shots replay the whole swing
- view modes: first person (default) turns + slides the world so the club pivot is where u stand, ball in front, target to ur lead side. behind ball = old layout
- `RangeScene` builds the range in code: sky sphere (8k jpg, inside out) + image based light from hdr, tinted grass w/ mowed stripes, tee box, staggered flags 50-250 yd w/ billboard labels
- `ClubRig` + `ClubSwingSystem` ghost club next to the ball. one rigid lever rotating in a tilted swing plane, timed by the swings backswing/downswing durations (so tempo shows), swing length from wrist speed, plane tilts a bit w/ pathBias. launches the ball at impact
- `BallFlightSystem` ecs system, plays a precomputed flight on the ball. grows the ball w/ distance so u can see it, drops trail segments, carry + rest markers

debug launch args (Debug builds only): iphone `-autoTestSwing` sends a sample once connected (+ `-autoTestClub` streams a fake club swing first). avp `-autoShot` opens range + hits, `-hideWindow` closes the panel after, `-sideView` turns the world so the sim camera sees the arc, `-clubView` face-on look at the club, `-openRange` just opens it, `-raise` lifts the world so the sim cam sees the ball in first person

## watch app (M3)

- `WorkoutManager` runs an `HKWorkoutSession` (golf). only to keep the app alive + unlock batched sensors, no builder so nothing saved to health
- `MotionCapture` streams `CMBatchedSensorManager` accel + device motion into ring buffers (~10s). falls back to `CMMotionManager` @ 100hz if batched isnt supported. record = 3-2-1 haptic countdown, 3s window, waits for the ~1s batch lag, slices by timestamp (secs since boot)
- live detection runs on a separate 100hz `CMMotionManager` stream (batched lands ~1s late, too laggy for the impact tap). light tap at address, strong at impact. each detected swing auto saves 2.5s before + 0.8s after impact as a recording (toggle)
- `WatchConnectivityManager` writes `SwingRecording` json + `transferFile`s it to the phone

## iphone app (M3)

- `PhoneConnectivity` gets files, moves them into Documents/Recordings before the delegate returns
- `RecordingStore` lists/loads/deletes them
- `RecordingDetailView` swift charts of accel + rotation (magnitude or x/y/z), reruns the detector and draws takeaway/top/impact lines + tempo, share button so recordings can be airdropped to the mac

## coaching (M6)

- avp: `ShotCard` attachment pops up ~0.3s after the ball lands, on ur trail side so it doesnt block the flight. carry/total, tempo vs 3:1 bar, smoothness, curve, tip. window has a session summary + new session button
- iphone: every real swing saved w/ swiftdata (`SwingRecord`, flat fields). `HistoryView` = tempo over time chart w/ the 3:1 line, stats, per day list. carry there is a straight shot estimate (phone doesnt know the avp curve calibration)
- debug: iphone `-seedHistory` fake swings, `-openHistory` starts on history

## polish (M7/M8)

- `GameAudio` loads the synth wavs once. impact plays at the tee when the ball launches, landing thud is spatial at the landing spot (boosted, its far), wind + birds ambience loops all around
- `TempoTrainer` (avp, practice section): 3 ticks over ur backswing time then a tock 1 beat later = perfect 3:1, repeats w/ a 2s gap
- `AddressCheck` (avp, toggle, off by default): arkit `HandTrackingProvider`, only checks wrists at address: together (<12cm), height 0.55-1.15m, roughly in front of u. never tracks the fast swing. not testable in the sim
- watch: impact tap is a double "success" when tempo is in the zone, plain strong tap otherwise. optional "tempo taps" plays the same 3:1 rhythm as haptics right after address

## putting green (M8)

- separate `ImmersiveSpace` (mixed), green sits on ur real floor (space origin = ur feet). only one space open at a time, window switches between range + green
- `PuttingScene` same trick as first person range: laid out w/ target = -z, then turned so the putter pivot is where u stand. cup w/ white liner, flagstick, fringe. `ClubRig` has a putter variant (closer pivot, blade head)
- `PuttSimulator` (swingkit, tested): 2d roll w/ friction (~stimp 10) + slope pull, drops if it crosses the cup under 1.3 m/s, lips out if faster. stroke speed = wrist rad/s x 0.6, aim from faceAngle (same flip/strength calibration as full swings)
- mode: avp sends `mode(.putt/.full)` back over the same tcp link when spaces change, phone forwards to the watch w/ `updateApplicationContext` (+ sendMessage if up). watch swaps to `SwingDetectorConfig.putting` (GUESSED thresholds, no recorded putts yet) + 2:1 tempo goal. watch also has a manual picker
- `Coach.puttTip` goal tempo 2:1
- debug: `-openGreen` (+ `-autoPutt`, `-raise`)

## 3d content

xcode 27 visionOS template no longer makes a reality composer pro package, so the range is built in code from primitives + textures in `Apps/VisionOS/Resources`. see `ASSETS.md`
