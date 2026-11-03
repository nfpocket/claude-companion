import Foundation

enum Secrets {
    /// The key lives in the login Keychain as generic password "elevenlabs".
    /// Reading it through /usr/bin/security (which created the item) avoids a Keychain prompt.
    static func elevenLabsKey() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "elevenlabs", "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty else { return nil }
        return s
    }
}

struct ElevenLabsError: LocalizedError {
    let status: Int
    let body: String
    var errorDescription: String? {
        if status == 401 { return "ElevenLabs rejected the key (401)." }
        if body.contains("quota_exceeded") { return "ElevenLabs quota is used up." }
        return "ElevenLabs error \(status): \(body.prefix(160))"
    }
    var isQuota: Bool { body.contains("quota_exceeded") || status == 402 }
}

struct Voice: Identifiable, Hashable {
    let id: String
    let name: String
    let language: String?
}

final class ElevenLabs {
    var apiKey: String?
    private let base = URL(string: "https://api.elevenlabs.io")!
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        return URLSession(configuration: c)
    }()

    var isConfigured: Bool { apiKey != nil }

    private func request(_ path: String, query: [URLQueryItem] = []) throws -> URLRequest {
        guard let key = apiKey else { throw ElevenLabsError(status: 0, body: "No ElevenLabs key in the Keychain (item \"elevenlabs\").") }
        var url = base.appending(path: path)
        if !query.isEmpty { url = url.appending(queryItems: query) }
        var r = URLRequest(url: url)
        r.setValue(key, forHTTPHeaderField: "xi-api-key")
        return r
    }

    private func check(_ data: Data, _ resp: URLResponse) throws {
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw ElevenLabsError(status: code, body: String(data: data, encoding: .utf8) ?? "")
        }
    }

    /// Speech for `text`, as MP3.
    func speech(_ text: String, voiceId: String, model: String, language: String? = nil) async throws -> Data {
        var r = try request("/v1/text-to-speech/\(voiceId)", query: [URLQueryItem(name: "output_format", value: "mp3_44100_64")])
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        var body: [String: Any] = [
            "text": text,
            "model_id": model,
            "voice_settings": ["stability": 0.5, "similarity_boost": 0.75],
        ]
        // Flash/Turbo v2.5 accept a language hint, which keeps German from being read with English rules.
        if let language, model.hasSuffix("v2_5") { body["language_code"] = language }
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: r)
        try check(data, resp)
        return data
    }

    /// Transcribes 16 kHz mono 16-bit little-endian PCM with Scribe; returns the text and
    /// the detected language code (e.g. "eng", "deu").
    func transcribe(pcm16k: Data) async throws -> (text: String, language: String?) {
        var r = try request("/v1/speech-to-text")
        r.httpMethod = "POST"
        let boundary = "companion-\(UUID().uuidString)"
        r.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        field("model_id", "scribe_v2")
        field("file_format", "pcm_s16le_16")
        field("tag_audio_events", "false")
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"speech.pcm\"\r\nContent-Type: application/octet-stream\r\n\r\n")
        body.append(pcm16k)
        body.append("\r\n--\(boundary)--\r\n")
        r.httpBody = body
        let (data, resp) = try await session.data(for: r)
        try check(data, resp)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return ((obj?["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                obj?["language_code"] as? String)
    }

    /// Characters used and allowed in the current billing period.
    func quota() async throws -> (used: Int, limit: Int) {
        let r = try request("/v1/user/subscription")
        let (data, resp) = try await session.data(for: r)
        try check(data, resp)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return ((obj["character_count"] as? NSNumber)?.intValue ?? 0,
                (obj["character_limit"] as? NSNumber)?.intValue ?? 0)
    }

    func voices() async throws -> [Voice] {
        let r = try request("/v1/voices")
        let (data, resp) = try await session.data(for: r)
        try check(data, resp)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let list = obj["voices"] as? [[String: Any]] ?? []
        return list.compactMap { v in
            guard let id = v["voice_id"] as? String, let name = v["name"] as? String else { return nil }
            let labels = v["labels"] as? [String: Any]
            return Voice(id: id, name: name, language: labels?["language"] as? String)
        }
    }
}

extension Data {
    mutating func append(_ s: String) { append(Data(s.utf8)) }
}
