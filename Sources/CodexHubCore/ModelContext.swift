import Foundation

/// Context windows of Claude models. Claude Code does not log the window in a transcript, but it keeps each model's
/// `runtime.max_input_tokens` in its local model catalog (`cache/model-catalog/*.json`). That catalog is the only
/// source: a model it does not list has no window, which is never guessed from its name.
public enum ModelContext {
    /// `max_input_tokens` per model id from `catalog.config.models[].runtime`; malformed entries are skipped.
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
}
