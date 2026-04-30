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
        if let bundledScriptURL = Bundle.main.url(
            forResource: (scriptFileName as NSString).deletingPathExtension,
            withExtension: (scriptFileName as NSString).pathExtension,
            subdirectory: "local_speech"
        ), FileManager.default.fileExists(atPath: bundledScriptURL.path) {
            return bundledScriptURL
        }

        // Development fallback: #filePath points at the source file in the repo.
        // This keeps local iteration working before the helper scripts are added
        // to the app bundle's Copy Bundle Resources phase.
        let sourceFileURL = URL(fileURLWithPath: #filePath)
        let projectRootURL = sourceFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let developmentScriptURL = projectRootURL
            .appendingPathComponent("local_speech", isDirectory: true)
            .appendingPathComponent(scriptFileName)

        guard FileManager.default.fileExists(atPath: developmentScriptURL.path) else {
            return nil
        }

        return developmentScriptURL
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
        try await ensureSTTServerRunning(whisperModelName: whisperModelName)
        try await ensureTTSServerRunning(
            ttsModelName: ttsModelName,
            ttsVoiceName: ttsVoiceName,
            ttsLanguageCode: ttsLanguageCode
        )
        didAttemptStartup = true
    }

    func ensureSTTServerRunning(whisperModelName: String) async throws {
        if sttServerProcess?.isRunning == true {
            return
        }

        terminateStaleLocalSpeechServerProcesses(scriptFileName: "stt_server.py")
        try? await Task.sleep(nanoseconds: 300_000_000)

        try launchSTTServer(whisperModelName: whisperModelName)

        let sttHealthy = await waitForHealthcheck(urlString: "http://127.0.0.1:8765/health")
        guard sttHealthy else {
            throw LocalSpeechServiceBootstrapError.serverDidNotBecomeHealthy(serviceName: "stt")
        }
    }

    func ensureTTSServerRunning(
        ttsModelName: String,
        ttsVoiceName: String,
        ttsLanguageCode: String
    ) async throws {
        if ttsServerProcess?.isRunning == true {
            return
        }

        terminateStaleLocalSpeechServerProcesses(scriptFileName: "tts_server.py")
        try? await Task.sleep(nanoseconds: 300_000_000)

        try launchTTSServer(
            ttsModelName: ttsModelName,
            ttsVoiceName: ttsVoiceName,
            ttsLanguageCode: ttsLanguageCode
        )

        let ttsHealthy = await waitForHealthcheck(urlString: "http://127.0.0.1:8766/health")
        guard ttsHealthy else {
            throw LocalSpeechServiceBootstrapError.serverDidNotBecomeHealthy(serviceName: "tts")
        }
    }

    func stopServers() {
        stopSTTServer()
        if let ttsServerProcess, ttsServerProcess.isRunning {
            ttsServerProcess.terminate()
        }
        ttsServerProcess = nil
        didAttemptStartup = false
    }

    func restartSTTServer(whisperModelName: String) async throws {
        stopSTTServer()
        terminateStaleLocalSpeechServerProcesses(scriptFileName: "stt_server.py")
        try? await Task.sleep(nanoseconds: 300_000_000)
        try launchSTTServer(whisperModelName: whisperModelName)

        let sttHealthy = await waitForHealthcheck(urlString: "http://127.0.0.1:8765/health")
        guard sttHealthy else {
            throw LocalSpeechServiceBootstrapError.serverDidNotBecomeHealthy(serviceName: "stt")
        }
    }

    private func stopSTTServer() {
        if let sttServerProcess, sttServerProcess.isRunning {
            sttServerProcess.terminate()
        }
        sttServerProcess = nil
    }

    private func terminateStaleLocalSpeechServerProcesses(scriptFileName: String) {
        let pkillProcess = Process()
        pkillProcess.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkillProcess.arguments = ["-f", "local_speech/\(scriptFileName)"]
        pkillProcess.standardOutput = FileHandle.nullDevice
        pkillProcess.standardError = FileHandle.nullDevice

        do {
            try pkillProcess.run()
            pkillProcess.waitUntilExit()
        } catch {
            // If pkill is unavailable or finds nothing, launching below will still
            // surface a healthcheck failure if the port is actually blocked.
        }
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

        // The speech servers can emit model/runtime logs while processing audio.
        // If nobody drains a Pipe, the subprocess can eventually fail writes with
        // Broken pipe, which surfaces as intermittent transcription failures.
        sttProcess.standardOutput = FileHandle.nullDevice
        sttProcess.standardError = FileHandle.nullDevice

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

        // Keep subprocess logging from filling an undrained Pipe during long runs.
        ttsProcess.standardOutput = FileHandle.nullDevice
        ttsProcess.standardError = FileHandle.nullDevice

        try ttsProcess.run()
        ttsServerProcess = ttsProcess
    }

    private func waitForHealthcheck(urlString: String) async -> Bool {
        guard let url = URL(string: urlString) else { return false }

        // Give the subprocess time to import libraries and bind before first attempt.
        // Avoids noisy Connection refused console spam during initial startup.
        try? await Task.sleep(nanoseconds: 1_000_000_000)

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
        let homeDirectoryUVExecutablePath = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/uv")
            .path

        let knownUVExecutablePaths = [
            "/opt/homebrew/bin/uv",
            "/usr/local/bin/uv",
            homeDirectoryUVExecutablePath
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
