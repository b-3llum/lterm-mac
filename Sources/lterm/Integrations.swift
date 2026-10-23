import Foundation
import LtermCore

/// Agent hook installers. Filled in by the Claude Code integration step.
enum Integrations {
    struct NotReady: Error, CustomStringConvertible {
        var description: String { "integrations are not built yet" }
    }

    static func run(_ action: IntegrationAction, target: String?, lterm: String) throws {
        throw NotReady()
    }
}
