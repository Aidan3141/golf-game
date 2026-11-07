#!/bin/zsh
# whole showcase from one recorded shot: headset pov -> 3rd person -> impact slo mo
# -> flight -> the shot, w/ music + game sounds. no title/end cards (--card still works if u want them)
# usage: tools/showcase/make_video.sh shot.json out_dir
set -e
here=${0:A:h}
repo=${here:h:h}
rec=${1:?shot json}
out=${2:-$here/out}
mkdir -p $out
cd $here
swift build -c release 2>&1 | grep -E 'error|Build comp' || true
bin=$here/.build/release/ShowcaseRender
res=$repo/Apps/VisionOS/Resources
title=0

$bin --rec $rec --assets $res --out $out/video.mp4 --cues $out/cues.json | tail -1
total=$(ffprobe -v error -show_entries format=duration -of csv=p=0 $out/video.mp4)
python3 -I $here/make_audio.py $out/cues.json $total $title $res/Sounds $out/audio_raw.wav
ffmpeg -loglevel error -y -i $out/audio_raw.wav -af loudnorm=I=-16:TP=-1.5:LRA=11 -ar 48000 $out/audio.wav
# full quality + a small one (github uploads cap at 10MB)
ffmpeg -loglevel error -y -i $out/video.mp4 -i $out/audio.wav -c:v copy -c:a aac -b:a 192k -shortest -movflags +faststart $out/showcase.mp4
kbps=$(python3 -c "print(int(9.0*8*1024/$total - 160))")
ffmpeg -loglevel error -y -i $out/video.mp4 -i $out/audio.wav -vf scale=1920:1080 -r 30 -c:v libx264 -preset slow -b:v ${kbps}k -maxrate $((kbps*2))k -bufsize $((kbps*2))k -c:a aac -b:a 128k -shortest -movflags +faststart $out/showcase_small.mp4
ls -lh $out/showcase.mp4 $out/showcase_small.mp4
