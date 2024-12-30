import SwiftUI
import PhotosUI
import Logging

struct ChatView: View {
    @StateObject private var viewModel: ChatViewModel
    @State private var messageText = ""
    @State private var showingImagePicker = false
    @State private var selectedImages: [UIImage] = []
    private let logger = Logger(label: "com.handybot.ChatView")
    
    init(project: RepairProject) {
        _viewModel = StateObject(wrappedValue: ChatViewModel(project: project))
        logger.info("Initializing ChatView for project: \(project.title)")
    }
    
    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(viewModel.messages) { message in
                            MessageBubble(message: message)
                        }
                    }
                    .padding()
                }
                .onChange(of: viewModel.messages.count) { _ in
                    withAnimation {
                        proxy.scrollTo(viewModel.messages.last?.id, anchor: .bottom)
                    }
                }
            }
            
            // Selected images preview
            if !selectedImages.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(selectedImages.indices, id: \.self) { index in
                            Image(uiImage: selectedImages[index])
                                .resizable()
                                .scaledToFill()
                                .frame(width: 60, height: 60)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    Button(action: { selectedImages.remove(at: index) }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.white)
                                            .background(Color.black.opacity(0.5))
                                            .clipShape(Circle())
                                    }
                                    .padding(4),
                                    alignment: .topTrailing
                                )
                        }
                    }
                    .padding(.horizontal)
                }
                .frame(height: 80)
            }
            
            // Input area
            VStack(spacing: 0) {
                Divider()
                HStack(alignment: .bottom, spacing: 8) {
                    Button(action: { showingImagePicker = true }) {
                        Image(systemName: "photo")
                            .font(.system(size: 24))
                    }
                    .foregroundColor(.accentColor)
                    
                    TextField("Message", text: $messageText)
                        .textFieldStyle(.roundedBorder)
                    
                    Button(action: sendMessage) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 24))
                    }
                    .foregroundColor(.accentColor)
                    .disabled(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && selectedImages.isEmpty)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
        }
        .navigationTitle(viewModel.project.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingImagePicker) {
            ImagePicker(images: $selectedImages)
        }
        .alert("Error", isPresented: Binding(
            get: { viewModel.error != nil },
            set: { show in
                if !show {
                    viewModel.error = nil
                }
            }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            if let error = viewModel.error {
                Text(error)
            }
        }
    }
    
    private func sendMessage() {
        logger.debug("Sending message with text: \(messageText), images: \(selectedImages.count)")
        Task {
            do {
                try await viewModel.sendMessage(messageText, withImages: selectedImages)
                logger.info("Message sent successfully")
                messageText = ""
                selectedImages.removeAll()
            } catch {
                logger.error("Failed to send message: \(error)")
                viewModel.error = error.localizedDescription
            }
        }
    }
}

struct MessageBubble: View {
    let message: Message
    
    var body: some View {
        HStack {
            if message.isUser {
                Spacer(minLength: 32)
            }
            
            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 4) {
                // Images grid
                if !message.attachments.isEmpty {
                    let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 2)
                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(message.attachments) { attachment in
                            if let image = attachment.image {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 150)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }
                }
                
                // Message text
                Text(message.content)
                    .padding(12)
                    .background(message.isUser ? Color.accentColor : Color(.systemGray5))
                    .foregroundColor(message.isUser ? .white : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            
            if !message.isUser {
                Spacer(minLength: 32)
            }
        }
    }
}

struct ImagePicker: UIViewControllerRepresentable {
    @Binding var images: [UIImage]
    @Environment(\.dismiss) private var dismiss
    
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.selectionLimit = 4
        config.filter = .images
        
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }
    
    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: ImagePicker
        
        init(_ parent: ImagePicker) {
            self.parent = parent
        }
        
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.dismiss()
            
            for result in results {
                result.itemProvider.loadObject(ofClass: UIImage.self) { image, error in
                    if let image = image as? UIImage {
                        DispatchQueue.main.async {
                            self.parent.images.append(image)
                        }
                    }
                }
            }
        }
    }
}

@MainActor
class ChatViewModel: ObservableObject {
    @Published private(set) var project: RepairProject
    @Published private(set) var messages: [Message]
    private let claudeService: ClaudeService
    private let dataManager = DataManager.shared
    @Published var error: String?
    private let logger = Logger(label: "com.handybot.ChatViewModel")
    
    init(project: RepairProject) {
        self.project = project
        self.messages = project.messages
        self.claudeService = ClaudeService(dataManager: dataManager)
        logger.info("ChatViewModel initialized for project: \(project.title) with \(messages.count) messages")
    }
    
    enum ChatError: LocalizedError {
        case missingAPIKey
        case messageSendFailed(Error)
        case saveFailed(Error)
        
        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "Please set your Claude API key in settings"
            case .messageSendFailed(let error):
                return "Failed to send message: \(error.localizedDescription)"
            case .saveFailed(let error):
                return "Failed to save project: \(error.localizedDescription)"
            }
        }
    }
    
    func sendMessage(_ text: String, withImages images: [UIImage]) async throws {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty || !images.isEmpty else { return }
        
        logger.info("Preparing to send message with \(images.count) images")
        
        // Create user message with attachments
        var attachments: [Attachment] = []
        for image in images {
            attachments.append(Attachment(image: image))
        }
        
        let userMessage = Message(
            content: trimmedText,
            isUser: true,
            attachments: attachments
        )
        
        // Check if this message already exists in the conversation
        guard messages.last?.content != trimmedText else {
            logger.debug("Skipping duplicate message")
            return
        }
        
        // Add user message
        messages.append(userMessage)
        project.messages = messages
        project.lastUpdated = Date()
        
        // Save project with user message
        do {
            try await dataManager.saveProject(project)
            logger.debug("Saved user message to project")
        } catch {
            // Rollback message addition
            messages.removeLast()
            project.messages = messages
            logger.error("Failed to save user message: \(error)")
            throw ChatError.saveFailed(error)
        }
        
        // Get AI response
        let response: String
        do {
            response = try await claudeService.sendMessage(
                text,
                withImages: images,
                projectContext: messages
            )
            logger.debug("Received response from Claude")
        } catch {
            // Rollback user message on AI failure
            messages.removeLast()
            project.messages = messages
            try? await dataManager.saveProject(project)
            logger.error("Error during message exchange: \(error)")
            throw ChatError.messageSendFailed(error)
        }
        
        // Add assistant message
        let assistantMessage = Message(
            content: response,
            isUser: false
        )
        
        messages.append(assistantMessage)
        project.messages = messages
        project.lastUpdated = Date()
        
        // Save project with assistant response
        do {
            try await dataManager.saveProject(project)
            logger.info("Successfully saved assistant response")
        } catch {
            // Rollback both messages on save failure
            messages.removeLast(2) // Remove both assistant and user messages
            project.messages = messages
            try? await dataManager.saveProject(project)
            logger.error("Failed to save assistant response: \(error)")
            throw ChatError.saveFailed(error)
        }
    }
}
