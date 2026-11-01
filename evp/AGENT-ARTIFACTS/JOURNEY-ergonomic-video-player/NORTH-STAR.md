# NORTH STAR: Ergonomic Video Player (`EVP`)

> "I'm quite unhappy with mac video players atm. i havent found something that just out of the box can easily..."
> "all of these players always have 1-2 things that are just annoying as shit"

Product name: **"Ergonomic Video Player"**. CLI: **`evp <path>`**. **`./install.sh` sets everything up** (his convention: "like the rest of my shit in ~/minh-qol-utilities": a tool folder with `install.sh`, `uninstall.sh`, `README.md`).

Design ethos (his words): "super vscode-like", **"extremely minimal and elegant design, not a software bloat. no reinvention of the wheel."**

Items marked SHINY are the make-or-break signals for closing the project.

## SHINY 1: Resume position, always
> "constantly fetch the last timestep i was on to save it as a bookmark whenever i reopen that video"
- Position is saved continuously (not only on quit), so a crash or force-quit loses at most about a second.
- Reopening a video seeks to that exact timestep.
- Added (his approval): a video you finished, or are within about 5 seconds of the end, reopens at 0.

## SHINY 2: VSCode-style reopen of everything
> "have clean reopen recent feature, a-la vscode. immediately opens all windows to exact timestep i was on."
> "i want this to be super vscode-like, opens all windows to exact video i was watching and the timestep i was on, theres an open recent menu."
- Launch restores every window that was open: same video, same timestep, same window frame.
- An **Open Recent** menu lists recent files.
- Open Recent entries show their timestamp (my proposal, accepted).

## SHINY 3: Decouple from media keys
> "decouple from back/forward/pause (F7, F8, F9) buttons if i turn on that option"
- A setting toggles the decoupling.
- With decoupling on, F7/F8/F9 never touch EVP, so other apps get them.
- With decoupling off, F7/F8/F9 control the frontmost-playing EVP video.

## SHINY 4: Player UI is off the video
> "i also want the player UI to be off of the video so mouse-over doesnt fucking obscure it."
- All controls live in a bar below the video. Nothing is ever drawn over the picture.
- No on-video OSD either (key feedback shows in the bar).

## SHINY 5: Resizes like any other Mac app
> "i should also be able to arbitrarily resize windows to whatever, and it does best-fit and black bars otherwise"
> "easily resizable like any other app on my mac, i maximize, left half, right half it, it just fucking works."
- Any window size, video letterboxed with black bars, no stretching.
- Maximize, left-half, right-half tiling all work.

## SHINY 6: Plays everything
> "support any video type" / "Supports all video types too (or wide majority, at least get mkv, mp4, mov, audio files too, webm)"
- mkv, mp4, mov, webm, and audio files are the floor; the engine (libmpv/ffmpeg) provides the rest.
- His question "ffmpeg probably we will use? idk": answered with libmpv, which wraps ffmpeg and is the player engine behind mpv and IINA. We do not write a player on raw ffmpeg.

## Keyboard (all rebindable)
> "also id like for left-right + J-L to be pm 5 seconds, pm 10s like on youtube (and pause/play state is whatever it was before), can be held down."
- Left/Right: minus/plus 5s. J/L: minus/plus 10s. Pause/play state is preserved. Holding repeats.
> "no fast forward/fast backward feature like double speed needed."
> "press d to increase speed by 10%, s to decrease speed by 10% and thats also an autosaved state."
> "up/down increase or decrease the volume, also an autosaved thing."
> "spacebar on it pause it obviously."
> "global pause of all videos with ctrl + space keybind"
> "and in settings also all keybinds like these adjustable"
> "OHHH and youtube's 0 through 9 thing": 0 to 9 jump to 0% to 90% of the video.

## Per-file state (his correction supersedes "global")
> "speed and volume not global."
- Position, speed, and volume are autosaved **per video file**.
- A never-opened file starts at 1.0x speed and 100% volume (defaults editable in Settings).

## Bottom bar (his words and accepted proposals)
- Time display `4:52 / 9:01`: "double click on timestamp probably highlights it first to copy then you can press delete". Double-click selects the whole field, typing or Delete replaces it, Enter seeks if the time is valid. Invalid input is rejected.
> "we'd support scrubbing, obviously?" A scrub bar spans the window width.
> "screenshot-to-clipboard button in the bottom bar". Clipboard only: "no shift feature for the screenshot needed".
> "just crowd it in the bottom bar? id be okay with that." Speed and seek buttons live in the bar.
- Audio-track and subtitle-track menus: "audio and subtitle track menus are good".
- Menu items: "one of the menu items is settings that toggles on/off the decoupling feature".
- Fullscreen: native macOS fullscreen. The bar stays below the video.

## Install and permissions
> "CLI access would also be awesome. evp <path>. ./install sets everything up"
> "could this work without sudo or any permissions btw, is this buildable?"
- Requirement: no sudo, no Accessibility or Input Monitoring permission.

## Explicitly NOT wanted
- Always on top ("no always on top").
- Global speed or volume.
- Shift-screenshot-to-file.
- Fast-forward or double-speed holds.
- Transcript or speech-to-text support ("no no dont worry about that").
- Reviews: not yet ("dont do reviews yet") for this planning pass.

## Principle constraints for this project
- Minimal, no bloat, no reinvented wheels: libmpv does all decode, render, seek, and track handling.
- Every constant from a measurement, spec, or his decision.
