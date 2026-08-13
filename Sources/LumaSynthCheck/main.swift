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

    complaints += checkStereo(synth)
    complaints += checkGettingBack(synth)

    guard complaints.isEmpty else {
        FileHandle.standardError.write(Data((complaints.joined(separator: "\n") + "\n").utf8))
        return 1
    }
    print("every patch sounds, and sounds like itself")
    return 0
}

/// A panned voice has to reach one side more than the other, and an echo has
/// to cross sides as it comes round. Neither is audible to a compiler.
@MainActor
func checkStereo(_ synth: Synth) -> [String] {
    var complaints: [String] = []

    synth.use(.pulse, channel: 0)
    for (name, pan, louder) in [("left", Float(-1), 0), ("right", Float(1), 1)] {
        synth.pan(pan, channel: 0)
        _ = synth.play(frequency: 220, velocity: 1, channel: 0)
        let frames = synth.renderOffline(frameCount: 12000, channels: 2)

        let sides = (0..<2).map { side in
            stride(from: side, to: frames.count, by: 2).reduce(Float(0)) { $0 + abs(frames[$1]) }
        }
        print(String(format: "pan %@  left %.2f  right %.2f", name, sides[0], sides[1]))
        if sides[louder] <= sides[1 - louder] {
            complaints.append("pan \(name): the other side is no quieter")
        }
    }

    synth.pan(0, channel: 0)
    synth.echo(seconds: 0.2, feedback: 0.5, mix: 0.6)
    _ = synth.play(frequency: 220, velocity: 1, channel: 0)
    let frames = synth.renderOffline(frameCount: 48000, channels: 2)
    var crossed = false
    for index in stride(from: 0, to: frames.count, by: 2)
    where abs(frames[index] - frames[index + 1]) > 0.01 {
        crossed = true
        break
    }
    if !crossed {
        complaints.append("echo: the sides are identical, so it is not crossing")
    }
    print("echo crosses sides: \(crossed)")
    synth.echo(seconds: 0, feedback: 0, mix: 0)
    return complaints
}

/// Getting back to the start has to be audible too: a hush has to silence
/// what is sounding, and a reset has to sound like the beginning.
@MainActor
func checkGettingBack(_ synth: Synth) -> [String] {
    var complaints: [String] = []

    // A patch that sustains keeps sounding until something stops it.
    let held = SynthPatch(
        waveform: .saw, attack: 0.001, decay: 0.05, sustain: 0.9, release: 0.4,
        cutoff: 0, resonance: 0, gain: 0.8)
    synth.use(held, channel: 0)
    _ = synth.play(frequency: 220, velocity: 1, channel: 0)
    _ = synth.renderOffline(frameCount: 4800)
    synth.hush()
    let afterHush = synth.renderOffline(frameCount: 4800).map(abs).max() ?? 0
    print(String(format: "after hush: peak %.4f", afterHush))
    if afterHush > 0.001 {
        complaints.append("hush: still sounding, peak \(afterHush)")
    }

    // What the beginning sounds like, against what it sounds like once a
    // channel has been dressed up and then reset.
    synth.reset()
    synth.use(.pulse, channel: 0)
    _ = synth.play(frequency: 220, velocity: 1, channel: 0)
    let plain = synth.renderOffline(frameCount: 12000)

    synth.use(.acid, channel: 0)
    synth.pan(-1, channel: 0)
    synth.echo(seconds: 0.2, feedback: 0.5, mix: 0.6)
    _ = synth.play(frequency: 220, velocity: 1, channel: 0)
    _ = synth.renderOffline(frameCount: 12000)

    synth.reset()
    synth.use(.pulse, channel: 0)
    _ = synth.play(frequency: 220, velocity: 1, channel: 0)
    let again = synth.renderOffline(frameCount: 12000)

    print("reset sounds like the beginning: \(plain == again)")
    if plain != again {
        complaints.append("reset: does not sound like the beginning")
    }
    return complaints
}

exit(MainActor.assumeIsolated { check() })
