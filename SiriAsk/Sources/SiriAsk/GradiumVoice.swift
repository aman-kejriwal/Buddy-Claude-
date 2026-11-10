import AVFoundation

/// Speaks text with Gradium's text-to-speech API.
/// The API key and voice ID are read from `SiriAsk/.env` (next to `SiriAsk.app`).
///
/// Playback is streamed: Gradium sends the WAV progressively (first audio after ~0.6 s,
/// and faster than real time), so audio starts playing as soon as a little has arrived
/// instead of waiting for the whole file, which took ~7 s for a 20 s answer.
final class GradiumVoice: NSObject, URLSessionDataDelegate {

    struct Config {
        let apiKey: String
        let voiceID: String
    }

    private static let endpoint = URL(string: "https://api.gradium.ai/api/post/speech/tts")!
    /// Audio buffered before playback starts, to ride out small network hiccups.
    private static let startBufferSeconds = 0.25

    // Callbacks arrive on the main queue, the same queue speak()/stop() run on.
    private lazy var urlSession = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    private var task: URLSessionDataTask?
    private var onFailure: (() -> Void)?
    /// Called on the main queue when audio actually starts playing.
    var onAudioStarted: (() -> Void)?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()

    // Per-request stream state.
    private var header = Data()
    private var pcm = Data()                 // bytes after the WAV header not yet scheduled
    private var channels = 1
    private var sampleRate = 48_000.0
    private var format: AVAudioFormat?
    private var scheduledFrames = 0
    /// True once audio is actually playing.
    private(set) var started = false

    override init() {
        super.init()
        engine.attach(player)
    }

    /// Reads `GRADIUM_API_KEY` and `GRADIUM_VOICE_ID` from the `.env` file. Returns nil if either is missing.
    static func loadConfig() -> Config? {
        let envURL = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent(".env")
        guard let text = try? String(contentsOf: envURL, encoding: .utf8) else { return nil }

        var values: [String: String] = [:]
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, let last = value.last,
               (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                value = String(value.dropFirst().dropLast())
            }
            values[key] = value
        }

        guard let apiKey = values["GRADIUM_API_KEY"], !apiKey.isEmpty,
              let voiceID = values["GRADIUM_VOICE_ID"], !voiceID.isEmpty else { return nil }
        return Config(apiKey: apiKey, voiceID: voiceID)
    }

    /// Plays the text as speech. Calls `onFailure` on the main queue if Gradium can't be used
    /// before any audio played, so the caller can fall back to the macOS voice.
    func speak(_ text: String, config: Config, onFailure: @escaping () -> Void) {
        stop()
        self.onFailure = onFailure

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        let body: [String: Any] = [
            "text": text,
            "voice_id": config.voiceID,
            "output_format": "wav",
            "only_audio": true,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let task = urlSession.dataTask(with: request)
        self.task = task
        task.resume()
    }

    func stop() {
        task?.cancel()
        task = nil
        onFailure = nil
        player.stop()
        engine.stop()
        header.removeAll()
        pcm.removeAll()
        format = nil
        scheduledFrames = 0
        started = false
    }

    // MARK: - Streaming

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard dataTask === task else { return completionHandler(.cancel) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 200 {
            completionHandler(.allow)
        } else {
            completionHandler(.cancel)
            fail("HTTP \(status)")
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard dataTask === task else { return }
        if format == nil {
            header.append(data)
            guard let audioStart = parseHeader() else {
                if header.count > 64 * 1024 { fail("unreadable WAV header") }
                return
            }
            pcm.append(header[audioStart...])
            header.removeAll()
        } else {
            pcm.append(data)
        }
        scheduleAvailableAudio()
        if !started && Double(scheduledFrames) >= Self.startBufferSeconds * sampleRate {
            startPlayback()
        }
    }

    func urlSession(_ session: URLSession, task finished: URLSessionTask, didCompleteWithError error: Error?) {
        guard finished === task else { return }
        task = nil
        if let urlError = error as? URLError, urlError.code == .cancelled { return }
        if scheduledFrames == 0 {
            fail(error?.localizedDescription ?? "no audio received")
            return
        }
        // Short clips may finish downloading before the start buffer filled.
        if !started { startPlayback() }
    }

    /// Finds the `fmt ` and `data` chunks. Returns the offset where audio samples begin,
    /// or nil if more header bytes are needed. Only 16-bit PCM is supported.
    private func parseHeader() -> Int? {
        let bytes = [UInt8](header)
        guard bytes.count >= 12 else { return nil }
        guard bytes[0..<4].elementsEqual("RIFF".utf8), bytes[8..<12].elementsEqual("WAVE".utf8) else {
            fail("not a WAV stream")
            return nil
        }
        func u16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }

        var offset = 12
        var sawFormat = false
        while offset + 8 <= bytes.count {
            let id = String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
            let size = u32(offset + 4)
            let body = offset + 8
            if id == "data" {
                guard sawFormat else { fail("WAV data before format"); return nil }
                return body
            }
            guard body + size <= bytes.count else { return nil }   // chunk not fully arrived yet
            if id == "fmt " {
                let encoding = u16(body), bits = u16(body + 14)
                guard encoding == 1, bits == 16 else { fail("unsupported WAV encoding"); return nil }
                channels = max(1, u16(body + 2))
                sampleRate = Double(u32(body + 4))
                format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                       channels: AVAudioChannelCount(channels), interleaved: false)
                engine.connect(player, to: engine.mainMixerNode, format: format)
                sawFormat = true
            }
            offset = body + size + (size & 1)   // chunks are padded to even sizes
        }
        return nil
    }

    /// Converts whole 16-bit frames received so far to float and queues them on the player.
    private func scheduleAvailableAudio() {
        guard let format else { return }
        let bytesPerFrame = 2 * channels
        let frames = pcm.count / bytesPerFrame
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let out = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for frame in 0..<frames {
                for ch in 0..<channels {
                    out[ch][frame] = Float(Int16(littleEndian: samples[frame * channels + ch])) / 32768
                }
            }
        }
        pcm.removeFirst(frames * bytesPerFrame)

        player.scheduleBuffer(buffer)
        scheduledFrames += frames
    }

    private func startPlayback() {
        guard !started else { return }
        do {
            if !engine.isRunning { try engine.start() }
            player.play()
            started = true
            onFailure = nil   // audio is playing; no fallback from here on
            onAudioStarted?()
        } catch {
            fail("audio engine: \(error.localizedDescription)")
        }
    }

    private func fail(_ reason: String) {
        NSLog("SiriAsk: Gradium voice failed (\(reason)). Using the macOS voice.")
        let fallback = onFailure
        stop()
        fallback?()
    }
}
