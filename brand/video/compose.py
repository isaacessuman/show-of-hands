# Builds the Show of Hands explainer video from the clips in clips/ and caption overlays in caps/.
import subprocess, os
D = os.path.dirname(os.path.abspath(__file__))
C = lambda f: os.path.join(D, "clips", f)
X = 0.5  # crossfade seconds
# (name, file, trim start, duration, caption)
SCENES = [
    ("a", "a-hook.mp4", 0.0, 6.0, "a-hook"),
    ("b", "b-problem.mp4", 0.0, 5.0, "b-problem"),
    ("c", "c-seal.mp4", 0.0, 5.0, "c-seal"),
    ("h", "home.mp4", 0.0, 6.4, "home"),
    ("p", "poll.mp4", 0.0, 10.2, "poll"),
    ("r", "predict.mp4", 0.0, 10.0, "predict"),
    ("k", "check.mp4", 0.0, 9.6, "check"),
    ("l", "league.mp4", 0.0, 5.6, "league"),
    ("g", "agents.mp4", 0.0, 6.6, "agents"),
    ("d", "d-lights.mp4", 0.0, 6.0, "d-end"),
]
args, fil = ["ffmpeg", "-y", "-loglevel", "error"], []
for i, (n, f, ss, dur, cap) in enumerate(SCENES):
    args += ["-ss", str(ss), "-t", str(dur), "-i", C(f)]
    norm = "fps=30,format=yuv420p,setsar=1"
    if n == "c":  # square seal clip: paper background from its own plain corner, seal on the right with a feathered edge
        fil.append(f"[{i}:v]split[c1][c2];[c1]crop=360:202:20:20,scale=1920:1080,gblur=sigma=3[cbg];"
                   f"[c2]scale=1080:1080,format=yuva420p,geq=lum='lum(X,Y)':cb='cb(X,Y)':cr='cr(X,Y)':a='255*min(1,X/220)'[cfg];"
                   f"[cbg][cfg]overlay=840:0,{norm}[v{i}]")
    else:
        fil.append(f"[{i}:v]scale=1920:1080:force_original_aspect_ratio=increase:flags=lanczos,crop=1920:1080,{norm}[v{i}]")
# crossfade chain
starts, t, last = [0.0], SCENES[0][3], "v0"
for i in range(1, len(SCENES)):
    off = t - X
    fil.append(f"[{last}][v{i}]xfade=transition=fade:duration={X}:offset={off:.3f}[x{i}]")
    starts.append(off); t = off + SCENES[i][3]; last = f"x{i}"
total = t
# caption overlays
base = len(SCENES)
for j, (n, f, ss, dur, cap) in enumerate(SCENES):
    t0 = starts[j] + (0.3 if n in "ad" else 0.7); t1 = starts[j] + dur - (0.15 if n == "d" else 0.45)
    if n == "d": t0 = starts[j] + 1.0
    L = t1 - t0
    args += ["-loop", "1", "-t", f"{L:.3f}", "-i", os.path.join(D, "caps", cap + ".png")]
    fo = "" if n == "d" else f",fade=t=out:st={L-0.35:.3f}:d=0.35:alpha=1"
    fil.append(f"[{base+j}:v]format=rgba,fade=t=in:st=0:d=0.45:alpha=1{fo},setpts=PTS-STARTPTS+{t0:.3f}/TB[c{j}]")
    fil.append(f"[{last}][c{j}]overlay=0:0:eof_action=pass[o{j}]"); last = f"o{j}"
fil.append(f"[{last}]fade=t=in:st=0:d=0.6,fade=t=out:st={total-0.8:.3f}:d=0.8,format=yuv420p[vout]")
ai = base + len(SCENES)
args += ["-i", os.path.join(D, "clips", "music.mp3")]
fil.append(f"[{ai}:a]atrim=0:{total:.3f},afade=t=in:st=0:d=0.8,afade=t=out:st={total-3:.3f}:d=3,volume=0.9[aout]")
out = os.path.join(D, "show-of-hands-explainer-1080p.mp4")
args += ["-filter_complex", ";".join(fil), "-map", "[vout]", "-map", "[aout]", "-c:v", "libx264", "-preset", "slow", "-crf", "17",
         "-profile:v", "high", "-pix_fmt", "yuv420p", "-r", "30", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", out]
subprocess.run(args, check=True)
print("done", round(total, 2), "s ->", out)
for n, s in zip([s[0] for s in SCENES], starts): print(n, round(s, 2))
