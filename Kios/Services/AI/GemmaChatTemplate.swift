import Foundation

enum GemmaChatTemplate {
    /// Renders a system + user message in Gemma 3's instruct format.
    /// Gemma's chat template prepends system content into the first user turn.
    static func render(system: String, user: String) -> String {
        let combinedUser: String
        if system.isEmpty {
            combinedUser = user
        } else {
            combinedUser = "\(system)\n\n\(user)"
        }
        return """
        <start_of_turn>user
        \(combinedUser)<end_of_turn>
        <start_of_turn>model

        """
    }
}
