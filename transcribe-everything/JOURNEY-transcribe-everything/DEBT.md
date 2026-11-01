# Debt

- Something on mac-work-2 periodically deletes files under build directories (overnight: built binaries
  and helper scripts; later: `NemoTextProcessing.xcframework/Info.plist` inside `.build/artifacts`).
  Symptom: "There is no Info.plist found at …xcframework". Fix each time: `rm -rf .build/artifacts`
  and rebuild. Cause not investigated (suspected demonlock).
