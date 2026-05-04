//
//  LocalTTSClient.swift
//  leanring-buddy
//
//  Local TTS client backed by Argmax TTSKit.
//

import Foundation
import TTSKit

@MainActor
final class LocalTTSClient {
    private var ttsKit: TTSKit?
    private var playbackTask: Task<Void, Error>?

    /// Synthesizes `text` with Argmax TTSKit and streams it to the default audio output.
    func speakText(_ text: String) async throws {
        try Task.checkCancellation()

        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else { return }

        stopPlayback()

        let ttsKit = try await resolveTTSKit()
        let currentPlaybackTask = Task {
            _ = try await ttsKit.play(text: normalizedText)
        }
        playbackTask = currentPlaybackTask

        do {
            try await currentPlaybackTask.value
        } catch is CancellationError {
            await ttsKit.audioOutput.stopPlayback(waitForCompletion: false)
            throw CancellationError()
        } catch {
            await ttsKit.audioOutput.stopPlayback(waitForCompletion: false)
            throw error
        }

        playbackTask = nil
    }

    /// Whether TTS audio is currently generating or playing back.
    var isPlaying: Bool {
        playbackTask != nil
    }

    /// Stops any in-progress generation or playback immediately.
    func stopPlayback() {
        playbackTask?.cancel()
        playbackTask = nil

        if let ttsKit {
            Task {
                await ttsKit.audioOutput.stopPlayback(waitForCompletion: false)
            }
        }
    }

    private func resolveTTSKit() async throws -> TTSKit {
        if let ttsKit {
            return ttsKit
        }

        let newTTSKit = try await TTSKit()
        ttsKit = newTTSKit
        return newTTSKit
    }
}
