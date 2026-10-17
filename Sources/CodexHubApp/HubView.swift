import SwiftUI
import AppKit
import CodexHubCore

struct HubView: View {
    @Bindable var model: HubPresentation
    var height: CGFloat = 620
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if model.page != .overview {
                    Button("Back") { model.page = .overview }.keyboardShortcut("[", modifiers: .command)
                }
                Text(title).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                Spacer()
                Button("Close") { model.close?() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let error = model.error { Text("Collection unavailable: \(error)").textSelection(.enabled) }
                    if let notice = model.notice { Text(notice).textSelection(.enabled) }
                    switch model.page {
                    case .overview: overview
                    case .detail(let key):
                        if let session = model.sessions.first(where: { $0.id == key }) { detail(session) }
                        else { Text("This session is no longer available.") }
                    case .preferences: preferences
                    case .connection: connection
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            }.id(model.page)
            Divider()
            HStack {
                Text(model.freshness).font(.system(size: 11))
                Spacer()
                Button("Connection") { model.page = .connection }
                Button("Settings") { model.page = .preferences }.keyboardShortcut(",", modifiers: .command)
            }.padding(16)
        }
        .font(.system(size: 13)).frame(width: 400, height: height)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("Clear collected metadata?", isPresented: $model.confirmClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear metadata", role: .destructive) { model.clearMetadata?() }
        } message: { Text("Deletes Hub metadata only. Original Codex logs and sessions are kept.") }
    }
    private var title: String {
        switch model.page {
        case .overview: "Codex Hub"
        case .detail: "Session details"
        case .preferences: "Preferences"
        case .connection: "Connection"
        }
    }
    private var overview: some View {
        Group {
            modePicker
            Text("Observed CLI root subtotal").font(.headline)
            HStack { Text(model.measurementMode.label); Spacer(); Text(model.source) }.font(.system(size: 11))
            HStack(alignment: .firstTextBaseline) {
                Text(model.summary).font(.system(size: model.summary.count > 12 ? 28 : 42, weight: .semibold)).monospacedDigit()
                if model.aggregateRate != nil && model.error == nil { Text("tok/s") }
            }.accessibilityElement(children: .combine)
            Text("R = reported output over 10s. ≈ = visible-output estimate over 5s; excludes reasoning and tools. Neither is server generation speed.").font(.system(size: 11))
            Text("Partial · child scope unknown").font(.system(size: 11))
            value("Measurement coverage", model.coverage)
            if model.sessions.contains(where: { $0.monitor.connectivity == .connected && $0.activity == .approvalWait }) {
                Text("Approval is waiting in Codex. Respond in the original terminal; Hub never approves commands.")
            }
            Divider()
            if model.sessions.isEmpty {
                Text("No sessions discovered").font(.headline)
                Text("Check the configured Codex home and collection diagnostics.")
                Button("Check connection") { model.page = .connection; model.refresh?() }.disabled(model.busy || model.refresh == nil)
            } else if model.visibleSessions.isEmpty { Text("Idle sessions are hidden. Change this in Settings.") }
            ForEach(model.visibleSessions) { session in
                Button { model.page = .detail(session.id) } label: {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.title).fontWeight(.medium).lineLimit(1)
                            Text("\(session.identity) · \(session.source)").font(.system(size: 11))
                            if model.measurementMode == .live {
                                Text(session.liveMeasurement.rawValue + (session.liveUnavailableReason.map { " · " + $0 } ?? "")).font(.system(size: 11))
                            }
                            Text(session.rootObserved ? "CLI root · child scope unknown" : "Excluded from subtotal · root unverified").font(.system(size: 11))
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(model.rate(for: session) + (model.rate(for: session) == "—" ? "" : " tok/s")).monospacedDigit()
                            Text(model.status(for: session)).font(.system(size: 11))
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("\(session.title), \(session.identity), \(session.source), \(model.status(for: session)), \(model.measurementMode.label) \(model.rate(for: session))")
                Divider()
            }
        }
    }
    private func detail(_ session: SessionPresentation) -> some View {
        let monitor = session.monitor
        let baseline = monitor.counter.baseline
        let last = monitor.turns.values.filter { $0.outcome == .completed }.max { ($0.endedAt ?? 0) < ($1.endedAt ?? 0) }
        return Group {
            Text(session.title).font(.headline)
            value("State / source", "\(model.status(for: session)) · \(session.source)")
            value(model.measurementMode.label, model.rate(for: session) + " tok/s")
            value("Measurement", (model.measurementMode == .reported ? session.measurement : session.liveMeasurement).rawValue)
            if model.measurementMode == .live, let reason = session.liveUnavailableReason {
                Text("Live: " + reason).font(.system(size: 11)).textSelection(.enabled)
            }
            if session.hookCompletionCandidate { Text("Hook completion candidate · awaiting authoritative session state") }
            if session.sourceReconciliationPending { Text("Partial · source reconciliation pending") }
            if session.observationStopped { Text("Observation stopped · a fresh measurement baseline is required.") }
            value("Model", session.model ?? "Unavailable")
            value("Controller PID", session.process.map { String($0.pid) } ?? "Session only")
            value("Server PID", session.server.map { String($0.pid) } ?? "Unavailable")
            if let process = session.process { value("Controller start identity", process.osStartTime) }
            if let server = session.server { value("Server start identity", server.osStartTime) }
            copyValue("Working directory", session.cwd)
            copyValue("Thread ID", session.id.threadID)
            copyValue("Run ID", session.id.runID)
            copyValue("Current turn ID", monitor.activeTurnID)
            Divider()
            value("Current turn reported output", session.measurement == .reported ? (monitor.activeTurnID.flatMap { monitor.turns[$0] }.map { "\($0.outputTokens) tokens" } ?? "Unavailable") : "Unavailable")
            Text("Last reported cumulative snapshot").font(.headline)
            value("Output · includes reasoning", baseline.map { String($0.outputTokens) } ?? "Unavailable")
            value("Reasoning · included above", baseline?.reasoningOutputTokens.map(String.init) ?? "Unavailable")
            value("Non-reasoning output", baseline?.nonReasoningOutputTokens.map(String.init) ?? "Unavailable")
            value("Last completed turn average", last?.average.map { $0.formatted(.number.precision(.fractionLength(0...1))) + " tok/s" } ?? "Unavailable")
            Text("Turn average includes tools and waiting. It is history, not current generation speed.").font(.system(size: 11))
            value("Last observation", session.lastObserved?.formatted() ?? "Unavailable")
            Text(session.rootObserved ? "Observed CLI root counter only. Partial: child scope remains unknown." : "Root provenance is unverified or ambiguous; excluded from subtotal. Individual measurements remain visible.")
        }
    }
    private var preferences: some View {
        Group {
            modePicker
            Text("Live requires complete managed visible text and a supported model. Warm-up and unavailable measurements remain —.").font(.system(size: 11))
            Divider()
            Toggle("Hide idle sessions", isOn: $model.hideIdle).onChange(of: model.hideIdle) { model.saveDisplayPreferences?() }
            Toggle("Compact menu bar", isOn: $model.compact).onChange(of: model.compact) { model.saveDisplayPreferences?() }
            Toggle("Start at login", isOn: Binding(get: { model.startAtLogin }, set: { model.updateLogin?($0) })).disabled(model.updateLogin == nil)
            Text(model.loginStatus).font(.system(size: 11))
            hooksControls
            Divider()
            Picker("Metadata retention", selection: Binding(get: { model.retentionDays }, set: { model.updateRetention?($0) })) {
                ForEach([1, 7, 30, 90], id: \.self) { Text("\($0) days").tag($0) }
            }.disabled(!model.canManageMetadata || model.updateRetention == nil || model.busy)
            Text("Prompt and response text are never stored. Clearing metadata preserves original Codex logs.").font(.system(size: 11))
            Button("Clear collected metadata", role: .destructive) { model.confirmClear = true }.disabled(!model.canManageMetadata || model.clearMetadata == nil || model.busy)
            Divider()
            Text("Quitting Hub stops monitoring, not your Codex sessions.").font(.system(size: 11))
            Button("Quit Codex Hub") { model.quit?() }.disabled(model.quit == nil)
        }
    }
    private var connection: some View {
        Group {
            Text("Keep your terminal.").font(.system(size: 24, weight: .semibold))
            Text("Logs compatibility mode observes saved metadata without restarting Codex.")
            Text(model.codexHome).font(.system(size: 11)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Button("Choose Codex home…") { model.chooseHome?() }.disabled(model.chooseHome == nil || model.busy || model.hooksBusy)
            Button(model.busy ? "Checking…" : "Check connection") { model.refresh?() }.disabled(model.busy || model.refresh == nil)
            Divider()
            hooksControls
            Divider()
            if !model.diagnostics.isEmpty {
                Text("Collection diagnostics").font(.headline)
                ForEach(Array(model.diagnostics.enumerated()), id: \.offset) { _, text in Text(text).textSelection(.enabled) }
                Divider()
            }
            value("Managed direct", model.helperPath == nil ? "Helper unavailable" : "Experimental · unverified")
            Text("Start a new run yourself in a terminal. Existing sessions are never resumed or replayed. Relay behavior and G0 await user QA.")
            copyValue("Bundled helper", model.helperPath)
            copyValue("Installed Codex", model.codexPath)
            Button("Choose Codex executable…") { model.chooseCodex?() }.disabled(model.chooseCodex == nil || model.doctorBusy)
            Button(model.doctorBusy ? "Checking version…" : "Check helper compatibility") { model.runDoctor?() }
                .disabled(model.runDoctor == nil || model.helperPath == nil || model.codexPath == nil || model.doctorBusy)
            Text(model.doctorResult).font(.system(size: 11))
            copyValue("Experimental terminal command", model.managedCommand)
            Text("Run from your intended project directory. Additional flags, prompts, profiles and resume commands are not supported.").font(.system(size: 11))
            Text("Live estimates require a managed direct run with supported model metadata and complete visible-text observation. Unsupported models and missing evidence remain unavailable.")
            Text("A collection error does not mean your Codex task failed. Check the original terminal for task status.").font(.system(size: 11))
        }
    }
    private var modePicker: some View {
        Picker("Measurement mode", selection: Binding(get: { model.measurementMode }, set: { model.updateMeasurementMode?($0) })) {
            ForEach(MeasurementMode.allCases, id: \.self) { Text($0.label).tag($0) }
        }.disabled(model.updateMeasurementMode == nil)
    }
    private var hooksControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Optional compatibility hooks").font(.headline)
            Text(model.codexHome + "/hooks.json").font(.system(size: 11)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Text(model.hooksResult).font(.system(size: 11)).textSelection(.enabled)
            Button(model.hooksBusy ? "Working…" : "Check hook status") { model.hookAction?(.status) }
            HStack {
                Button("Install hooks…") { model.hookAction?(.install) }
                Button("Remove hooks…") { model.hookAction?(.uninstall) }
            }
            Text("State only, never token usage. Installation requires confirmation; manually review and trust in Codex /hooks. No automatic feature enablement.").font(.system(size: 11))
        }.disabled(model.hooksBusy || model.helperPath == nil || model.hookAction == nil)
    }
    private func value(_ label: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline) { Text(label); Spacer(minLength: 12); Text(text).multilineTextAlignment(.trailing).monospacedDigit() }.accessibilityElement(children: .combine)
    }
    private func copyValue(_ label: String, _ text: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(label); Spacer(); Button("Copy") {
                guard let text else { return }
                NSPasteboard.general.clearContents()
                if NSPasteboard.general.setString(text, forType: .string) { model.notice = "Copied \(label.lowercased())." }
                else { model.notice = "Clipboard write failed." }
            }.disabled(text == nil).accessibilityLabel("Copy \(label)") }
            Text(text ?? "Unavailable").font(.system(size: 11)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}
