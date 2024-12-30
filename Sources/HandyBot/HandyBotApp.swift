import SwiftUI
import Logging
import Collections
import Security

@main
struct HandyBotApp: App {
    @StateObject private var dataManager = DataManager.shared
    private let logger = Logger(label: "com.handybot.app")
    @State private var apiKey = ""
    @State private var showingAPIKeyAlert = false
    @State private var showError = false
    @State private var errorMessage = ""
    
    init() {
        // Configure logging
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardOutput(label: label)
            handler.logLevel = .debug
            return handler
        }
    }
    
    var body: some Scene {
        WindowGroup {
            ProjectListView()
                .onAppear {
                    Task {
                        do {
                            try await dataManager.loadProjects()
                            logger.info("Successfully loaded projects")
                            let apiKey = try dataManager.getAPIKey()
                            showingAPIKeyAlert = apiKey.isEmpty
                        } catch {
                            logger.error("Failed to initialize: \(error)")
                            errorMessage = error.localizedDescription
                            showError = true
                        }
                    }
                }
                .alert("Error", isPresented: $showError) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(errorMessage)
                }
                .alert("API Key Required", isPresented: $showingAPIKeyAlert) {
                    TextField("Enter Claude API Key", text: $apiKey)
                        .textContentType(.password)
                    Button("Save") {
                        Task {
                            do {
                                try await dataManager.setAPIKey(apiKey)
                                logger.info("API key saved successfully")
                                showingAPIKeyAlert = false
                                apiKey = ""
                            } catch {
                                logger.error("Failed to save API key: \(error)")
                                errorMessage = error.localizedDescription
                                showError = true
                                showingAPIKeyAlert = false
                            }
                        }
                    }
                    Button("Cancel", role: .cancel) {
                        apiKey = ""
                        showingAPIKeyAlert = false
                    }
                } message: {
                    Text("Please enter your Claude API key to enable AI assistance")
                }
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(action: { showingAPIKeyAlert = true }) {
                            Image(systemName: "key")
                        }
                    }
                }
        }
    }
}

enum DataManagerError: LocalizedError {
    case encodingError(Error)
    case savingError(Error)
    case decodingError(Error)
    case keychainError(Error)
    
    var errorDescription: String? {
        switch self {
        case .encodingError(let error):
            return "Failed to encode data: \(error.localizedDescription)"
        case .savingError(let error):
            return "Failed to save data: \(error.localizedDescription)"
        case .decodingError(let error):
            return "Failed to decode data: \(error.localizedDescription)"
        case .keychainError(let error):
            return "Keychain operation failed: \(error.localizedDescription)"
        }
    }
}

@MainActor
class DataManager: ObservableObject {
    static let shared = DataManager()
    private let logger = Logger(label: "com.handybot.DataManager")
    
    @Published var projects: [RepairProject] = []
    private let projectsKey = "handybot_projects"
    let apiKeyKey = "claude_api_key"
    
    private init() {
        logger.info("DataManager initialized")
    }
    
    func getAPIKey() throws -> String {
        do {
            if let key = try KeychainHelper.load(key: apiKeyKey) {
                logger.debug("Successfully retrieved API key from keychain")
                return String(decoding: key, as: UTF8.self)
            }
            logger.warning("No API key found in keychain")
            return ""
        } catch {
            logger.error("Failed to load API key from keychain: \(error)")
            throw DataManagerError.keychainError(error)
        }
    }
    
    func setAPIKey(_ newValue: String) async throws {
        if !newValue.isEmpty {
            do {
                let data = Data(newValue.utf8)
                try KeychainHelper.save(key: apiKeyKey, data: data)
                logger.info("API key saved to keychain")
                objectWillChange.send()
            } catch {
                logger.error("Failed to save API key to keychain: \(error)")
                throw DataManagerError.keychainError(error)
            }
        } else {
            do {
                try KeychainHelper.delete(key: apiKeyKey)
                logger.info("API key deleted from keychain")
                objectWillChange.send()
            } catch {
                logger.error("Failed to delete API key from keychain: \(error)")
                throw DataManagerError.keychainError(error)
            }
        }
    }
    
    // Computed property for backward compatibility
    var claudeAPIKey: String {
        get { (try? getAPIKey()) ?? "" }
        set {
            if !newValue.isEmpty {
                Task { @MainActor in
                    do {
                        try await setAPIKey(newValue)
                    } catch {
                        logger.error("Failed to set API key: \(error)")
                    }
                }
            }
        }
    }
    
    func saveProject(_ project: RepairProject) async throws {
        logger.info("Saving project: \(project.title)")
        
        await MainActor.run {
            if let index = projects.firstIndex(where: { $0.id == project.id }) {
                logger.debug("Updating existing project at index \(index)")
                projects[index] = project
            } else {
                logger.debug("Adding new project")
                projects.append(project)
            }
            objectWillChange.send()
        }
        
        do {
            try await saveProjects()
            logger.info("Project saved successfully")
        } catch {
            logger.error("Failed to save project: \(error)")
            throw DataManagerError.savingError(error)
        }
    }
    
    func loadProjects() async throws {
        logger.info("Loading projects from UserDefaults")
        
        if let data = UserDefaults.standard.data(forKey: projectsKey) {
            do {
                let decoded = try JSONDecoder().decode([RepairProject].self, from: data)
                await MainActor.run {
                    projects = decoded.sorted(by: { $0.lastUpdated > $1.lastUpdated })
                    objectWillChange.send()
                }
                logger.info("Successfully loaded \(projects.count) projects")
            } catch {
                logger.error("Failed to decode projects: \(error)")
                throw DataManagerError.decodingError(error)
            }
        } else {
            logger.info("No projects found in UserDefaults")
            await MainActor.run {
                projects = []
                objectWillChange.send()
            }
        }
    }
    
    private func saveProjects() async throws {
        logger.debug("Encoding projects for saving")
        
        do {
            let encoded = try JSONEncoder().encode(projects)
            UserDefaults.standard.set(encoded, forKey: projectsKey)
            logger.info("Projects saved successfully to UserDefaults")
        } catch {
            logger.error("Failed to encode projects: \(error)")
            throw DataManagerError.encodingError(error)
        }
    }
}

enum KeychainError: LocalizedError {
    case saveError(OSStatus)
    case loadError(OSStatus)
    case deleteError(OSStatus)
    case dataConversionError
    
    var errorDescription: String? {
        switch self {
        case .saveError(let status):
            return "Failed to save to Keychain (status: \(status))"
        case .loadError(let status):
            return "Failed to load from Keychain (status: \(status))"
        case .deleteError(let status):
            return "Failed to delete from Keychain (status: \(status))"
        case .dataConversionError:
            return "Failed to convert data"
        }
    }
}

enum KeychainHelper {
    private static let logger = Logger(label: "com.handybot.KeychainHelper")
    
    static func save(key: String, data: Data) throws {
        let query = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ] as [String: Any]
        
        // First attempt to delete any existing item
        _ = SecItemDelete(query as CFDictionary)
        
        // Then add the new item
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            logger.error("Failed to save to Keychain: \(status)")
            throw KeychainError.saveError(status)
        }
        logger.debug("Successfully saved data to Keychain for key: \(key)")
    }
    
    static func load(key: String) throws -> Data? {
        let query = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: kCFBooleanTrue!,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ] as [String: Any]
        
        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
        
        if status == errSecSuccess {
            guard let data = dataTypeRef as? Data else {
                logger.error("Failed to convert keychain item to Data")
                throw KeychainError.dataConversionError
            }
            logger.debug("Successfully loaded data from Keychain for key: \(key)")
            return data
        } else if status == errSecItemNotFound {
            logger.debug("No data found in Keychain for key: \(key)")
            return nil
        } else {
            logger.error("Failed to load from Keychain: \(status)")
            throw KeychainError.loadError(status)
        }
    }
    
    static func delete(key: String) throws {
        let query = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ] as [String: Any]
        
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess {
            logger.debug("Successfully deleted data from Keychain for key: \(key)")
        } else if status == errSecItemNotFound {
            logger.debug("No data found to delete in Keychain for key: \(key)")
        } else {
            logger.error("Failed to delete from Keychain: \(status)")
            throw KeychainError.deleteError(status)
        }
    }
}
