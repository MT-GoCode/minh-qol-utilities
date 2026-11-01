# transcribe-everything

Live captions of any app and the microphone, on this Mac. Parakeet Ultra runs on the Neural Engine; nothing leaves the machine.
A menu-bar app: the icon is yellow while the engine starts and green when it is ready.

## Install
    ./install.sh        # models, signed app in ~/Applications, LaunchAgent that starts it at login. No sudo.
Needs a "Developer ID Application" certificate in the login keychain (a changed signature resets permission grants).
Grant Microphone and Screen Recording when asked; the menu names what is missing, and a grant applies after relaunch.

## Use
- Menu ▸ Attach to Apps ▸ a window (its whole app is captured), or Microphone. Each source is its own stream.
- Captions appear over your screen; the bar moves them (⠿), expands to the last minute (⌃), hides them (eye). Text can be selected and copied.
- Transcripts: `~/.transcribe-everything/transcripts/<start time>.jsonl`, one JSON line per caption line.
- Settings: `~/.transcribe-everything/config.json`, applied as soon as you save. The font size is also a slider in the menu.
- Capture needs the display awake: when it sleeps, sources end with the reason and you attach them again.

## Uninstall
    ./uninstall.sh            # keeps ~/.transcribe-everything
    ./uninstall.sh --purge    # also deletes it

## Tests
    ./test-setup.sh           # once: fixtures and the reference transcripts
    ./test.sh [filter]        # the whole suite; results in test-results/<time>/
Some tests launch the installed app, mute the output briefly, and restart the LaunchAgent.
