import AVFoundation
import Foundation

/// The microphone, held by the app because a keyboard extension cannot have one.
///
/// While the session runs, every buffer the microphone delivers is dropped unless
/// a dictation is being captured; only then is it written, as 16 kHz mono, to the
/// one file that dictation owns. Nothing is recorded between dictations.
final class AudioCapture {
    enum Failure: LocalizedError {
        case noMicrophone
        case notRunning

        var errorDescription: String? {
            switch self {
            case .noMicrophone: return "The microphone is not available right now."
            case .notRunning: return "The microphone is off."
            }
        }
    }

    /// Called on the main queue when the session ended without being asked to:
    /// a phone call, another app taking the microphone, or the audio system restarting.
    var onEnded: (() -> Void)?

    private(set) var isRunning = false

    private var engine = AVAudioEngine()
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var fileURL: URL?
    private var converter: AVAudioConverter?
    private var observers: [NSObjectProtocol] = []
    // 16 kHz mono float is always a valid PCM format.
    private let target = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// Turns the microphone on. iOS allows this only while the app is on screen.
    func start() throws {
        guard !isRunning else { return }
        let session = AVAudioSession.sharedInstance()
        // Other apps keep playing: on the speaker instead of the earpiece, and on wireless
        // headphones at full quality while the iPhone's own microphone listens.
        try session.setCategory(
            .playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
        try session.setActive(true)
        do {
            try startEngine()
        } catch {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
        isRunning = true
        observe()
    }

    /// Turns the microphone off and drops any capture in progress.
    func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        if let dropped = endCapture() {
            try? FileManager.default.removeItem(at: dropped.url)
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Starts keeping audio, in a new file at `url`.
    func beginCapture(to url: URL) throws {
        guard isRunning else { throw Failure.notRunning }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: target.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let newFile = try AVAudioFile(
            forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        lock.lock()
        converter?.reset()
        file = newFile
        fileURL = url
        lock.unlock()
    }

    /// Stops keeping audio. Returns the file and how many seconds it holds, or nil when nothing was being captured.
    func endCapture() -> (url: URL, seconds: Double)? {
        lock.lock()
        let finished = file
        let url = fileURL
        file = nil
        fileURL = nil
        lock.unlock()
        guard let finished, let url else { return nil }
        return (url, Double(finished.length) / target.sampleRate)
    }

    // MARK: Engine

    private func startEngine() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let newConverter = AVAudioConverter(from: format, to: target)
        else { throw Failure.noMicrophone }
        lock.lock()
        converter = newConverter
        lock.unlock()
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.consume(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    /// The microphone's own thread. Outside a capture this returns at once and the buffer is gone.
    private func consume(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let file, let converter else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        let supplied = Once()
        var conversionError: NSError?
        let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
            if supplied.used {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied.used = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, conversionError == nil, converted.frameLength > 0 else { return }
        try? file.write(from: converted)
    }

    // MARK: Interruptions

    private func observe() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                guard raw == AVAudioSession.InterruptionType.began.rawValue else { return }
                self?.endUnasked()
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.endUnasked()
                // The audio system restarted and the old engine went with it. The next start gets a new one.
                self.engine = AVAudioEngine()
            },
            // A headset plugged in or removed: the input format changed and the engine stopped itself.
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                guard let self, self.isRunning else { return }
                do { try self.startEngine() } catch { self.endUnasked() }
            },
        ]
    }

    /// Keeps a capture in progress for the owner to finish, and turns the microphone off.
    private func endUnasked() {
        guard isRunning else { return }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        onEnded?()
    }
}

/// The converter asks for input more than once per buffer; this hands the buffer over the first time only.
/// Used on the microphone's thread alone, inside one call.
private final class Once: @unchecked Sendable {
    var used = false
}
