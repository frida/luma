import Foundation
import LumaCore

/// Plays each patch offline and says what came out. A synthesiser is the one
/// thing here that cannot be checked by looking, and a patch that has gone
/// silent or lost its character sounds fine to a compiler.
///
///     swift run LumaSynthCheck
@MainActor
func check() -> Int32 {
    let synth = Synth()
    let patches: [(name: String, patch: SynthPatch)] = [
        ("pulse", .pulse), ("bass", .bass), ("blip", .blip), ("noiseHit", .noiseHit),
        ("pwmLead", .pwmLead), ("acid", .acid), ("syncLead", .syncLead),
        ("bell", .bell), ("pad", .pad),
    ]

    var complaints: [String] = []
    var shapes: [String: [Float]] = [:]
    for (name, patch) in patches {
        synth.use(patch, channel: 0)
        _ = synth.play(frequency: 220, velocity: 1, channel: 0)
        let frames = synth.renderOffline(frameCount: 24000)

        let peak = frames.map(abs).max() ?? 0
        var crossings = 0
        for index in 1..<frames.count where (frames[index] < 0) != (frames[index - 1] < 0) {
            crossings += 1
        }
        print(String(format: "%@ peak %.3f crossings %d",
                     name.padding(toLength: 9, withPad: " ", startingAt: 0), peak, crossings))

        if peak < 0.05 {
            complaints.append("\(name): silent, peak \(peak)")
        }
        if peak > 0.999 {
            complaints.append("\(name): clipped, peak \(peak)")
        }
        for (other, shape) in shapes where shape == frames {
            complaints.append("\(name): sounds exactly like \(other)")
        }
        shapes[name] = frames
    }

    guard complaints.isEmpty else {
        FileHandle.standardError.write(Data((complaints.joined(separator: "\n") + "\n").utf8))
        return 1
    }
    print("every patch sounds, and sounds like itself")
    return 0
}

exit(MainActor.assumeIsolated { check() })
