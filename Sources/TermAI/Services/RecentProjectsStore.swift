import Foundation
import SwiftUI

/// A recently opened project folder
struct RecentProject: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var path: String
    var lastOpened: Date
    
    init(id: UUID = UUID(), path: String, lastOpened: Date = Date()) {
        self.id = id
        self.path = path
        self.lastOpened = lastOpened
    }
    
    /// Display name is the last path component (folder name)
    var displayName: String {
        (path as NSString).lastPathComponent
    }
}

/// Thread-safe cache for recent projects (accessed from dock menu on non-main thread)
private final class RecentProjectsCache: @unchecked Sendable {
    static let shared = RecentProjectsCache()
    
    private let lock = NSLock()
    private var _projects: [RecentProject] = []
    
    var projects: [RecentProject] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _projects
        }
        set {
            lock.lock()
            _projects = newValue
            lock.unlock()
        }
    }
}

/// Manages recent project folders for quick access from dock menu
@MainActor
final class RecentProjectsStore: ObservableObject {
    static let shared = RecentProjectsStore()
    
    @Published private(set) var projects: [RecentProject] = [] {
        didSet {
            // Keep thread-safe cache updated for dock menu access
            RecentProjectsCache.shared.projects = projects
        }
    }
    
    /// Synchronous access to projects for dock menu (called from non-main-actor context)
    nonisolated static var cachedProjects: [RecentProject] {
        RecentProjectsCache.shared.projects
    }
    
    /// Maximum number of recent projects to keep
    private let maxProjects = 10
    
    /// Filename for persistence
    private let filename = "recent-projects.json"
    
    private init() {
        load()
    }
    
    /// Add a project path to recent projects
    /// If the path already exists, it will be moved to the top with updated timestamp
    func addProject(path: String) {
        // Normalize the path
        let normalizedPath = (path as NSString).standardizingPath
        
        // Skip home directory - it's always available via "New Tab at Home"
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        if normalizedPath == homePath {
            return
        }
        
        // Verify the directory exists
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalizedPath, isDirectory: &isDir),
              isDir.boolValue else {
            return
        }
        
        // Remove existing entry for this path (if any)
        projects.removeAll { $0.path == normalizedPath }
        
        // Add new entry at the beginning
        let project = RecentProject(path: normalizedPath)
        projects.insert(project, at: 0)
        
        // Trim to max size
        if projects.count > maxProjects {
            projects = Array(projects.prefix(maxProjects))
        }
        
        save()
    }
    
    /// Remove a specific project from the list
    func removeProject(id: UUID) {
        projects.removeAll { $0.id == id }
        save()
    }
    
    /// Clear all recent projects
    func clearAll() {
        projects.removeAll()
        save()
    }
    
    /// Save projects to disk
    private func save() {
        PersistenceService.saveJSONInBackground(projects, to: filename)
    }
    
    /// Load projects from disk
    private func load() {
        do {
            projects = try PersistenceService.loadJSON([RecentProject].self, from: filename)
            
            // Filter out any paths that no longer exist
            let validProjects = projects.filter { project in
                var isDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: project.path, isDirectory: &isDir) && isDir.boolValue
            }
            
            if validProjects.count != projects.count {
                projects = validProjects
                save()
            }
        } catch {
            // No saved projects or failed to load - start fresh
            projects = []
        }
    }
}
