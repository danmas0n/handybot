import SwiftUI
import Logging

struct ProjectListView: View {
    @StateObject private var viewModel = ProjectListViewModel()
    @State private var showingNewProjectSheet = false
    @State private var selectedProject: RepairProject?
    private let logger = Logger(label: "com.handybot.ProjectListView")
    
    var body: some View {
        NavigationView {
            List(viewModel.projects) { project in
                NavigationLink(
                    destination: ChatView(project: project),
                    tag: project,
                    selection: $selectedProject,
                    label: { ProjectRowView(project: project) }
                )
            }
            .onChange(of: selectedProject) { project in
                if let project = project {
                    logger.debug("Navigating to chat for project: \(project.title)")
                }
            }
            .navigationTitle("HandyBot")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { showingNewProjectSheet = true }) {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingNewProjectSheet) {
                NewProjectView(viewModel: viewModel) { project in
                    logger.info("New project created, navigating to chat")
                    selectedProject = project
                }
            }
        }
    }
}

struct ProjectRowView: View {
    let project: RepairProject
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(project.title)
                .font(.headline)
            
            Text(project.lastUpdated, style: .relative)
                .font(.caption)
                .foregroundColor(.secondary)
            
            if let lastMessage = project.messages.last {
                Text(lastMessage.content)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

struct NewProjectView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: ProjectListViewModel
    @State private var title = ""
    @State private var showError = false
    @State private var errorMessage = ""
    private let logger = Logger(label: "com.handybot.NewProjectView")
    let onProjectCreated: (RepairProject) -> Void
    
    var body: some View {
        NavigationView {
            Form {
                TextField("What needs fixing?", text: $title)
            }
            .navigationTitle("New Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        logger.debug("Cancelling new project creation")
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        logger.debug("Create button tapped with title: \(title)")
                        Task {
                            do {
                                let project = try await viewModel.createProject(title: title)
                                logger.info("Project created successfully")
                                
                                // Send initial message
                                try await viewModel.sendInitialMessage(project: project, message: title)
                                logger.info("Initial message sent")
                                
                                await MainActor.run {
                                    dismiss()
                                    onProjectCreated(project)
                                }
                            } catch {
                                logger.error("Failed to create project: \(error)")
                                errorMessage = error.localizedDescription
                                showError = true
                            }
                        }
                    }
                    .disabled(title.isEmpty)
                }
            }
            .alert("Error", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
        }
    }
}

@MainActor
class ProjectListViewModel: ObservableObject {
    @ObservedObject private var dataManager = DataManager.shared
    private let logger = Logger(label: "com.handybot.ProjectListViewModel")
    
    var projects: [RepairProject] { dataManager.projects }
    
    func createProject(title: String) async throws -> RepairProject {
        logger.info("Creating new project with title: \(title)")
        let project = RepairProject(title: title)
        
        do {
            logger.info("Saving project to DataManager...")
            try await dataManager.saveProject(project)
            logger.info("Project saved successfully")
            return project
        } catch {
            logger.error("Failed to save project: \(error)")
            throw error
        }
    }
    
    func sendInitialMessage(project: RepairProject, message: String) async throws {
        logger.info("Sending initial message for project: \(project.title)")
        let chatViewModel = ChatViewModel(project: project)
        try await chatViewModel.sendMessage(message, withImages: [])
        // Update the project in DataManager after sending message
        try await dataManager.saveProject(project)
        logger.info("Initial message sent and project updated successfully")
    }
}
