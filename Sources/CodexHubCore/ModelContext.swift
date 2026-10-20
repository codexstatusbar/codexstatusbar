import Foundation

/// Context windows of Claude models. Claude Code does not log the window in a transcript, but it keeps each model's
/// `runtime.max_input_tokens` in its local model catalog, which is the authoritative source. Anthropic's model overview
/// (every Claude 5 model has 1M tokens) only fills in for a model the catalog does not list. Anything else has no
/// window: it is never guessed.
public enum ModelContext {
    private static let oneMillionFamilies = ["claude-fable-5", "claude-opus-5", "claude-sonnet-5", "claude-haiku-5", "claude-mythos-5"]

    /// `max_input_tokens` per model id from `cache/model-catalog/*.json` (`catalog.config.models[].runtime`).
    public static func windows(fromCatalog data: Data) -> [String: Int] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let catalog = root["catalog"] as? [String: Any], let config = catalog["config"] as? [String: Any],
              let models = config["models"] as? [[String: Any]] else { return [:] }
        var result: [String: Int] = [:]
        for model in models.prefix(1_000) {
            guard let id = model["id"] as? String, !id.isEmpty, id.utf8.count <= 128,
                  let runtime = model["runtime"] as? [String: Any],
                  let number = runtime["max_input_tokens"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue >= 1, number.doubleValue <= 100_000_000 else { continue }
            result[id] = Int(number.doubleValue)
        }
        return result
    }

    public static func window(forClaudeModel model: String, catalog: [String: Int] = [:]) -> Int? {
        if let known = catalog[model] { return known }
        let id = model.lowercased()
        if id.contains("[1m]") || oneMillionFamilies.contains(where: id.hasPrefix) { return 1_000_000 }
        return nil
    }
}
