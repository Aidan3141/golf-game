# fake showcase recording (head + hands + club) wrapped around a real sim shot (ball flight),
# so the renderer can be built before theres real headset data. same json as the avp writes
# usage: python3 -I synth_shot.py sim_shot.json out.json
import json
import math
import sys

import numpy as np

src = json.load(open(sys.argv[1]))
fps = 90
pre = 4.0  # secs before launch

ball_frames = [f for f in src["frames"] if f.get("ball")]
ball0 = np.array(ball_frames[0]["ball"])
t_src0 = src["frames"][0]["t"] + src["launchT"]
# ball path by time since launch
bt = np.array([f["t"] - t_src0 for f in ball_frames])
bp = np.array([f["ball"] for f in ball_frames])
flight_secs = src["shot"]["flightSecs"]
total = pre + flight_secs + 2.0


def ball_at(s):
    if s <= 0:
        return ball0
    i = np.searchsorted(bt, s)
    if i >= len(bt):
        return bp[-1]
    return bp[i]


def norm(v):
    return v / np.linalg.norm(v)


def smooth(x):
    x = min(max(x, 0.0), 1.0)
    return x * x * (3 - 2 * x)


# golfer (righty, faces -z, target = -x)
C = np.array([0.0, 1.27, -0.02])  # swing center, between the shoulders
u = norm(ball0 - C)
v = norm(np.array([1.0, 0, 0]) - np.dot([1.0, 0, 0], u) * u)  # away from target
n = np.cross(u, v)
r = 0.56
L = np.linalg.norm(ball0 - C) - r - 0.01

back, down, thru = 0.95, 0.30, 0.55
start = pre - back - down  # takeaway
TOP = 2.35
FIN = -2.7


def swing(s):
    """hand angle, wrist hinge, phase at time s (0 = launch/impact)"""
    if s < -(back + down):
        return 0.0, 0.0, "address"
    if s < -down:
        x = (s + back + down) / back
        th = TOP * smooth(x)
        hinge = 1.45 * smooth(min(x * 1.4, 1))
        return th, hinge, "backswing"
    if s < 0:
        x = (s + down) / down  # 0 at top -> 1 at impact
        th = TOP * (1 - x ** 1.8)
        hinge = 1.45 * (1 - x ** 3.5)  # late release
        return th, hinge, "downswing"
    if s < thru:
        x = s / thru
        th = FIN * (1 - (1 - x) ** 2)
        hinge = -1.1 * smooth(x)
        return th, hinge, "followThrough"
    # hold the finish, then relax a bit
    x = smooth((s - thru - 2.5) / 1.5)
    return FIN * (1 - 0.35 * x), -1.1 * (1 - 0.5 * x), "idle"


def look_rot(fwd, up=np.array([0, 1.0, 0])):
    # device: -z forward, +y up -> quaternion xyzw
    z = -norm(fwd)
    x = norm(np.cross(up, z))
    y = np.cross(z, x)
    m = np.stack([x, y, z], axis=1)
    tr = m.trace()
    if tr > 0:
        S = math.sqrt(tr + 1) * 2
        w = 0.25 * S
        qx = (m[2, 1] - m[1, 2]) / S
        qy = (m[0, 2] - m[2, 0]) / S
        qz = (m[1, 0] - m[0, 1]) / S
    else:
        i = int(np.argmax(np.diag(m)))
        j, k = (i + 1) % 3, (i + 2) % 3
        S = math.sqrt(1 + m[i, i] - m[j, j] - m[k, k]) * 2
        q = [0, 0, 0]
        q[i] = 0.25 * S
        q[j] = (m[j, i] + m[i, j]) / S
        q[k] = (m[k, i] + m[i, k]) / S
        w = (m[k, j] - m[j, k]) / S
        qx, qy, qz = q
    return [qx, qy, qz, w]


def hand_joints(center, shaft, palm_n, toward_arm):
    """27 joints in avp order around a grip"""
    side = norm(np.cross(shaft, palm_n))
    wrist = center + 0.075 * toward_arm
    out = {"wrist": wrist, "forearmWrist": wrist, "forearmArm": wrist + 0.13 * toward_arm}
    fingers = ["thumb", "indexFinger", "middleFinger", "ringFinger", "littleFinger"]
    for i, f in enumerate(fingers):
        along = (i - 2) * 0.021  # spread down the shaft
        base = center + along * shaft
        if f == "thumb":
            out["thumbKnuckle"] = center + 0.035 * toward_arm + 0.02 * side
            out["thumbIntermediateBase"] = center + 0.015 * toward_arm + 0.03 * side
            out["thumbIntermediateTip"] = center - 0.005 * toward_arm + 0.035 * side + 0.02 * shaft
            out["thumbTip"] = center - 0.02 * toward_arm + 0.03 * side + 0.035 * shaft
            continue
        meta = base + 0.04 * toward_arm
        knuckle = base
        # curl around the grip
        ib = base - 0.02 * toward_arm - 0.015 * palm_n
        it = base - 0.02 * toward_arm - 0.035 * palm_n - 0.012 * side
        tip = base - 0.005 * toward_arm - 0.04 * palm_n - 0.025 * side
        out[f + "Metacarpal"] = meta
        out[f + "Knuckle"] = knuckle
        out[f + "IntermediateBase"] = ib
        out[f + "IntermediateTip"] = it
        out[f + "Tip"] = tip
    return out


names = src["joints"]
frames = []
head0 = np.array([0.02, 1.52, 0.04])
for k in range(int(total * fps)):
    t = k / fps
    s = t - pre
    th, hinge, phase = swing(s)
    hands = C + r * (math.cos(th) * u + math.sin(th) * v)
    ph = th + hinge
    d = math.cos(ph) * u + math.sin(ph) * v
    grip = hands
    club = hands + L * d
    # shoulders turn w/ the hands, arms point from hand back toward the lead shoulder
    turn = 0.75 * th
    sh_axis = np.array([math.cos(turn), 0, math.sin(turn)])
    lead_sh = C - 0.19 * sh_axis + np.array([0, 0.12, 0])
    trail_sh = C + 0.19 * sh_axis + np.array([0, 0.12, 0])
    # palm faces: lead palm faces away from target-ish (plane normal), trail opposite
    lead_c = grip - 0.015 * d
    trail_c = grip + 0.075 * d
    lead = hand_joints(lead_c, d, n, norm(lead_sh - lead_c))
    trail = hand_joints(trail_c, d, -n, norm(trail_sh - trail_c))
    # head: steady, turns to watch the ball after impact
    if s < 0.15:
        look = ball0 - head0
        head = head0.copy()
    else:
        x = smooth((s - 0.15) / 0.6)
        b = ball_at(s)
        look = (1 - x) * (ball0 - head0) + x * norm(b - head0) * 5
        head = head0 + np.array([-0.06, 0.07, 0.02]) * x
    f = {
        "t": round(t, 4),
        "head": [*map(float, head), *look_rot(look)],
        "left": [float(c) for nm in names for c in lead[nm]],
        "right": [float(c) for nm in names for c in trail[nm]],
        "grip": [*map(float, grip)],
        "club": [*map(float, club)],
        "ball": [*map(float, ball_at(s))],
        "watch": float(ph),
        "phase": phase,
    }
    frames.append(f)

out = dict(src)
out["frames"] = frames
out["launchT"] = pre
out["shot"] = dict(src["shot"], tempo=back / down, backswing=back, downswing=down, live=True)
json.dump(out, open(sys.argv[2], "w"))
print(len(frames), "frames", round(total, 1), "s")
