import AVFoundation
import CryptoKit
import Carbon

// MARK: - Speaking

/// Plays utterances one after another. Fetches ElevenLabs audio as soon as an
/// utterance is queued (so a briefing has no gaps), caches it on disk by text,
/// and falls back to the macOS voice when ElevenLabs is unavailable.
final class Speaker: NSObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    struct Utterance {
        let id = UUID()
        let text: String
        let tag: String?
        var language: Lang = .en
    }

    var onStart: ((Utterance) -> Void)?
    var onFinish: ((Utterance) -> Void)?
    var onIdle: (() -> Void)?
    /// Characters actually sent to ElevenLabs (cache misses only).
    var onSpent: ((Int) -> Void)?
    var onError: ((Error) -> Void)?

    var voiceId = "JBFqnCBsd6RMkjVDRZzb"
    var voiceIdDE = "87AwpS6yC86wa2WglbsK"
    var model = "eleven_flash_v2_5"
    var useSystemVoice = false

    private let el: ElevenLabs
    private var queue: [(Utterance, Task<Data?, Never>)] = []
    private(set) var current: Utterance?
    private var player: AVAudioPlayer?
    private let synth = AVSpeechSynthesizer()
    private var generation = 0

    init(el: ElevenLabs) {
        self.el = el
        super.init()
        synth.delegate = self
    }

    var isBusy: Bool { current != nil || !queue.isEmpty }

    /// 0…1, for the avatar's mouth.
    func level() -> Float {
        if let p = player, p.isPlaying {
            p.updateMeters()
            let db = p.averagePower(forChannel: 0)
            return max(0, min(1, (db + 42) / 36))
        }
        if synth.isSpeaking { return 0.45 + 0.35 * Float(abs(sin(Date().timeIntervalSince1970 * 11))) }
        return 0
    }

    func say(_ text: String, tag: String? = nil, language: Lang = .en) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let u = Utterance(text: t, tag: tag, language: language)
        let systemOnly = useSystemVoice
        let voice = language == .de ? voiceIdDE : voiceId
        let task = Task<Data?, Never> { [weak self] in
            if systemOnly { return nil }
            return await self?.audio(for: t, voice: voice, language: language)
        }
        queue.append((u, task))
        pump()
    }

    func stopAll() {
        generation += 1
        queue.forEach { $0.1.cancel() }
        queue.removeAll()
        player?.stop()
        player = nil
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        if let c = current {
            current = nil
            onFinish?(c)
        }
        onIdle?()
    }

    /// Skips to the next utterance in the queue.
    func skip() {
        player?.stop()
        player = nil
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        finishCurrent()
    }

    private func pump() {
        guard current == nil else { return }
        guard !queue.isEmpty else { onIdle?(); return }
        let (u, task) = queue.removeFirst()
        current = u
        let gen = generation
        onStart?(u)
        Task { @MainActor [weak self] in
            let data = await task.value
            guard let self, gen == self.generation, self.current?.id == u.id else { return }
            if let data, let p = try? AVAudioPlayer(data: data) {
                p.delegate = self
                p.isMeteringEnabled = true
                self.player = p
                p.play()
            } else {
                let utt = AVSpeechUtterance(string: u.text)
                utt.voice = AVSpeechSynthesisVoice(language: u.language.speechLocale)
                utt.rate = 0.52
                self.synth.speak(utt)
            }
        }
    }

    private func finishCurrent() {
        guard let c = current else { return }
        current = nil
        player = nil
        onFinish?(c)
        pump()
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.player === player else { return }
            self.finishCurrent()
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in self?.finishCurrent() }
    }

    private func audio(for text: String, voice: String, language: Lang) async -> Data? {
        let key = SHA256.hash(data: Data("\(voice)|\(model)|\(text)".utf8)).map { String(format: "%02x", $0) }.joined()
        let file = Paths.ttsCache.appendingPathComponent(key + ".mp3")
        if let cached = try? Data(contentsOf: file) { return cached }
        guard el.isConfigured else { return nil }
        do {
            let data = try await el.speech(text, voiceId: voice, model: model, language: language.rawValue)
            try? data.write(to: file)
            let n = text.count
            DispatchQueue.main.async { [weak self] in self?.onSpent?(n) }
            return data
        } catch {
            DispatchQueue.main.async { [weak self] in self?.onError?(error) }
            return nil
        }
    }
}

// MARK: - Listening

/// Records the microphone as 16 kHz mono Int16 PCM while push-to-talk is held.
final class Recorder {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let lock = NSLock()
    private var pcm = Data()
    private var _level: Float = 0
    private(set) var isRecording = false
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

    var level: Float { lock.lock(); defer { lock.unlock() }; return _level }

    static var authorized: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    static func requestAccess(_ done: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { done(ok) } }
    }

    func start() throws {
        guard !isRecording else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw NSError(domain: "Companion", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone input available."]) }
        converter = AVAudioConverter(from: format, to: target)
        converter?.downmix = true
        lock.lock(); pcm = Data(); _level = 0; lock.unlock()
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        engine.prepare()
        try engine.start()
        isRecording = true
    }

    /// Stops and returns everything recorded since `start()`.
    func stop() -> Data {
        guard isRecording else { return Data() }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        lock.lock(); defer { lock.unlock() }
        _level = 0
        return pcm
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        if let ch = buffer.floatChannelData?[0], buffer.frameLength > 0 {
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += ch[i] * ch[i] }
            let rms = sqrt(sum / Float(buffer.frameLength))
            let lvl = max(0, min(1, (20 * log10(max(rms, 0.000_01)) + 50) / 42))
            lock.lock(); _level = lvl; lock.unlock()
        }
        guard let converter else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        if error == nil, let p = out.int16ChannelData?[0], out.frameLength > 0 {
            let d = Data(bytes: p, count: Int(out.frameLength) * 2)
            lock.lock(); pcm.append(d); lock.unlock()
        }
    }
}

// MARK: - Global push-to-talk key

/// Hold-to-talk on ⌥ Space via Carbon hot keys: works in every app, sees both
/// press and release, and needs no Accessibility permission.
final class HotKey {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private static var current: HotKey?

    func register(keyCode: UInt32 = UInt32(kVK_Space), modifiers: UInt32 = UInt32(optionKey)) -> Bool {
        HotKey.current = self
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            let kind = GetEventKind(event)
            DispatchQueue.main.async {
                if kind == UInt32(kEventHotKeyPressed) { HotKey.current?.onPress?() } else { HotKey.current?.onRelease?() }
            }
            return noErr
        }, 2, &types, nil, &handler)
        let id = EventHotKeyID(signature: OSType(0x4343_4D50), id: 1) // "CCMP"
        return RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr
    }
}
