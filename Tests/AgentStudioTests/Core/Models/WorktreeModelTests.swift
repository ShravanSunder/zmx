import Foundation
import Testing

@testable import AgentStudio

@Suite(.serialized)
final class WorktreeModelTests {

    // MARK: - AgentType Properties

    @Test

    func test_agentType_displayName_claude() {
        // Assert
        #expect(AgentType.claude.displayName == "Claude Code")
    }

    @Test

    func test_agentType_displayName_allCasesNonEmpty() {
        // Assert
        for agent in AgentType.allCases {
            #expect(!(agent.displayName.isEmpty))
        }
    }

    @Test

    func test_agentType_shortName_allCasesNonEmpty() {
        // Assert
        for agent in AgentType.allCases {
            #expect(!(agent.shortName.isEmpty))
        }
    }

    @Test

    func test_agentType_command_customIsEmpty() {
        // Assert
        #expect(AgentType.custom.command.isEmpty)
    }

    @Test

    func test_agentType_command_nonCustomAreNonEmpty() {
        // Assert
        for agent in AgentType.allCases where agent != .custom {
            #expect(!(agent.command.isEmpty))
        }
    }

    @Test

    func test_agentType_caseIterable_hasFiveCases() {
        // Assert
        #expect(AgentType.allCases.count == 5)
    }

    // MARK: - Worktree Codable

    @Test

    func test_worktree_codable_roundTrip() throws {
        // Arrange
        let original = makeWorktree(
            name: "feature-x"
        )

        // Act
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Worktree.self, from: data)

        // Assert
        #expect(decoded.id == original.id)
        #expect(decoded.name == original.name)
        #expect(decoded.repoId == original.repoId)
    }

    @Test

    func test_worktree_codable_defaultValues_roundTrip() throws {
        // Arrange
        let original = makeWorktree()

        // Act
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Worktree.self, from: data)

        // Assert
        #expect(decoded.id == original.id)
        #expect(decoded.repoId == original.repoId)
        #expect(decoded.name == original.name)
        #expect(decoded.path == original.path)
        #expect(decoded.isMainWorktree == original.isMainWorktree)
    }

    // MARK: - Worktree Hashable

    @Test

    func test_worktree_hashable_differentFieldsNotEqual() {
        // Arrange
        let id = UUID()
        let wt1 = makeWorktree(id: id, name: "a")
        let wt2 = makeWorktree(id: id, name: "b")

        // Assert
        #expect(wt1 != wt2)
    }

    // MARK: - Worktree Init Defaults

    @Test

    func test_worktree_init_defaults() {
        // Act
        let wt = Worktree(repoId: UUID(), name: "test", path: URL(fileURLWithPath: "/tmp/test"))

        // Assert
        #expect(wt.isMainWorktree == false)
    }
}
