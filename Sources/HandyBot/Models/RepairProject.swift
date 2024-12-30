import Foundation
import UIKit
import Logging

struct RepairProject: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var createdAt: Date
    var lastUpdated: Date
    var messages: [Message]
    
    private static let logger = Logger(label: "com.handybot.RepairProject")
    
    init(title: String) {
        self.id = UUID()
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.createdAt = Date()
        self.lastUpdated = Date()
        self.messages = []
        
        RepairProject.logger.info("Created new repair project: '\(title)' with ID: \(id)")
    }
    
    // Hashable conformance
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    // Equatable conformance (required by Hashable)
    static func == (lhs: RepairProject, rhs: RepairProject) -> Bool {
        lhs.id == rhs.id
    }
    
    mutating func addMessage(_ message: Message) {
        messages.append(message)
        lastUpdated = Date()
        RepairProject.logger.debug("Added message to project '\(title)': \(message.content.prefix(50))...")
    }
    
    mutating func updateTitle(_ newTitle: String) {
        let oldTitle = title
        title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        lastUpdated = Date()
        RepairProject.logger.info("Updated project title from '\(oldTitle)' to '\(title)'")
    }
}

struct Message: Identifiable, Codable {
    let id: UUID
    let content: String
    let timestamp: Date
    let isUser: Bool
    let attachments: [Attachment]
    
    private static let logger = Logger(label: "com.handybot.Message")
    
    init(content: String, isUser: Bool, attachments: [Attachment] = []) {
        self.id = UUID()
        self.content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        self.timestamp = Date()
        self.isUser = isUser
        self.attachments = attachments
        
        Message.logger.debug("""
            Created new message:
            - ID: \(id)
            - IsUser: \(isUser)
            - Attachments: \(attachments.count)
            - Content: \(content.prefix(50))...
            """)
    }
}

struct Attachment: Identifiable, Codable {
    let id: UUID
    let type: AttachmentType
    let filename: String
    let localPath: String
    
    private static let logger = Logger(label: "com.handybot.Attachment")
    
    // For encoding/decoding UIImage
    var image: UIImage? {
        get {
            guard type == .image else {
                Attachment.logger.warning("Attempted to get image for non-image attachment type: \(type)")
                return nil
            }
            
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: localPath))
                guard let image = UIImage(data: data) else {
                    Attachment.logger.error("Failed to create UIImage from data at path: \(localPath)")
                    return nil
                }
                Attachment.logger.debug("Successfully loaded image from path: \(localPath)")
                return image
            } catch {
                Attachment.logger.error("Failed to load image data: \(error.localizedDescription)")
                return nil
            }
        }
        set {
            guard let image = newValue else {
                Attachment.logger.warning("Attempted to save nil image")
                return
            }
            
            guard let data = image.jpegData(compressionQuality: 0.8) else {
                Attachment.logger.error("Failed to create JPEG data from image")
                return
            }
            
            do {
                try data.write(to: URL(fileURLWithPath: localPath))
                Attachment.logger.debug("Successfully saved image to path: \(localPath)")
            } catch {
                Attachment.logger.error("Failed to write image data: \(error.localizedDescription)")
            }
        }
    }
    
    init(image: UIImage) {
        self.id = UUID()
        self.type = .image
        self.filename = "\(UUID().uuidString).jpg"
        
        Attachment.logger.info("Creating new image attachment with ID: \(id)")
        
        // Create documents directory path for storing images
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let attachmentsPath = documentsPath.appendingPathComponent("attachments")
        let imagePath = attachmentsPath.appendingPathComponent(filename)
        self.localPath = imagePath.path
        
        // Ensure attachments directory exists
        do {
            try FileManager.default.createDirectory(
                at: attachmentsPath,
                withIntermediateDirectories: true
            )
            Attachment.logger.debug("Created or verified attachments directory at: \(attachmentsPath.path)")
        } catch {
            Attachment.logger.error("Failed to create attachments directory: \(error.localizedDescription)")
        }
        
        // Save initial image
        self.image = image
    }
}

enum AttachmentType: String, Codable {
    case image
    // Can be extended for other types like video, audio, etc.
}
