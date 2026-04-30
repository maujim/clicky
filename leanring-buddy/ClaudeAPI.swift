//
//  ClaudeAPI.swift
//  OpenAI-compatible local vision chat client with streaming support.
//

import Foundation

/// Vision API helper with streaming for progressive text display.
/// Sends OpenAI-compatible chat-completions requests to the configured endpoint.
class ClaudeAPI { // TODO: Rename to VisionChatClient in a project-file-aware cleanup pass.
    private let apiURL: URL
    private let apiKey: String?
    var model: String
    private let session: URLSession

    init(proxyURL: String, model: String, apiKey: String? = nil) {
        self.apiURL = URL(string: proxyURL)!
        self.model = model
        self.apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true
        config.urlCache = nil
        config.httpCookieStorage = nil
        self.session = URLSession(configuration: config)
    }

    private func makeAPIRequest() -> URLRequest {
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        return request
    }

    /// Detects the MIME type of image data by inspecting the first bytes.
    private func detectImageMediaType(for imageData: Data) -> String {
        if imageData.count >= 4 {
            let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
            let firstFourBytes = [UInt8](imageData.prefix(4))
            if firstFourBytes == pngSignature {
                return "image/png"
            }
        }
        return "image/jpeg"
    }

    /// Send a vision request with streaming.
    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()
        var request = makeAPIRequest()

        var messages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt]
        ]

        for (userPlaceholder, assistantResponse) in conversationHistory {
            messages.append(["role": "user", "content": userPlaceholder])
            messages.append(["role": "assistant", "content": assistantResponse])
        }

        var userContentBlocks: [[String: Any]] = []
        userContentBlocks.append([
            "type": "text",
            "text": userPrompt
        ])

        for image in images {
            userContentBlocks.append([
                "type": "text",
                "text": image.label
            ])

            let mediaType = detectImageMediaType(for: image.data)
            let base64DataURL = "data:\(mediaType);base64,\(image.data.base64EncodedString())"
            userContentBlocks.append([
                "type": "image_url",
                "image_url": ["url": base64DataURL]
            ])
        }

        messages.append([
            "role": "user",
            "content": userContentBlocks
        ])

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "stream": true,
            "messages": messages
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        let payloadMB = Double(bodyData.count) / 1_048_576.0
        print("🌐 Local vision streaming request: \(String(format: "%.1f", payloadMB))MB, \(images.count) image(s), model=\(model)")

        let (byteStream, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "ClaudeAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"]
            )
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            var errorBodyChunks: [String] = []
            for try await line in byteStream.lines {
                errorBodyChunks.append(line)
            }
            let errorBody = errorBodyChunks.joined(separator: "\n")
            throw NSError(
                domain: "ClaudeAPI",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "API Error (\(httpResponse.statusCode)): \(errorBody)"]
            )
        }

        var accumulatedResponseText = ""

        for try await line in byteStream.lines {
            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6))

            guard jsonString != "[DONE]" else { break }

            guard let jsonData = jsonString.data(using: .utf8),
                  let eventPayload = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                continue
            }

            if let choices = eventPayload["choices"] as? [[String: Any]],
               let firstChoice = choices.first,
               let delta = firstChoice["delta"] as? [String: Any],
               let textChunk = delta["content"] as? String,
               !textChunk.isEmpty {
                accumulatedResponseText += textChunk
                let currentAccumulatedText = accumulatedResponseText
                await onTextChunk(currentAccumulatedText)
            }
        }

        let duration = Date().timeIntervalSince(startTime)
        return (text: accumulatedResponseText, duration: duration)
    }

    /// Non-streaming fallback for validation requests where we don't need progressive display.
    func analyzeImage(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()
        var request = makeAPIRequest()

        var messages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt]
        ]

        for (userPlaceholder, assistantResponse) in conversationHistory {
            messages.append(["role": "user", "content": userPlaceholder])
            messages.append(["role": "assistant", "content": assistantResponse])
        }

        var userContentBlocks: [[String: Any]] = []
        userContentBlocks.append([
            "type": "text",
            "text": userPrompt
        ])

        for image in images {
            userContentBlocks.append([
                "type": "text",
                "text": image.label
            ])

            let mediaType = detectImageMediaType(for: image.data)
            let base64DataURL = "data:\(mediaType);base64,\(image.data.base64EncodedString())"
            userContentBlocks.append([
                "type": "image_url",
                "image_url": ["url": base64DataURL]
            ])
        }

        messages.append([
            "role": "user",
            "content": userContentBlocks
        ])

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 256,
            "stream": false,
            "messages": messages
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        let payloadMB = Double(bodyData.count) / 1_048_576.0
        print("🌐 Local vision request: \(String(format: "%.1f", payloadMB))MB, \(images.count) image(s), model=\(model)")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let responseString = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(
                domain: "ClaudeAPI",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: "API Error: \(responseString)"]
            )
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        guard let choices = json?["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let text = message["content"] as? String else {
            throw NSError(
                domain: "ClaudeAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid response format"]
            )
        }

        let duration = Date().timeIntervalSince(startTime)
        return (text: text, duration: duration)
    }
}
