//
//  ElevenLabsTTSClient.swift
//  leanring-buddy
//
//  Local TTS client backed by mlx-audio (Kokoro) through uv.
//

import AVFoundation
import Foundation

@MainActor
final class ElevenLabsTTSClient {
    private let proxyURL: URL
    private let session: URLSession

    private let localKokoroModelName = AppBundleConfiguration.stringValue(forKey: "LocalTTSModel")
        ?? "mlx-community/Kokoro-82M-4bit"
    private let localKokoroVoiceName = AppBundleConfiguration.stringValue(forKey: "LocalTTSVoice")
        ?? "af_heart"
    private let localKokoroLanguageCode = AppBundleConfiguration.stringValue(forKey: "LocalTTSLanguageCode")
        ?? "a"

    /// The audio player for the current TTS playback. Kept alive so the
    /// audio finishes playing even if the caller doesn't hold a reference.
    private var audioPlayer: AVAudioPlayer?

    init(proxyURL: String) {
        self.proxyURL = URL(string: proxyURL)!

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: configuration)
    }

    /// Synthesizes `text` via the local TTS server and plays the resulting audio.
    func speakText(_ text: String) async throws {
        try Task.checkCancellation()

        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else { return }

        try await LocalSpeechServiceBootstrap.shared.ensureServersRunning(
            whisperModelName: AppBundleConfiguration.stringValue(forKey: "LocalWhisperModel") ?? "mlx-community/whisper-base-mlx-fp32",
            ttsModelName: localKokoroModelName,
            ttsVoiceName: localKokoroVoiceName,
            ttsLanguageCode: localKokoroLanguageCode
        )

        guard let localTTSServerURL = URL(string: "http://127.0.0.1:8766/speak") else {
            throw NSError(domain: "LocalKokoroTTS", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid local TTS server URL"])
        }

        let requestBody: [String: Any] = [
            "text": normalizedText
        ]

        var request = URLRequest(url: localTTSServerURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "LocalKokoroTTS", code: -1, userInfo: [NSLocalizedDescriptionKey: "Local TTS server returned an invalid response"])
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let responseText = String(data: data, encoding: .utf8) ?? "Unknown local TTS server error"
            throw NSError(domain: "LocalKokoroTTS", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Local TTS server failed: \(responseText)"])
        }

        guard let responseJSON = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let audioBase64 = responseJSON["audioBase64"] as? String,
              let audioData = Data(base64Encoded: audioBase64) else {
            throw NSError(domain: "LocalKokoroTTS", code: -1, userInfo: [NSLocalizedDescriptionKey: "Local TTS server returned malformed audio payload"])
        }

        let player = try AVAudioPlayer(data: audioData)
        self.audioPlayer = player
        player.play()
        print("🔊 Local Kokoro TTS: playing \(audioData.count / 1024)KB audio")
    }

    /// Whether TTS audio is currently playing back.
    var isPlaying: Bool {
        audioPlayer?.isPlaying ?? false
    }

    /// Stops any in-progress playback immediately.
    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
    }
}
