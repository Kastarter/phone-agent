import Foundation
import ActivityKit

struct AgentActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var status: String
        var step: Int
        var updatedAt: Date
        // Optional fields let an older, still-visible activity decode without
        // accidentally acquiring control authority after an app update.
        var controlSessionID: UUID? = nil
        var canPause: Bool? = nil
        var canStop: Bool? = nil
    }
    var taskID: UUID
}
