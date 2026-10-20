/// Context windows of Claude models. Claude Code does not log the window, so it comes from Anthropic's model
/// overview (every current Claude 5 model has 1M tokens). A model that is not in the table has no window: it is never guessed.
public enum ModelContext {
    private static let oneMillionFamilies = ["claude-fable-5", "claude-opus-5", "claude-sonnet-5", "claude-haiku-5", "claude-mythos-5"]

    public static func window(forClaudeModel model: String) -> Int? {
        let id = model.lowercased()
        if id.contains("[1m]") || oneMillionFamilies.contains(where: id.hasPrefix) { return 1_000_000 }
        return nil
    }
}
