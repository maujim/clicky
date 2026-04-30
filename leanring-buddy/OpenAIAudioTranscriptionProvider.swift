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
        let temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("clicky-whisper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)

        defer {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }

        let inputAudioFileURL = temporaryDirectoryURL.appendingPathComponent("input.wav")
        try wavAudioData.write(to: inputAudioFileURL)

        var processOutput = ""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: resolveLocalUVExecutablePath())
        process.arguments = [
            "run", "--with", "mlx-whisper", "mlx_whisper",
            inputAudioFileURL.path,
            "--model", localWhisperModelName
        ]
        process.environment = buildSubprocessEnvironment()

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let standardOutputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let standardErrorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let standardOutputText = String(data: standardOutputData, encoding: .utf8) ?? ""
        let standardErrorText = String(data: standardErrorData, encoding: .utf8) ?? ""
        processOutput = "\(standardOutputText)\n\(standardErrorText)"

        let normalizedProcessOutput = processOutput.trimmingCharacters(in: .whitespacesAndNewlines)

        guard process.terminationStatus == 0 else {
            throw OpenAIAudioTranscriptionProviderError(
                message: "Whisper MLX command failed: \(normalizedProcessOutput)"
            )
        }

        if normalizedProcessOutput.localizedCaseInsensitiveContains("filenotfounderror") ||
            normalizedProcessOutput.localizedCaseInsensitiveContains("no such file or directory") ||
            normalizedProcessOutput.localizedCaseInsensitiveContains("ffmpeg") ||
            normalizedProcessOutput.localizedCaseInsensitiveContains("traceback") {
            throw OpenAIAudioTranscriptionProviderError(
                message: "Whisper MLX command failed: \(normalizedProcessOutput)"
            )
        }

        let normalizedLines = processOutput
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if let finalTranscriptLine = normalizedLines.last(where: {
            !$0.hasPrefix("[") &&
            !$0.lowercased().contains("fetching") &&
            !$0.lowercased().contains("downloading")
        }) {
            return finalTranscriptLine
        }

        return ""
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

    private func resolveLocalUVExecutablePath() -> String {
        let knownUVExecutablePaths = [
            "/opt/homebrew/bin/uv",
            "/usr/local/bin/uv",
            "/Users/mukund/.local/bin/uv"
        ]

        if let firstExistingPath = knownUVExecutablePaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return firstExistingPath
        }

        return "uv"
    }

    private func buildSubprocessEnvironment() -> [String: String] {
        var processEnvironment = ProcessInfo.processInfo.environment
        let existingPath = processEnvironment["PATH"] ?? ""
        let requiredPathSegments = ["/opt/homebrew/bin", "/usr/local/bin", "/bin", "/usr/bin"]

        let mergedPath = ([existingPath] + requiredPathSegments)
            .joined(separator: ":")
            .split(separator: ":")
            .map(String.init)
            .filter { !$0.isEmpty }

        processEnvironment["PATH"] = Array(NSOrderedSet(array: mergedPath)).compactMap { $0 as? String }.joined(separator: ":")
        return processEnvironment
    }

    deinit {
        cancel()
    }
}
