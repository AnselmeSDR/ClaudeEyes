import AppKit
import Combine

/// Short robot chirps, synthesized at runtime: no audio file in the bundle
enum Chirp: CaseIterable {
    case waiting, done, failed

    var name: String { "\(self)" }

    /// Several sessions change at once: the most urgent sound plays
    var urgency: Int {
        switch self {
        case .waiting: return 3
        case .failed: return 2
        case .done: return 1
        }
    }

    /// Frequency glide (Hz), duration and silence after each note (seconds)
    fileprivate var notes: [(from: Double, to: Double, duration: Double, gap: Double)] {
        switch self {
        case .waiting:  // "bip-bip?", rising like a question
            return [(880, 880, 0.07, 0.05), (990, 1480, 0.13, 0)]
        case .done:     // happy little arpeggio
            return [(784, 784, 0.06, 0.02), (988, 988, 0.06, 0.02), (1319, 1397, 0.14, 0)]
        case .failed:   // sad, falling "bwoo-bwoo"
            return [(523, 466, 0.14, 0.05), (392, 311, 0.22, 0)]
        }
    }

    /// 16-bit mono WAV
    var wav: Data {
        let sampleRate = 44_100.0
        var samples: [Int16] = []
        for note in notes {
            let count = Int(note.duration * sampleRate)
            var phase = 0.0
            for index in 0..<count {
                let progress = Double(index) / Double(count)
                // Exponential glide: sounds even across octaves
                phase += 2 * .pi * note.from * pow(note.to / note.from, progress) / sampleRate
                // A touch of 3rd harmonic gives the slightly square, robotic timbre
                let wave = (sin(phase) + 0.25 * sin(3 * phase)) / 1.25
                // Short attack and release: no clicks
                let envelope = min(1, Double(index) / (0.005 * sampleRate)) * min(1, Double(count - index) / (0.03 * sampleRate))
                samples.append(Int16(wave * envelope * 0.8 * Double(Int16.max)))
            }
            samples += [Int16](repeating: 0, count: Int(note.gap * sampleRate))
        }

        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let byteCount = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8))
        append(36 + byteCount)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))                   // fmt chunk size
        append(UInt16(1))                    // PCM
        append(UInt16(1))                    // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate) * 2)       // bytes per second
        append(UInt16(2))                    // bytes per frame
        append(UInt16(16))                   // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(byteCount)
        samples.forEach(append)
        return data
    }
}

/// Plays a chirp when a session starts waiting for you or ends its turn (main app only)
final class Sounds {
    static let shared = Sounds()

    private var players: [Chirp: NSSound] = [:]
    private var lastStates: [String: SessionState] = [:]
    private var lastPlayed: [String: Double] = [:]
    private var startedAt = 0.0
    private var observer: AnyCancellable?

    func start() {
        startedAt = Date().timeIntervalSince1970
        Prefs.shared.forgetMutedSessions { id in
            // Session ids are "pid-<pid>": the mute ends with the process
            guard let pid = Int32(id.replacingOccurrences(of: "pid-", with: "")) else { return true }
            return kill(pid, 0) != 0 && errno != EPERM
        }
        observer = SessionStore.shared.$sessions.sink { [weak self] in self?.update($0) }
    }

    /// Writes every chirp as <name>.wav, to listen to them outside the app
    static func write(to directory: String) {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for chirp in Chirp.allCases {
            try? chirp.wav.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(chirp.name).wav"))
        }
    }

    func play(_ chirp: Chirp) {
        if players[chirp] == nil { players[chirp] = NSSound(data: chirp.wav) }
        guard let player = players[chirp] else { return }
        player.stop()
        player.volume = Float(Prefs.shared.soundVolume)
        player.play()
    }

    private func update(_ sessions: [Session]) {
        let prefs = Prefs.shared
        let now = Date().timeIntervalSince1970
        // States found at launch, and the live status read right after, are not news
        let warmingUp = now - startedAt < 3
        var chirp: Chirp?

        for session in sessions {
            let state = session.state
            let previous = lastStates[session.id]
            lastStates[session.id] = state
            guard !warmingUp, let previous, previous != state,
                  prefs.isSoundOn(for: session.id),
                  now - (lastPlayed[session.id] ?? 0) > 2 else { continue }

            let next: Chirp?
            switch state {
            case .waiting where prefs.soundWhenWaiting: next = .waiting
            case .done where prefs.soundWhenDone: next = .done
            case .failed where prefs.soundWhenFailed: next = .failed
            default: next = nil
            }
            guard let next else { continue }
            lastPlayed[session.id] = now
            if chirp == nil || next.urgency > chirp!.urgency { chirp = next }
        }

        let ids = Set(sessions.map(\.id))
        lastStates = lastStates.filter { ids.contains($0.key) }
        lastPlayed = lastPlayed.filter { ids.contains($0.key) }
        if let chirp { play(chirp) }
    }
}
