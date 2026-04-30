//
//  OpenAIAudioTranscriptionProvider.swift
//  leanring-buddy
//
//  Local transcription provider backed by mlx-whisper through uv.
//

import AVFoundation
import Foundation

struct OpenAIAudioTranscriptionProviderError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

final class OpenAIAudioTranscriptionProvider: BuddyTranscriptionProvider {
    private let localWhisperModelName = AppBundleConfiguration.stringValue(forKey: "LocalWhisperModel")
        ?? "mlx-community/whisper-base-mlx-fp32"

    let displayName = "Whisper MLX"
    let requiresSpeechRecognitionPermission = false

    var isConfigured: Bool {
        true
    }

    var unavailableExplanation: String? {
        nil
    }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        return OpenAIAudioTranscriptionSession(
            localWhisperModelName: localWhisperModelName,
            keyterms: keyterms,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
    }
}

private final class OpenAIAudioTranscriptionSession: BuddyStreamingTranscriptionSession {
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 8.0

    private static let targetSampleRate = 16_000

    private let localWhisperModelName: String
    private let keyterms: [String]
    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    private let stateQueue = DispatchQueue(label: "com.learningbuddy.localwhisper.transcription")
    private let stateQueueSpecificKey = DispatchSpecificKey<UInt8>()
    private let audioPCM16Converter = BuddyPCM16AudioConverter(
        targetSampleRate: Double(targetSampleRate)
    )

    private var bufferedPCM16AudioData = Data()
    private var hasRequestedFinalTranscript = false
    private var hasDeliveredFinalTranscript = false
    private var isCancelled = false
    private var transcriptionTask: Task<Void, Never>?

    init(
        localWhisperModelName: String,
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.localWhisperModelName = localWhisperModelName
        self.keyterms = keyterms
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError
        self.stateQueue.setSpecific(key: stateQueueSpecificKey, value: 1)
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard let audioPCM16Data = audioPCM16Converter.convertToPCM16Data(from: audioBuffer),
              !audioPCM16Data.isEmpty else {
            return
        }

        stateQueue.async {
            guard !self.hasRequestedFinalTranscript, !self.isCancelled else { return }
            self.bufferedPCM16AudioData.append(audioPCM16Data)
        }
    }

    func requestFinalTranscript() {
        stateQueue.async {
            guard !self.hasRequestedFinalTranscript, !self.isCancelled else { return }
            self.hasRequestedFinalTranscript = true

            let bufferedPCM16AudioData = self.bufferedPCM16AudioData
            self.transcriptionTask = Task { [weak self] in
                await self?.transcribeBufferedAudio(bufferedPCM16AudioData)
            }
        }
    }

    func cancel() {
        runOnStateQueueSynchronously {
            isCancelled = true
            bufferedPCM16AudioData.removeAll(keepingCapacity: false)
            transcriptionTask?.cancel()
            transcriptionTask = nil
        }
    }

    private func transcribeBufferedAudio(_ bufferedPCM16AudioData: Data) async {
        guard !Task.isCancelled else { return }

        let trimmedAudioDataIsEmpty = stateQueue.sync {
            isCancelled || bufferedPCM16AudioData.isEmpty
        }

        if trimmedAudioDataIsEmpty {
            deliverFinalTranscript("")
            return
        }

        let wavAudioData = BuddyWAVFileBuilder.buildWAVData(
            fromPCM16MonoAudio: bufferedPCM16AudioData,
            sampleRate: Self.targetSampleRate
        )

        do {
            let transcriptText = try await transcribeWithLocalWhisper(wavAudioData: wavAudioData)
            guard !stateQueue.sync(execute: { isCancelled }) else { return }

            if !transcriptText.isEmpty {
                onTranscriptUpdate(transcriptText)
            }

            deliverFinalTranscript(transcriptText)
        } catch {
            guard !stateQueue.sync(execute: { isCancelled }) else { return }
            print("[Whisper MLX] ❌ Transcription failed: \(error.localizedDescription)")
            onError(error)
        }
    }

    private func transcribeWithLocalWhisper(wavAudioData: Data) async throws -> String {
        try await LocalSpeechServiceBootstrap.shared.ensureServersRunning(
            whisperModelName: localWhisperModelName,
            ttsModelName: AppBundleConfiguration.stringValue(forKey: "LocalTTSModel") ?? "mlx-community/Kokoro-82M-4bit",
            ttsVoiceName: AppBundleConfiguration.stringValue(forKey: "LocalTTSVoice") ?? "af_heart",
            ttsLanguageCode: AppBundleConfiguration.stringValue(forKey: "LocalTTSLanguageCode") ?? "a"
        )

        guard let transcriptionURL = URL(string: "http://127.0.0.1:8765/transcribe") else {
            throw OpenAIAudioTranscriptionProviderError(message: "Invalid local STT server URL")
        }

        let requestBody: [String: Any] = [
            "audioBase64": wavAudioData.base64EncodedString()
        ]

        var request = URLRequest(url: transcriptionURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIAudioTranscriptionProviderError(message: "Local STT server returned an invalid response")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let responseText = String(data: data, encoding: .utf8) ?? "Unknown local STT server error"
            throw OpenAIAudioTranscriptionProviderError(message: "Local STT server failed: \(responseText)")
        }

        guard let responseJSON = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenAIAudioTranscriptionProviderError(message: "Local STT server returned malformed JSON")
        }

        if let transcriptText = responseJSON["text"] as? String {
            return transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        throw OpenAIAudioTranscriptionProviderError(message: "Local STT server response missing transcript text")
    }

    private func deliverFinalTranscript(_ transcriptText: String) {
        guard !hasDeliveredFinalTranscript else { return }
        hasDeliveredFinalTranscript = true
        onFinalTranscriptReady(transcriptText)
    }

    private func runOnStateQueueSynchronously(_ work: () -> Void) {
        if DispatchQueue.getSpecific(key: stateQueueSpecificKey) != nil {
            work()
        } else {
            stateQueue.sync(execute: work)
        }
    }

    deinit {
        cancel()
    }
}
