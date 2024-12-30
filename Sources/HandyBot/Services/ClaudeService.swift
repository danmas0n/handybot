import Foundation
import UIKit
import Logging

enum ClaudeError: Error {
    case invalidResponse
    case networkError(Error)
    case apiError(String)
    case imageEncodingError
}

struct ClaudeResponse: Codable {
    let id: String
    let type: String
    let role: String
    let model: String
    let content: [Content]
    let usage: Usage
    let stop_reason: String?
    let stop_sequence: String?
    
    struct Content: Codable {
        let type: String
        let text: String
    }
    
    struct Usage: Codable {
        let input_tokens: Int
        let output_tokens: Int
    }
}

struct ClaudeErrorResponse: Codable {
    let type: String
    let error: Error
    
    struct Error: Codable {
        let type: String
        let message: String
        let status_code: Int?
    }
}

class ClaudeService {
    private let dataManager: DataManager
    private let baseURL = "https://api.anthropic.com/v1/messages"
    private let logger = Logger(label: "com.handybot.ClaudeService")
    private let systemPrompt = """
        You are a helpful assistant specializing in home repairs and DIY projects. \
        Analyze any images provided and give clear, safe advice for fixing issues. \
        If you're unsure about safety implications, always recommend consulting a professional. \
        When giving advice:
        1. Start with safety considerations
        2. List required tools and materials
        3. Provide step-by-step instructions
        4. Mention common pitfalls to avoid
        5. Suggest when to call a professional
        """
    
    init(dataManager: DataManager) {
        self.dataManager = dataManager
        logger.info("ClaudeService initialized")
    }
    
    @MainActor private func getAPIKey() throws -> String {
        let apiKey = try dataManager.getAPIKey()
        guard !apiKey.isEmpty else {
            logger.error("API key not configured")
            throw ClaudeError.apiError("API key not configured")
        }
        logger.debug("Retrieved API key (starts with: '\(String(apiKey.prefix(4)))...')")
        return apiKey
    }
    
    func sendMessage(_ message: String, withImages images: [UIImage] = [], projectContext: [Message]) async throws -> String {
        logger.info("Sending message to Claude API", metadata: [
            "images": .stringConvertible(images.count),
            "context_messages": .stringConvertible(projectContext.count)
        ])
        
        var messages: [[String: Any]] = []
        
        // Skip the last message if it matches our current message
        let contextToUse = message == projectContext.last?.content ? 
            projectContext.dropLast() : projectContext
        
        // Build conversation history first
        for msg in contextToUse {
            if msg.attachments.isEmpty {
                // If no attachments, use simple string content
                messages.append([
                    "role": msg.isUser ? "user" : "assistant",
                    "content": msg.content
                ])
            } else {
                // If has attachments, use content blocks array
                var content: [[String: Any]] = []
                content.append([
                    "type": "text",
                    "text": msg.content
                ])
                
                // Add image attachments
                for attachment in msg.attachments where attachment.type == .image {
                    if let image = attachment.image,
                       let base64Image = image.jpegData(compressionQuality: 0.8)?.base64EncodedString() {
                        content.append([
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": "image/jpeg",
                                "data": base64Image
                            ]
                        ])
                    }
                }
                
                messages.append([
                    "role": msg.isUser ? "user" : "assistant",
                    "content": content
                ])
            }
        }
        
        // Add current message last
        if images.isEmpty {
            // If no images, use simple string content
            messages.append([
                "role": "user",
                "content": message
            ])
        } else {
            // If has images, use content blocks array
            var currentContent: [[String: Any]] = [
                ["type": "text", "text": message]
            ]
            
            // Add images
            for image in images {
                guard let base64Image = image.jpegData(compressionQuality: 0.8)?.base64EncodedString() else {
                    throw ClaudeError.imageEncodingError
                }
                currentContent.append([
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": "image/jpeg",
                        "data": base64Image
                    ]
                ])
            }
            
            messages.append([
                "role": "user",
                "content": currentContent
            ])
        }
        
        // Create request
        guard let url = URL(string: baseURL) else {
            logger.error("Invalid API URL")
            throw ClaudeError.invalidResponse
        }
        
        let apiKey = try await getAPIKey()
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        request.addValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        
        let requestBody: [String: Any] = [
            "model": "claude-3-5-sonnet-20241022",
            "max_tokens": 4096,
            "messages": messages,
            "temperature": 0.7,
            "system": systemPrompt
        ]
        
        let requestData = try JSONSerialization.data(withJSONObject: requestBody)
        request.httpBody = requestData
        
        if let requestString = String(data: requestData, encoding: .utf8) {
            // Mask the API key in logs
            var maskedRequest = requestString
            if let apiKey = try? await getAPIKey() {
                maskedRequest = maskedRequest.replacingOccurrences(of: apiKey, with: "API_KEY_MASKED")
            }
            logger.debug("Request body: '\(maskedRequest)'")
        }
        
        // Send request
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            logger.error("Invalid response type")
            throw ClaudeError.invalidResponse
        }
        
        // Log response headers (excluding sensitive info)
        var safeHeaders = httpResponse.allHeaderFields
        safeHeaders.removeValue(forKey: "Authorization")
        safeHeaders.removeValue(forKey: "Set-Cookie")
        logger.debug("Response headers: \(String(describing: safeHeaders))")
        
        // Always log response for debugging
        if let responseString = String(data: data, encoding: .utf8) {
            logger.debug("Response body: '\(responseString)'")
        }
        
        if !(200...299).contains(httpResponse.statusCode) {
            logger.error("API request failed", metadata: ["status_code": .stringConvertible(httpResponse.statusCode)])
            
            // Try to parse error response
            if let errorResponse = try? JSONDecoder().decode(ClaudeErrorResponse.self, from: data) {
                let errorMessage = "Claude API error (\(errorResponse.error.type)): \(errorResponse.error.message)"
                logger.error("\(errorMessage)")
                throw ClaudeError.apiError(errorMessage)
            } else if let responseString = String(data: data, encoding: .utf8) {
                logger.error("Raw error response: '\(responseString)'")
                throw ClaudeError.apiError("API request failed with status \(httpResponse.statusCode)")
            } else {
                throw ClaudeError.apiError("API request failed with status \(httpResponse.statusCode)")
            }
        }
        
        do {
            let decoder = JSONDecoder()
            let response = try decoder.decode(ClaudeResponse.self, from: data)
            guard let message = response.content.first?.text else {
                logger.error("No text content in response")
                throw ClaudeError.invalidResponse
            }
            
            logger.info("Successfully received response from Claude API", metadata: [
                "input_tokens": .stringConvertible(response.usage.input_tokens),
                "output_tokens": .stringConvertible(response.usage.output_tokens),
                "stop_reason": .string(response.stop_reason ?? "unknown")
            ])
            logger.debug("Response length: \(message.count) characters")
            return message
        } catch {
            logger.error("JSON parsing error: \(String(describing: error))")
            throw ClaudeError.invalidResponse
        }
    }
}
