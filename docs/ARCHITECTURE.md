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
- live club (v2 wire format): watch sends `ClubSample` = angle along the swing axis (`SwingAngleTracker`, from the address pose, body frame so facing doesnt matter) + angular velocity (`AngleRateTracker`, 30ms finite diff) + phase + sample time. offered at 60hz
  - transport 1, bluetooth fast lane (preferred): phone = ble peripheral (`PhoneBLELink`, asks for the low latency connection interval), watch = central (`WatchBLELink`). 18 byte `ClubPacket`s, write w/o response so no queue builds (newest wins). ping/pong packets for clock sync. the headset + watch are BOTH central only (checked in the sdk: `CBPeripheralManager` is unavailable on visionos + watchos) so watch -> headset direct isnt possible
  - transport 2, watchconnectivity fallback: ack gated `sendMessage` (only one in flight, skip while waiting) bc fire n forget at 25hz backed up + played ~90s late. the phones reply carries its uptime so every msg is also a clock sync round trip. 2s pings keep sync warm before the first swing
  - clocks: `ClockOffsetEstimator` (ntp style, keeps the min round trip sample). watch -> phone offset on the watch, phone -> headset offset on the phone (tcp `clockPing`/`clockPong`). sample + impact times get converted hop by hop so on the headset theyre in its own uptime clock = real ages
  - headset: `LiveClub` dead reckons: draws angle + omega x (now + display lead - sample time), capped at 250ms / 1.6 rad. `LiveClubSystem` smooths the step when a new sample corrects it (~25ms). mapped to the lever: x1.45 backswing side, x2.6 follow thru side. samples >0.5s old get dropped
  - stats on all 3 screens: watch link + rate + sync, phone per link rate + age, headset rate + age + stale
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
- `RangeScene` builds the range in code. sky = kloppenheim 06 pure sky (poly haven, golden hour, NO ground) on a big inside out sphere + the matching 2k hdr as image based light, both turned by `skyYaw` so the low sun sits just right of the target line. flat grass runs out from the tee (custom disc/ring mesh w/ tangents so the normal map works): opaque to 300m then rings fade it out by 1500m into the skys hazy lower half. mowed fairway stripes, tee box, staggered flags 50-250 yd w/ target greens + billboard labels. (tried sunset fairway, a 360 photo w/ its own ground, but its hills didnt match a flat range + flags floated)
- `ClubRig` + `ClubSwingSystem` ghost club next to the ball. one rigid lever rotating in a tilted swing plane, timed by the swings backswing/downswing durations (so tempo shows), swing length from wrist speed, plane tilts a bit w/ pathBias. launches the ball at impact
- `BallFlightSystem` ecs system, plays a precomputed flight on the ball. grows the ball w/ distance so u can see it, drops trail segments, carry + rest markers

debug launch args (Debug builds only): avp `-behind` behind ball view (sim cam looks down the target line), `-clubFirst` puts the club section on top. iphone `-autoTestSwing` sends a sample once connected (+ `-autoTestClub` streams a fake club swing first). avp `-autoShot` opens range + hits, `-hideWindow` closes the panel after, `-sideView` turns the world so the sim camera sees the arc, `-clubView` face-on look at the club, `-openRange` just opens it, `-raise` lifts the world so the sim cam sees the ball in first person

## watch app (M3)

- `WorkoutManager` (shared) runs an `HKWorkoutSession` (golf). `WatchAppDelegate.handleActiveWorkoutRecovery` reattaches to a live session if watchos relaunches us. only to keep the app alive + unlock batched sensors, no builder so nothing saved to health
- `MotionCapture` streams ONE `CMMotionManager` device motion source @ 100hz into ring buffers (~10s) + the detector + the club stream. (batched 800hz was dropped: running it next to the 100hz live stream killed it w/ CMError 109 on the ultra.) only writes observable state when it changes, setting it 100x/s froze the watch ui. record = 3-2-1 haptic countdown, 3s window, waits for the ~1s batch lag, slices by timestamp (secs since boot)
- live detection runs on that same 100hz stream (low latency, batched used to land ~1s late). light tap at address, strong at impact. each detected swing auto saves 2.5s before + 0.8s after impact as a recording (toggle)
- `WatchConnectivityManager` writes `SwingRecording` json + `transferFile`s it to the phone

## iphone app (M3)

- `PhoneConnectivity` gets files, moves them into Documents/Recordings before the delegate returns
- `RecordingStore` lists/loads/deletes them
- `RecordingDetailView` swift charts of accel + rotation (magnitude or x/y/z), reruns the detector and draws takeaway/top/impact lines + tempo, share button so recordings can be airdropped to the mac

## hand driven club

- `HandTracking` one service, 2 backends, only one runs at a time:
  - system predicted (default): realitykit `AnchorEntity(.hand(.left/.right, location: .palm), trackingMode: .predicted)`. the RENDERER moves anchored content to the hand pose predicted for display time, so our update loop adds no lag. a `SpatialTrackingSession` (`.hand`) lets us read those anchor transforms (calibration, contact, address check)
  - manual: arkit `handAnchors(at: now + lookahead)`. its docs want the compositor services `trackableAnchorTime` (photon time) which realitykit apps dont get, so we guess (default 60ms, was 25 = under predicting = lag). optional 1€ filter. diag: arkit update hz, data age (`HandAnchor.timestamp` vs `CACurrentMediaTime`, both mach seconds), fidelity
- `HandClub` lock (calibration): clasped hands hide the lead hand most frames (~16% seen on device) + ARKit sometimes flips a half hidden palm. so it collects every frame where both palms are seen + still (<6mm/frame) + together (<15cm), needs 8+ frames over 0.5s+ that agree within 12°, locks off the AVERAGE, rejects a lead palm facing the target (in a grip the back of the lead hand faces it), + only locks from a believable setup over the ball (grip 0.55-1.25m from the ball, 0.45-1.05 putter, 35cm+ above it, <90cm sideways) bc the lock assumes the clubhead is AT the ball. LOCKS ONCE, re-lock button to redo (relocking whenever hands were still + together, eg watching the ball, re-aimed the shaft at the ball from wherever ur hands were + stacked up shot after shot -> club on the back of the hand)
- the lock is the club pose (shaft grip -> ball, face -> target) in the lead palm frame. anchored: that local transform sits on a club thats a child of the lead palm anchor. manual: we place a world club from it every frame. wrist twist = club twist either way
- hybrid: if the lead hand drops out (top of backswing, blur at impact) a world "free" club takes the last pose + swings it around the watch lever axis by how much the dead reckoned watch angle moved. when the hand comes back the free club slides onto it over 80ms then the anchored one takes over. hands only = club hides when lost, watch = old lever club
- once locked + hands lost w/o watch motion: the club freezes where ur hands were (used to drop to the watch lever club sitting at the ball after 0.25s, looked like it snapped to the ball)
- contact launch: when the drawn clubhead crosses the ball plane heading at the target (within 15cm, >1.5 m/s, putter 8cm/0.15 m/s) after a real backstroke (head 15cm / putter 6cm behind the ball in the last 0.8s), speed averaged over 40ms (frame to frame speed turned jitter around a putter 3.6cm behind the ball into rockets), face angle capped ±20° / putter ±8° the ball launches right then off head speed + face angle (provisional). the watch swing that arrives inside 1.5s refines it: same shot id, `BallFlightComponent.retarget` blends onto the new path over 0.35s. putts keep the hand speed + just take the watch tempo for the card
- quick impact: the watch sends a 19 byte `ClubPacket.impact` over the ble fast lane the instant it detects impact -> phone -> `MessagePayload.quickImpact` -> the ball launches off it (provisional) if the hand club didnt already. the full swing over watchconnectivity (can take 1-2s) refines it inside a 3s window, w/ the hand face or else the watch wrist roll for curve
- no contact but a watch swing w/ an impact time: the ball starts `now - impact` (max 0.4s) into its flight so it lines up w/ when u actually hit it
- the hand club ticks off a dedicated always enabled `driver` entity (disabled entities may not get system updates)
- diag: window shows source (anchored/manual/fallback/frozen/none), calibrated, % of frames the lead hand was seen per watch phase (addr/back/down/thru, resets each address), contact speed. `SwingLogger` keeps ~8s of per frame data (source, hands seen, grip + head pos, raw vs predicted watch angle, sample age, phase) + ~1s after each swing writes the last 5s to Documents/SwingLogs (Files app + share buttons in the window), w/ the tuning settings
- everything tunable live in the window: club follows, hand mode, manual predict ahead + smoothing, watch prediction on/off + display lead

## coaching (M6)

- avp: `ShotCard` attachment pops up ~0.3s after the ball lands, on ur trail side so it doesnt block the flight. carry/total, tempo vs 3:1 bar, smoothness, curve, tip. window has a session summary + new session button
- iphone: every real swing saved w/ swiftdata (`SwingRecord`, flat fields). `HistoryView` = tempo over time chart w/ the 3:1 line, stats, per day list. carry there is a straight shot estimate (phone doesnt know the avp curve calibration)
- debug: iphone `-seedHistory` fake swings, `-openHistory` starts on history

## polish (M7/M8)

- `GameAudio` loads the synth wavs once. impact plays at the tee when the ball launches, landing thud is spatial at the landing spot (boosted, its far), wind + birds ambience loops all around
- `TempoTrainer` (avp, practice section): 3 ticks over ur backswing time then a tock 1 beat later = perfect 3:1, repeats w/ a 2s gap
- hands: both spaces use `upperLimbVisibility(.visible)`. w/ hand tracking on, once ur hands are good + still for 0.5s (+ not mid swing) `ClubRig.snapGrip` re aims the lever so the grip goes thru ur hands (pivot = hands + 0.38m further along ball->hands). re-snaps only if hands move >3cm
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
