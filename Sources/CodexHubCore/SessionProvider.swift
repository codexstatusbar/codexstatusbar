public enum SessionProvider: String, CaseIterable, Sendable {
    case codex, claude
    public var displayName: String { self == .codex ? "Codex" : "Claude" }
}
