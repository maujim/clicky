//
//  AppBundleConfiguration.swift
//  leanring-buddy
//
//  Shared helper for reading runtime configuration from the built app bundle.
//

import Foundation

enum LocalSpeechServiceBootstrapError: LocalizedError {
    case scriptNotFound(path: String)
    case serverDidNotBecomeHealthy(serviceName: String)

    var errorDescription: String? {
        switch self {
        case .scriptNotFound(let path):
            return "Local speech service script not found at path: \(path)"
        case .serverDidNotBecomeHealthy(let serviceName):
            return "Local speech service did not become healthy: \(serviceName)"
        }
    }
}

enum AppBundleConfiguration {
    static func stringValue(forKey key: String) -> String? {
        if let value = Bundle.main.object(forInfoDictionaryKey: key) as? String {
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedValue.isEmpty {
                return trimmedValue
            }
        }

        guard let resourceInfoPath = Bundle.main.path(forResource: "Info", ofType: "plist"),
              let resourceInfo = NSDictionary(contentsOfFile: resourceInfoPath),
              let value = resourceInfo[key] as? String else {
            return nil
        }

        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    static func localSpeechScriptURL(scriptFileName: String) -> URL? {
        // During development, #filePath points at the source file in the repo.
        // We derive the project root from this file so helper Python scripts
        // can be launched without adding them to the app bundle.
        let sourceFileURL = URL(fileURLWithPath: #filePath)
        let projectRootURL = sourceFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scriptURL = projectRootURL
            .appendingPathComponent("local_speech", isDirectory: true)
            .appendingPathComponent(scriptFileName)

        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            return nil
        }

        return scriptURL
    }
}

@MainActor
final class LocalSpeechServiceBootstrap {
    static let shared = LocalSpeechServiceBootstrap()

    private var sttServerProcess: Process?
    private var ttsServerProcess: Process?

    private var didAttemptStartup = false

    func ensureServersRunning(
        whisperModelName: String,
        ttsModelName: String,
        ttsVoiceName: String,
        ttsLanguageCode: String
    ) async throws {
        if didAttemptStartup, areBothServersRunning {
            return
        }

        didAttemptStartup = true

        if sttServerProcess == nil || sttServerProcess?.isRunning == false {
            try launchSTTServer(whisperModelName: whisperModelName)
        }

        if ttsServerProcess == nil || ttsServerProcess?.isRunning == false {
            try launchTTSServer(
                ttsModelName: ttsModelName,
                ttsVoiceName: ttsVoiceName,
                ttsLanguageCode: ttsLanguageCode
            )
        }

        let sttHealthy = await waitForHealthcheck(urlString: "http://127.0.0.1:8765/health")
        guard sttHealthy else {
            throw LocalSpeechServiceBootstrapError.serverDidNotBecomeHealthy(serviceName: "stt")
        }

        let ttsHealthy = await waitForHealthcheck(urlString: "http://127.0.0.1:8766/health")
        guard ttsHealthy else {
            throw LocalSpeechServiceBootstrapError.serverDidNotBecomeHealthy(serviceName: "tts")
        }
    }

    func stopServers() {
        if let sttServerProcess, sttServerProcess.isRunning {
            sttServerProcess.terminate()
        }
        if let ttsServerProcess, ttsServerProcess.isRunning {
            ttsServerProcess.terminate()
        }
        sttServerProcess = nil
        ttsServerProcess = nil
        didAttemptStartup = false
    }

    private var areBothServersRunning: Bool {
        (sttServerProcess?.isRunning ?? false) && (ttsServerProcess?.isRunning ?? false)
    }

    private func launchSTTServer(whisperModelName: String) throws {
        guard let sttScriptURL = AppBundleConfiguration.localSpeechScriptURL(scriptFileName: "stt_server.py") else {
            throw LocalSpeechServiceBootstrapError.scriptNotFound(path: "local_speech/stt_server.py")
        }

        let sttProcess = Process()
        sttProcess.executableURL = URL(fileURLWithPath: resolveLocalUVExecutablePath())
        sttProcess.arguments = [
            "run",
            "--with", "mlx-whisper",
            "python", sttScriptURL.path
        ]

        var processEnvironment = buildSubprocessEnvironment()
        processEnvironment["CLICKY_STT_MODEL"] = whisperModelName
        processEnvironment["CLICKY_STT_HOST"] = "127.0.0.1"
        processEnvironment["CLICKY_STT_PORT"] = "8765"
        sttProcess.environment = processEnvironment

        let outputPipe = Pipe()
        sttProcess.standardOutput = outputPipe
        sttProcess.standardError = outputPipe

        try sttProcess.run()
        sttServerProcess = sttProcess
    }

    private func launchTTSServer(
        ttsModelName: String,
        ttsVoiceName: String,
        ttsLanguageCode: String
    ) throws {
        guard let ttsScriptURL = AppBundleConfiguration.localSpeechScriptURL(scriptFileName: "tts_server.py") else {
            throw LocalSpeechServiceBootstrapError.scriptNotFound(path: "local_speech/tts_server.py")
        }

        let ttsProcess = Process()
        ttsProcess.executableURL = URL(fileURLWithPath: resolveLocalUVExecutablePath())
        ttsProcess.arguments = [
            "run",
            "--with", "mlx-audio",
            "--with", "misaki",
            "--with", "soundfile",
            "python", ttsScriptURL.path
        ]

        var processEnvironment = buildSubprocessEnvironment()
        processEnvironment["CLICKY_TTS_MODEL"] = ttsModelName
        processEnvironment["CLICKY_TTS_VOICE"] = ttsVoiceName
        processEnvironment["CLICKY_TTS_LANGUAGE_CODE"] = ttsLanguageCode
        processEnvironment["CLICKY_TTS_HOST"] = "127.0.0.1"
        processEnvironment["CLICKY_TTS_PORT"] = "8766"
        ttsProcess.environment = processEnvironment

        let outputPipe = Pipe()
        ttsProcess.standardOutput = outputPipe
        ttsProcess.standardError = outputPipe

        try ttsProcess.run()
        ttsServerProcess = ttsProcess
    }

    private func waitForHealthcheck(urlString: String) async -> Bool {
        guard let url = URL(string: urlString) else { return false }

        for _ in 0..<30 {
            do {
                let (_, response) = try await URLSession.shared.data(from: url)
                if let httpResponse = response as? HTTPURLResponse,
                   (200...299).contains(httpResponse.statusCode) {
                    return true
                }
            } catch {
                // Keep retrying until timeout
            }

            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        return false
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
}
