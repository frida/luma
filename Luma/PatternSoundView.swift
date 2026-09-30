import AVFoundation
import LumaCore
import SwiftUI

struct PatternSoundView: View {
    let sound: PatternVisualization.Sound

    @State private var playback = SoundPlayback()
    private let waveform: [[ClosedRange<Float>]]

    private static let width: CGFloat = 600
    private static let height: CGFloat = 150

    init(sound: PatternVisualization.Sound) {
        self.sound = sound
        waveform = Self.envelope(of: sound, columns: Int(Self.width))
    }

    private var frameCount: Int { sound.samples.count / sound.channels }
    private var duration: Double { Double(frameCount) / Double(sound.sampleRate) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TimelineView(.animation(paused: playback.startedAt == nil)) { context in
                Canvas { canvas, size in
                    drawWaveform(in: &canvas, size: size)
                    if let startedAt = playback.startedAt {
                        let progress = min(context.date.timeIntervalSince(startedAt) / duration, 1)
                        let x = size.width * progress
                        canvas.stroke(
                            Path { $0.addLines([CGPoint(x: x, y: 0), CGPoint(x: x, y: size.height)]) }, with: .color(.primary), lineWidth: 1
                        )
                    }
                }
            }
            .frame(width: Self.width, height: Self.height)
            HStack(spacing: 10) {
                Button {
                    if playback.startedAt == nil {
                        playback.play(sound)
                    } else {
                        playback.stop()
                    }
                } label: {
                    Image(systemName: playback.startedAt == nil ? "play.fill" : "stop.fill")
                }
                .disabled(frameCount == 0)
                Text("\(sound.channels) ch · \(sound.sampleRate) Hz · \(duration.formatted(.number.precision(.fractionLength(2)))) s")
                    .foregroundStyle(.secondary)
                if let problem = playback.problem {
                    Text(problem)
                        .foregroundStyle(.red)
                }
            }
        }
        .onDisappear { playback.stop() }
    }

    private func drawWaveform(in canvas: inout GraphicsContext, size: CGSize) {
        let laneHeight = size.height / CGFloat(max(waveform.count, 1))
        for (channel, columns) in waveform.enumerated() {
            let middle = laneHeight * (CGFloat(channel) + 0.5)
            var path = Path()
            let columnWidth = size.width / CGFloat(max(columns.count, 1))
            for (column, range) in columns.enumerated() {
                let x = (CGFloat(column) + 0.5) * columnWidth
                path.move(to: CGPoint(x: x, y: middle - CGFloat(range.upperBound) * laneHeight / 2))
                path.addLine(to: CGPoint(x: x, y: middle - CGFloat(range.lowerBound) * laneHeight / 2 + 0.5))
            }
            canvas.stroke(path, with: .color(.fridaBrand), lineWidth: 1)
        }
    }

    private static func envelope(of sound: PatternVisualization.Sound, columns: Int) -> [[ClosedRange<Float>]] {
        let frames = sound.samples.count / sound.channels
        guard frames > 0 else { return [] }
        return (0..<sound.channels).map { channel in
            func sample(_ frame: Int) -> Float {
                Float(sound.samples[frame * sound.channels + channel]) / 32768
            }
            var previous = sample(0)
            return (0..<min(columns, frames)).map { column in
                let first = column * frames / columns
                let end = max(first + 1, (column + 1) * frames / columns)
                var low = previous
                var high = previous
                for frame in first..<end {
                    previous = sample(frame)
                    low = min(low, previous)
                    high = max(high, previous)
                }
                return low...high
            }
        }
    }
}

@MainActor
@Observable
private final class SoundPlayback {
    private(set) var startedAt: Date?
    private(set) var problem: String?

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var generation = 0

    func play(_ sound: PatternVisualization.Sound) {
        stop()
        let frames = sound.samples.count / sound.channels
        guard
            let format = AVAudioFormat(
                standardFormatWithSampleRate: Double(sound.sampleRate), channels: AVAudioChannelCount(sound.channels)),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else {
            problem = "Cannot play \(sound.channels) channels at \(sound.sampleRate) Hz."
            return
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        let channels = buffer.floatChannelData!
        for frame in 0..<frames {
            for channel in 0..<sound.channels {
                channels[channel][frame] = Float(sound.samples[frame * sound.channels + channel]) / 32768
            }
        }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            problem = error.localizedDescription
            return
        }
        generation += 1
        let playing = generation
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == playing else { return }
                self.stop()
            }
        }
        player.play()
        self.engine = engine
        self.player = player
        startedAt = .now
        problem = nil
    }

    func stop() {
        generation += 1
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
        startedAt = nil
    }
}
