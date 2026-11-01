# Debt

- Something on mac-work-2 periodically deletes files under build directories (overnight: built binaries
  and helper scripts; later: `NemoTextProcessing.xcframework/Info.plist` inside `.build/artifacts`).
  Symptom: "There is no Info.plist found at …xcframework". Fix each time: `rm -rf .build/artifacts`
  and rebuild. Cause not investigated (suspected demonlock).

- `SourcePipeline.swift`'s force-cut window is a literal 2 s while `speakerWindow` is configurable. Below 2 s, a window with a pre-cut midpoint could label the first word of a force-cut segment. Needs a non-default setting; found in the End-of-Period review, round 2.
- Mic first start: the 5 s stall grace rests on evidence that fits (two stalls at load 20, restarts clean at 0.106 s) but the first-start delay was not measured directly.
- Capture tests that play through QuickTime can be paused from outside the test (seen with AirPods as the output device, cause not proven). The test now reports that instead of missing words.
