// Spike benchmarks; no TCC needed (file input only).
//   Bench latency <wav> <out.json>        Ultra decode latency per segment length + memory
//   Bench embed <embed-dir> <out.json>    CAM++ and WeSpeaker embeddings per clip, cropped to several lengths
import FluidAudio
import Foundation

func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    precondition(kr == KERN_SUCCESS)
    return Double(info.phys_footprint) / 1_048_576
}

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

func write(_ obj: Any, _ path: String) {
    let d = try! JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    try! d.write(to: URL(fileURLWithPath: path))
}

let SR = 16000
let args = CommandLine.arguments

switch args[1] {
case "latency":
    let audio = try AudioConverter().resampleAudioFile(URL(fileURLWithPath: args[2]))
    let base = footprintMB()
    var t = now()
    let models = try await AsrModels.downloadAndLoad(version: .ultra)
    let asr = AsrManager(config: .default)
    try await asr.loadModels(models)
    let loadS = now() - t
    let layers = await asr.decoderLayerCount
    var rows: [[String: Any]] = []
    for secs in [0.5, 1, 2, 3, 4, 6, 8, 10, 12] {
        let seg = Array(audio[0..<Int(secs * Double(SR))])
        var ms: [Double] = []
        var text = ""
        for i in 0..<9 {  // first run per length is warmup, excluded
            var state = TdtDecoderState.make(decoderLayers: layers)
            t = now()
            let r = try await asr.transcribe(seg, decoderState: &state)
            if i > 0 { ms.append((now() - t) * 1000) }
            text = r.text
        }
        ms.sort()
        rows.append(["seconds": secs, "median_ms": ms[ms.count / 2], "max_ms": ms.last!, "text": text])
        print(String(format: "%5.1fs  median %6.1f ms  max %6.1f ms  %@", secs, ms[ms.count / 2], ms.last!, text))
    }
    write(["load_seconds": loadS, "footprint_mb_before": base, "footprint_mb_after": footprintMB(), "rows": rows],
          args[3])

case "embed":
    let camp = try await CampPlusEmbedder.load()
    let diar = DiarizerManager()
    diar.initialize(models: try await DiarizerModels.downloadIfNeeded())
    let root = URL(fileURLWithPath: args[2])
    let conv = AudioConverter()
    var rows: [[String: Any]] = []
    var timing: [String: [Double]] = ["campplus": [], "wespeaker": []]
    for spk in try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() where !spk.hasPrefix(".") {
        for clip in try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(spk).path).sorted()
        where clip.hasSuffix(".wav") {
            let audio = try conv.resampleAudioFile(root.appendingPathComponent(spk).appendingPathComponent(clip))
            let lengths = args.count > 4 && args[4] == "full" ? [Double(audio.count) / Double(SR)]
                                                              : [1.0, 1.5, 2.0, 3.0, 5.0]
            for secs in lengths where audio.count >= Int(secs * Double(SR)) {
                let seg = Array(audio[0..<Int(secs * Double(SR))])
                var t = now()
                let c = try await camp.embed(audio: seg)
                timing["campplus"]!.append((now() - t) * 1000)
                t = now()
                let w = try diar.extractSpeakerEmbedding(from: seg)
                timing["wespeaker"]!.append((now() - t) * 1000)
                rows.append(["speaker": spk, "clip": clip, "seconds": secs, "campplus": c, "wespeaker": w])
            }
        }
        print("embedded \(spk)")
    }
    let med = timing.mapValues { $0.sorted()[$0.count / 2] }
    print("median embed ms: \(med)")
    write(["median_ms": med, "rows": rows], args[3])

case "vad":
    // Bench vad <wav> : streaming VAD events for several minSilenceDuration values
    let audio = try AudioConverter().resampleAudioFile(URL(fileURLWithPath: args[2]))
    let vad = try await VadManager()
    for minSil in [0.25, 0.5, 0.75] {
        let cfg = VadSegmentationConfig(minSilenceDuration: minSil)
        var st = vad.makeStreamState()
        var ev: [String] = []
        var i = 0
        while i + VadManager.chunkSize <= audio.count {
            let r = try await vad.processStreamingChunk(Array(audio[i..<i + VadManager.chunkSize]), state: st,
                                                        config: cfg, returnSeconds: true)
            st = r.state
            if let e = r.event {
                // reported time (backdated by the VAD) / detection time (when the event actually fired)
                ev.append(String(format: "%@%.3f/%.3f", e.isStart ? "+" : "-", Double(e.sampleIndex) / Double(SR),
                                 Double(st.processedSamples) / Double(SR)))
            }
            i += VadManager.chunkSize
        }
        print("minSilence \(minSil): \(ev.count / 2) segments  \(ev.joined(separator: " "))")
    }

case "prefix":
    // Bench prefix <conversation.wav> <truth.json> : first non-empty decode of each turn's growing prefix
    let audio = try AudioConverter().resampleAudioFile(URL(fileURLWithPath: args[2]))
    let truth = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[3]))) as! [[String: Any]]
    let asr = AsrManager(config: .default)
    try await asr.loadModels(try await AsrModels.downloadAndLoad(version: .ultra))
    let layers = await asr.decoderLayerCount
    for (i, t) in truth.enumerated() {
        let s0 = Int((t["start"] as! Double) * Double(SR))
        var n = 1
        while true {
            // FluidAudio rejects < 0.3 s; pad short prefixes with silence like the pipeline will.
            var seg = Array(audio[s0..<s0 + n * VadManager.chunkSize])
            seg += [Float](repeating: 0, count: max(0, 4800 - seg.count))
            var state = TdtDecoderState.make(decoderLayers: layers)
            let r = try await asr.transcribe(seg, decoderState: &state)
            if !r.text.trimmingCharacters(in: .whitespaces).isEmpty {
                print(String(format: "turn %2d first-text after %.3f s of clip: %@", i,
                             Double(n * VadManager.chunkSize) / Double(SR), r.text))
                break
            }
            n += 1
        }
    }

case "live":
    // Bench live <wav> : stream-grid first-text latency. VAD per chunk (minSilence 0.5); on a start event
    // open a segment at the backdated start; every chunk while open, decode it; record the stream time of
    // the first non-empty text per segment and of each segment end detection.
    let audio = try AudioConverter().resampleAudioFile(URL(fileURLWithPath: args[2]))
    let vad = try await VadManager()
    let asr = AsrManager(config: .default)
    try await asr.loadModels(try await AsrModels.downloadAndLoad(version: .ultra))
    let layers = await asr.decoderLayerCount
    var st = vad.makeStreamState()
    var open: Int? = nil
    var gotText = false
    var i = 0
    while i + VadManager.chunkSize <= audio.count {
        let r = try await vad.processStreamingChunk(Array(audio[i..<i + VadManager.chunkSize]), state: st,
                                                    config: VadSegmentationConfig(minSilenceDuration: 0.5))
        st = r.state
        let now = Double(st.processedSamples) / Double(SR)
        if let e = r.event, e.isStart { open = e.sampleIndex; gotText = false; print(String(format: "start reported %.3f detected %.3f", Double(e.sampleIndex) / Double(SR), now)) }
        if let s0 = open, !gotText {
            var seg = Array(audio[s0..<st.processedSamples])
            seg += [Float](repeating: 0, count: max(0, 4800 - seg.count))
            var ds = TdtDecoderState.make(decoderLayers: layers)
            let t0 = DispatchTime.now().uptimeNanoseconds
            let tr = try await asr.transcribe(seg, decoderState: &ds)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            if !tr.text.trimmingCharacters(in: .whitespaces).isEmpty {
                gotText = true
                print(String(format: "  first text at stream %.3f (+%.0f ms decode): %@", now, ms, tr.text))
            }
        }
        if let e = r.event, e.isEnd { open = nil; print(String(format: "end detected %.3f", now)) }
        i += VadManager.chunkSize
    }

case "cut":
    // Bench cut <wav> <out.json> : the planned segmenter (minSilence 0.5, force-cut at 12 s at the lowest-probability
    // chunk of the last 2 s, end-of-stream flush); decodes every line, plus the whole file for a baseline.
    let audio = try AudioConverter().resampleAudioFile(URL(fileURLWithPath: args[2]))
    let vad = try await VadManager()
    let asr = AsrManager(config: .default)
    try await asr.loadModels(try await AsrModels.downloadAndLoad(version: .ultra))
    let layers = await asr.decoderLayerCount
    func decode(_ a: ArraySlice<Float>) async throws -> String {
        var seg = Array(a)
        seg += [Float](repeating: 0, count: max(0, 4800 - seg.count))
        var ds = TdtDecoderState.make(decoderLayers: layers)
        return try await asr.transcribe(seg, decoderState: &ds).text
    }
    var st = vad.makeStreamState()
    var open: Int? = nil
    var probs: [(end: Int, p: Float)] = []
    var lines: [[String: Any]] = []
    func commit(_ s: Int, _ e: Int, _ why: String) async throws {
        let text = try await decode(audio[s..<e])
        lines.append(["start": Double(s) / Double(SR), "end": Double(e) / Double(SR), "why": why, "text": text])
        print(String(format: "%7.3f %7.3f %@ %@", Double(s) / Double(SR), Double(e) / Double(SR), why, text))
    }
    var i = 0
    while i + VadManager.chunkSize <= audio.count {
        let r = try await vad.processStreamingChunk(Array(audio[i..<i + VadManager.chunkSize]), state: st,
                                                    config: VadSegmentationConfig(minSilenceDuration: 0.5))
        st = r.state
        i += VadManager.chunkSize
        if let e = r.event, e.isStart { open = e.sampleIndex; probs = [] }
        if open != nil { probs.append((i, r.probability)) }
        if let e = r.event, e.isEnd, let s = open { try await commit(s, max(e.sampleIndex, s + 1), "end"); open = nil; continue }
        if let s = open, i - s >= 12 * SR {
            let cut = probs.filter { $0.end >= i - 2 * SR }.min { $0.p < $1.p }!.end
            try await commit(s, cut, "cut")
            open = cut
            probs = probs.filter { $0.end > cut }
        }
    }
    if let s = open { try await commit(s, audio.count, "flush") }
    let whole = try await decode(audio[...])
    print("WHOLE \(whole)")
    write(["lines": lines, "whole": whole], args[3])

case "diar":
    // Bench diar <wav> <seconds> <out.json> [minSilence] : the planned segmenter on real audio; one WeSpeaker embedding per segment.
    let diarMinSilence = args.count > 5 ? Double(args[5])! : 0.5
    let audio = Array(try AudioConverter().resampleAudioFile(URL(fileURLWithPath: args[2])).prefix(Int(args[3])! * SR))
    let vad = try await VadManager()
    let diar = DiarizerManager()
    diar.initialize(models: try await DiarizerModels.downloadIfNeeded())
    var st = vad.makeStreamState()
    var open: Int? = nil
    var probs: [(end: Int, p: Float)] = []
    var lines: [[String: Any]] = []
    func commit(_ s: Int, _ e: Int, _ why: String) throws {
        let secs = Double(e - s) / Double(SR)
        var row: [String: Any] = ["start": Double(s) / Double(SR), "end": Double(e) / Double(SR), "why": why]
        if secs >= 1.0 { row["emb"] = try diar.extractSpeakerEmbedding(from: Array(audio[s..<e])) }
        lines.append(row)
    }
    var i = 0
    while i + VadManager.chunkSize <= audio.count {
        let r = try await vad.processStreamingChunk(Array(audio[i..<i + VadManager.chunkSize]), state: st,
                                                    config: VadSegmentationConfig(minSilenceDuration: diarMinSilence))
        st = r.state
        i += VadManager.chunkSize
        if let e = r.event, e.isStart { open = e.sampleIndex; probs = [] }
        if open != nil { probs.append((i, r.probability)) }
        if let e = r.event, e.isEnd, let s = open { try commit(s, max(e.sampleIndex, s + 1), "end"); open = nil; continue }
        if let s = open, i - s >= 12 * SR {
            let cut = probs.filter { $0.end >= i - 2 * SR }.min { $0.p < $1.p }!.end
            try commit(s, cut, "cut")
            open = cut
            probs = probs.filter { $0.end > cut }
        }
    }
    if let s = open { try commit(s, audio.count, "flush") }
    print("segments \(lines.count)")
    write(["lines": lines], args[4])

case "windows":
    // Bench windows <wav> <seconds> <window> <hop> <out.json> : WeSpeaker embedding on sliding windows inside VAD speech.
    let audio = Array(try AudioConverter().resampleAudioFile(URL(fileURLWithPath: args[2])).prefix(Int(args[3])! * SR))
    let win = Int(Double(args[4])! * Double(SR)), hop = Int(Double(args[5])! * Double(SR))
    let vad = try await VadManager()
    let diar = DiarizerManager()
    diar.initialize(models: try await DiarizerModels.downloadIfNeeded())
    var st = vad.makeStreamState()
    var open: Int? = nil
    var next = 0
    var rows: [[String: Any]] = []
    var i = 0
    let t0 = Date()
    while i + VadManager.chunkSize <= audio.count {
        let r = try await vad.processStreamingChunk(Array(audio[i..<i + VadManager.chunkSize]), state: st,
                                                    config: VadSegmentationConfig(minSilenceDuration: 0.5))
        st = r.state
        i += VadManager.chunkSize
        if let e = r.event, e.isStart { open = e.sampleIndex; next = e.sampleIndex }
        if let e = r.event, e.isEnd { open = nil; _ = e }
        if open != nil {
            while next + win <= i {
                rows.append(["start": Double(next) / Double(SR), "end": Double(next + win) / Double(SR),
                             "emb": try diar.extractSpeakerEmbedding(from: Array(audio[next..<next + win]))])
                next += hop
            }
        }
    }
    print("windows \(rows.count) in \(Date().timeIntervalSince(t0)) s")
    write(["rows": rows], args[6])

case "lseend":
    // Bench lseend <wav> <seconds> <variant> <loops> <out.json> : the streaming API in 256 ms chunks, as the app would call it.
    let one = Array(try AudioConverter().resampleAudioFile(URL(fileURLWithPath: args[2])).prefix(Int(args[3])! * SR))
    let audio = (0..<Int(args[5])!).flatMap { _ in one }
    let variant: LSEENDVariant = ["ami": .ami, "callhome": .callhome, "dihard2": .dihard2, "dihard3": .dihard3][args[4]]!
    let d = LSEENDDiarizer()
    try await d.initialize(variant: variant, stepSize: .step100ms)
    var maxLag = 0.0, maxMs = 0.0, total = 0.0
    var i = 0
    while i < audio.count {
        let j = min(i + VadManager.chunkSize, audio.count)
        let t0 = DispatchTime.now().uptimeNanoseconds
        _ = try d.process(samples: audio[i..<j], sourceSampleRate: Double(SR))
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        maxMs = max(maxMs, ms); total += ms
        i = j
        if i > 10 * SR { maxLag = max(maxLag, Double(i) / Double(SR) - Double(d.timeline.finalizedDuration)) }
    }
    try d.finalizeSession()
    print(String(format: "lseend %@ %d s: total %.1f s, worst call %.1f ms, max finalize lag %.2f s, footprint %.0f MB", args[4], audio.count / SR, total / 1000, maxMs, maxLag, footprintMB()))
    var segs: [[String: Any]] = []
    for (_, s) in d.timeline.speakers { for g in s.finalizedSegments { segs.append(["spk": g.speakerIndex, "start": g.startTime, "end": g.endTime]) } }
    write(["segments": segs], args[6])

case "words":
    // Bench words <wav> <seconds> <out.json> : the planned segmenter + Ultra word times, for word-level speaker scoring.
    let audio = Array(try AudioConverter().resampleAudioFile(URL(fileURLWithPath: args[2])).prefix(Int(args[3])! * SR))
    let vad = try await VadManager()
    let asr = AsrManager(config: .default)
    try await asr.loadModels(try await AsrModels.downloadAndLoad(version: .ultra))
    let layers = await asr.decoderLayerCount
    var st = vad.makeStreamState()
    var open: Int? = nil
    var probs: [(end: Int, p: Float)] = []
    var words: [[String: Any]] = []
    func commit(_ s: Int, _ e: Int) async throws {
        var seg = Array(audio[s..<e])
        seg += [Float](repeating: 0, count: max(0, 4800 - seg.count))
        var ds = TdtDecoderState.make(decoderLayers: layers)
        let r = try await asr.transcribe(seg, decoderState: &ds)
        for w in buildWordTimings(from: r.tokenTimings ?? []) {
            words.append(["word": w.word, "start": Double(s) / Double(SR) + w.startTime, "end": Double(s) / Double(SR) + w.endTime])
        }
    }
    var i = 0
    while i + VadManager.chunkSize <= audio.count {
        let r = try await vad.processStreamingChunk(Array(audio[i..<i + VadManager.chunkSize]), state: st,
                                                    config: VadSegmentationConfig(minSilenceDuration: 0.5))
        st = r.state
        i += VadManager.chunkSize
        if let e = r.event, e.isStart { open = e.sampleIndex; probs = [] }
        if open != nil { probs.append((i, r.probability)) }
        if let e = r.event, e.isEnd, let s = open { try await commit(s, max(e.sampleIndex, s + 1)); open = nil; continue }
        if let s = open, i - s >= 12 * SR {
            let cut = probs.filter { $0.end >= i - 2 * SR }.min { $0.p < $1.p }!.end
            try await commit(s, cut)
            open = cut
            probs = probs.filter { $0.end > cut }
        }
    }
    if let s = open { try await commit(s, audio.count) }
    print("words \(words.count)")
    write(["words": words], args[4])

case "soak":
    // Bench soak <wav> : one hour of speech worth of live work: 14,062 growing-prefix decodes (one per 256 ms chunk) and
    // 7,200 embeddings, interleaved; logs memory and latency every 1,000 decodes.
    let audio = try AudioConverter().resampleAudioFile(URL(fileURLWithPath: args[2]))
    let asr = AsrManager(config: .default)
    try await asr.loadModels(try await AsrModels.downloadAndLoad(version: .ultra))
    let layers = await asr.decoderLayerCount
    let diar = DiarizerManager()
    diar.initialize(models: try await DiarizerModels.downloadIfNeeded())
    func rssMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        return Double(info.resident_size) / 1_048_576
    }
    var ms: [Double] = [], ems: [Double] = []
    var offset = 0, grow = 1, embeds = 0
    for n in 1...14062 {
        let len = max(4800, grow * VadManager.chunkSize)
        if offset + len > audio.count { offset = 0 }
        var ds = TdtDecoderState.make(decoderLayers: layers)
        var t0 = now()
        _ = try await asr.transcribe(Array(audio[offset..<offset + len]), decoderState: &ds)
        ms.append((now() - t0) * 1000)
        grow += 1
        if grow > 46 { grow = 1; offset += 46 * VadManager.chunkSize }  // 46 chunks = 11.8 s, just under the 12 s cut
        while Double(embeds) < Double(n) * 7200.0 / 14062.0 {
            let e = min(offset + 2 * SR, audio.count)
            t0 = now()
            _ = try diar.extractSpeakerEmbedding(from: Array(audio[(e - 2 * SR)..<e]))
            ems.append((now() - t0) * 1000)
            embeds += 1
        }
        if n % 1000 == 0 {
            ms.sort(); ems.sort()
            print(String(format: "%5d decodes %4d embeds | decode median %.1f max %.1f ms | embed median %.1f ms | footprint %.0f MB rss %.0f MB", n, embeds, ms[ms.count / 2], ms.last!, ems[ems.count / 2], footprintMB(), rssMB()))
            ms = []; ems = []
        }
    }

default:
    fatalError("unknown command \(args[1])")
}
