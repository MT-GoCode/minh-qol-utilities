// Probe: Carbon global hotkey (ctrl+space) + MPRemoteCommandCenter media keys. arg1 = coupled|decoupled
import AppKit
import Carbon
import MediaPlayer
import AVFoundation

let mode = CommandLine.arguments[1]
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

var ref: EventHotKeyRef?
var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in print("HOTKEY ctrl+space"); fflush(stdout); return noErr }, 1, &spec, nil, nil)
let st = RegisterEventHotKey(49, UInt32(controlKey), EventHotKeyID(signature: 0x45565031, id: 1), GetApplicationEventTarget(), 0, &ref)
print("hotkey register status=\(st)"); fflush(stdout)

if mode == "coupled" {
    let c = MPRemoteCommandCenter.shared()
    for (name, cmd) in [("play", c.playCommand), ("pause", c.pauseCommand), ("toggle", c.togglePlayPauseCommand),
                        ("next", c.nextTrackCommand), ("prev", c.previousTrackCommand),
                        ("skipF", c.skipForwardCommand), ("skipB", c.skipBackwardCommand),
                        ("seekF", c.seekForwardCommand), ("seekB", c.seekBackwardCommand)] {
        cmd.isEnabled = true
        cmd.addTarget { _ in print("REMOTE \(name)"); fflush(stdout); return .success }
    }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: "probe", MPMediaItemPropertyPlaybackDuration: 20.0, MPNowPlayingInfoPropertyElapsedPlaybackTime: 1.0, MPNowPlayingInfoPropertyPlaybackRate: 1.0]
    MPNowPlayingInfoCenter.default().playbackState = .playing
}
var player: AVAudioPlayer?
if CommandLine.arguments.count > 2 {
    player = try! AVAudioPlayer(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
    player!.volume = 0.03; player!.numberOfLoops = -1; player!.play()
    print("audio playing=\(player!.isPlaying)"); fflush(stdout)
}
Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
    MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: "probe2", MPNowPlayingInfoPropertyPlaybackRate: 1.0, MPNowPlayingInfoPropertyElapsedPlaybackTime: 2.0]
    MPNowPlayingInfoCenter.default().playbackState = .playing
    print("republished"); fflush(stdout)
}
Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { _ in print("exit"); exit(0) }
app.run()
