//
//  LocalWhisperTranscriptionProvider.swift
//  leanring-buddy
//
//  Local transcription provider backed by Argmax WhisperKit.
//

import AVFoundation
import Foundation
import WhisperKit

struct LocalWhisperTranscriptionProviderError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

final class LocalWhisperTranscriptionProvider: BuddyTranscriptionProvider {
    let displayName = "Argmax WhisperKit"
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
        return LocalWhisperTranscriptionSession(
            keyterms: keyterms,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
    }
}

private final class LocalWhisperTranscriptionSession: BuddyStreamingTranscriptionSession {
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 8.0

    private static let targetSampleRate = 16_000

    private let keyterms: [String]
    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    private let stateQueue = DispatchQueue(label: "com.learningbuddy.argmaxwhisper.transcription")
    private let stateQueueSpecificKey = DispatchSpecificKey<UInt8>()
    private let audioPCM16Converter = BuddyPCM16AudioConverter(targetSampleRate: Double(targetSampleRate))

    private var bufferedPCM16AudioData = Data()
    private var hasRequestedFinalTranscript = false
    private var hasDeliveredFinalTranscript = false
    private var isCancelled = false
    private var transcriptionTask: Task<Void, Never>?

    init(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
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

        do {
            let transcriptText = try await transcribeWithArgmaxWhisperKit(bufferedPCM16AudioData: bufferedPCM16AudioData)
            guard !stateQueue.sync(execute: { isCancelled }) else { return }

            if !transcriptText.isEmpty {
                onTranscriptUpdate(transcriptText)
            }

            deliverFinalTranscript(transcriptText)
        } catch {
            guard !stateQueue.sync(execute: { isCancelled }) else { return }
            print("[Argmax WhisperKit] ❌ Transcription failed: \(error.localizedDescription)")
            onError(error)
        }
    }

    private func transcribeWithArgmaxWhisperKit(bufferedPCM16AudioData: Data) async throws -> String {
        let audioSamples = convertPCM16DataToFloatSamples(bufferedPCM16AudioData)
        guard !audioSamples.isEmpty else { return "" }

        let whisperKit = try await ArgmaxWhisperKitStore.shared.resolveWhisperKit()
        let transcriptionResults = try await whisperKit.transcribe(
            audioArray: audioSamples,
            decodeOptions: DecodingOptions(language: "en")
        )

        return transcriptionResults
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func convertPCM16DataToFloatSamples(_ pcm16Data: Data) -> [Float] {
        let sampleCount = pcm16Data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return [] }

        return pcm16Data.withUnsafeBytes { rawBufferPointer in
            let pcm16Buffer = rawBufferPointer.bindMemory(to: Int16.self)
            return pcm16Buffer.prefix(sampleCount).map { pcm16Sample in
                Float(pcm16Sample) / Float(Int16.max)
            }
        }
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

private actor ArgmaxWhisperKitStore {
    static let shared = ArgmaxWhisperKitStore()

    private var whisperKit: WhisperKit?

    func resolveWhisperKit() async throws -> WhisperKit {
        if let whisperKit {
            return whisperKit
        }

        let newWhisperKit = try await WhisperKit()
        whisperKit = newWhisperKit
        return newWhisperKit
    }
}
