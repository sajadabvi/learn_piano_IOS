import Foundation
import AVFoundation

@main struct PitchCheck {
    static func main() throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let file = try AVAudioFile(forReading: url)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: file.fileFormat.sampleRate, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        guard let pipeline = InputPitchPipeline(sampleRate: format.sampleRate) else { print("pipeline init failed"); exit(1) }
        var events: [NoteInputEvent] = []
        let chunk = 1024
        var i = 0
        while i < samples.count {
            let slice = Array(samples[i..<min(i + chunk, samples.count)])
            for r in pipeline.process(samples: slice, startTime: Double(i) / format.sampleRate) { events += r.events }
            i += chunk
        }
        events += pipeline.flush(at: Double(samples.count) / format.sampleRate)
        for e in events {
            print(String(format: "%6.2fs  %@  %@", e.time, e.kind == .on ? "ON " : "off", MusicHelpers.noteName(midi: e.midi)))
        }
    }
}
