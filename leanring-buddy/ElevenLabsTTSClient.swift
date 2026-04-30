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

    /// Synthesizes `text` via local Kokoro (mlx-audio) and plays the resulting audio.
    func speakText(_ text: String) async throws {
        try Task.checkCancellation()

        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else { return }

        let temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("clicky-tts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)

        defer {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: resolveLocalUVExecutablePath())
        process.arguments = [
            "run",
            "--with", "mlx-audio",
            "--with", "misaki",
            "--with", "soundfile",
            "python", "-m", "mlx_audio.tts.generate",
            "--model", localKokoroModelName,
            "--text", normalizedText,
            "--voice", localKokoroVoiceName,
            "--lang_code", localKokoroLanguageCode,
            "--output_path", temporaryDirectoryURL.path
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

        guard process.terminationStatus == 0 else {
            let errorBody = "\(standardOutputText)\n\(standardErrorText)"
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "LocalKokoroTTS",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Local TTS command failed: \(errorBody)"]
            )
        }

        let generatedAudioFileURLs = (try? FileManager.default.contentsOfDirectory(
            at: temporaryDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ))?.filter {
            ["wav", "mp3", "m4a"].contains($0.pathExtension.lowercased())
        } ?? []

        guard let newestGeneratedAudioFileURL = generatedAudioFileURLs.max(by: { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhsDate < rhsDate
        }) else {
            throw NSError(
                domain: "LocalKokoroTTS",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Local TTS did not generate an audio file."]
            )
        }

        let audioData = try Data(contentsOf: newestGeneratedAudioFileURL)
        let player = try AVAudioPlayer(data: audioData)
        self.audioPlayer = player
        player.play()
        print("🔊 Local Kokoro TTS: playing \(audioData.count / 1024)KB audio")
    }

    /// Whether TTS audio is currently playing back.
    var isPlaying: Bool {
        audioPlayer?.isPlaying ?? false
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

    /// Stops any in-progress playback immediately.
    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
    }
}
