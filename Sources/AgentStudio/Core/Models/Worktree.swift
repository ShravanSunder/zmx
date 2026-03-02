import Foundation
import SwiftUI

/// A git worktree within a repo — structure-only.
/// All enrichment data (branch, status) comes from WorkspaceRepoCache via the event bus.
struct Worktree: Codable, Identifiable, Hashable {
    let id: UUID
    let repoId: UUID
    var name: String
    var path: URL
    var isMainWorktree: Bool

    /// Deterministic identity derived from filesystem path via SHA-256.
    /// Used for zmx session ID segment. Survives reinstall/data loss, breaks on directory move.
    var stableKey: String { StableKey.fromPath(path) }

    init(
        id: UUID = UUID(),
        repoId: UUID,
        name: String,
        path: URL,
        isMainWorktree: Bool = false
    ) {
        self.id = id
        self.repoId = repoId
        self.name = name
        self.path = path
        self.isMainWorktree = isMainWorktree
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.repoId = try container.decodeIfPresent(UUID.self, forKey: .repoId) ?? UUID()
        self.name = try container.decode(String.self, forKey: .name)
        self.path = try container.decode(URL.self, forKey: .path)
        self.isMainWorktree = try container.decodeIfPresent(Bool.self, forKey: .isMainWorktree) ?? false
    }
}

// MARK: - Agent Type

enum AgentType: String, Codable, CaseIterable {
    case claude
    case codex
    case gemini
    case aider
    case custom

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .gemini: return "Gemini CLI"
        case .aider: return "Aider"
        case .custom: return "Custom"
        }
    }

    var shortName: String {
        switch self {
        case .claude: return "CC"
        case .codex: return "CX"
        case .gemini: return "GM"
        case .aider: return "AD"
        case .custom: return "?"
        }
    }

    var command: String {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        case .gemini: return "gemini"
        case .aider: return "aider"
        case .custom: return ""
        }
    }

    var color: Color {
        switch self {
        case .claude: return .orange
        case .codex: return .green
        case .gemini: return .blue
        case .aider: return .purple
        case .custom: return .gray
        }
    }
}
