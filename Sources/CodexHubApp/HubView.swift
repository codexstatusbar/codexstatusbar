import SwiftUI
import AppKit
import CodexHubCore

struct HubView: View {
    @Bindable var model: HubPresentation
    @Environment(\.colorScheme) private var colorScheme
    var width: CGFloat = 520
    var height: CGFloat = 720
    private var dark: Bool { colorScheme == .dark }
    private var inset: Color { dark ? Color.white.opacity(0.045) : Color.black.opacity(0.035) }
    private var secondary: Color { dark ? Color(white: 0.72) : Color(white: 0.36) }
    private var active: Color { dark ? Color(red: 0.26, green: 0.87, blue: 0.55) : Color(red: 0.04, green: 0.45, blue: 0.23) }
    private var attention: Color { dark ? Color(red: 1, green: 0.65, blue: 0.25) : Color(red: 0.65, green: 0.33, blue: 0.03) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().padding(.horizontal, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let error = model.error { Text(model.text("Collection error") + ": " + error).textSelection(.enabled) }
                    if let notice = model.notice { Text(model.text(notice)).font(.system(size: 11)).foregroundStyle(secondary).textSelection(.enabled) }
                    switch model.page {
                    case .overview: overview
                    case .detail(let key):
                        if let session = model.sessions.first(where: { $0.id == key }) { detail(session) }
                        else { Text(model.text("This session is no longer available.")) }
                    case .preferences: preferences
                    case .connection: connection
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 18)
            }.id(model.page)
            Divider().padding(.horizontal, 14)
            footer
        }
        .font(.system(size: 13)).frame(width: width, height: height)
        .background {
            Rectangle().fill(.regularMaterial)
                .overlay(LinearGradient(colors: [.blue.opacity(dark ? 0.045 : 0.02), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .alert(model.text("Clear collected metadata?"), isPresented: $model.confirmClear) {
            Button(model.text("Cancel"), role: .cancel) {}
            Button(model.text("Clear metadata"), role: .destructive) { model.clearMetadata?() }
        } message: { Text(model.text("Deletes Hub metadata only. Original Codex logs and sessions are kept.")) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if model.page == .overview {
                Image(systemName: "waveform.path.ecg.rectangle").font(.system(size: 15)).accessibilityHidden(true)
                Text("Codex Hub").font(.system(size: 15, weight: .medium))
                Spacer(minLength: 8)
            } else {
                Button { model.page = .overview } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "chevron.left").frame(width: 24)
                        Text(title).font(.system(size: 15, weight: .semibold))
                        Spacer(minLength: 0)
                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(model.text("뒤로") + ", " + title).help(model.text("뒤로")).keyboardShortcut("[", modifiers: .command)
            }
            Button { model.close?() } label: {
                HStack(spacing: 6) {
                    if model.page == .overview {
                        Image(systemName: model.activeProcessCount > 0 ? "circle.inset.filled" : "pause.circle")
                            .foregroundStyle(model.generatingProcessCount > 0 ? active : model.activeProcessCount > 0 ? Color.primary : secondary)
                        Text(model.activitySummary).foregroundStyle(secondary)
                    }
                    Image(systemName: model.page == .overview ? "chevron.down" : "xmark").foregroundStyle(secondary)
                }.font(.system(size: 11)).frame(minWidth: model.page == .overview ? 0 : 44, minHeight: model.page == .overview ? 28 : 44).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(model.text("닫기") + ", " + model.activitySummary).help(model.text("닫기")).keyboardShortcut(.cancelAction)
        }.padding(.horizontal, 16).padding(.vertical, model.page == .overview ? 12 : 4)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.clockwise").accessibilityHidden(true)
            Text(model.freshness).lineLimit(1)
            Spacer(minLength: 8)
            Button { model.page = .connection } label: {
                Label(model.text("연결"), systemImage: "cable.connector").frame(minHeight: 28)
            }.buttonStyle(.plain)
            Button { model.page = .preferences } label: {
                Image(systemName: "slider.horizontal.3").frame(width: 28, height: 28).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(model.text("설정")).help(model.text("설정")).keyboardShortcut(",", modifiers: .command)
        }.font(.system(size: 11)).foregroundStyle(secondary).padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var title: String {
        switch model.page {
        case .overview: "Codex Hub"
        case .detail: model.text("상세정보")
        case .preferences: model.text("설정")
        case .connection: model.text("연결")
        }
    }

    private var measurementCaption: String {
        if model.measurementMode == .live, !model.sessions.isEmpty,
           model.sessions.allSatisfy({ ($0.observedSource ?? $0.monitor.counter.source) != .directRelay }) {
            return model.text("실시간 추정은 관리형 직접 연결이 필요합니다")
        }
        return model.aggregateRate != nil && model.error == nil ? model.text(model.measurementMode.label) : model.text(model.summary)
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.text("전체 속도")).font(.system(size: 12)).foregroundStyle(secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(model.error == nil && model.aggregateRate != nil ? model.summary : "—")
                            .font(.system(size: 28, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                        Text(model.rateUnit.suffix).font(.system(size: 13)).foregroundStyle(secondary)
                    }.accessibilityElement(children: .combine)
                    Label(measurementCaption, systemImage: "info.circle")
                        .font(.system(size: 10)).foregroundStyle(secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(model.text("보고 출력 · 30분")).font(.system(size: 10)).foregroundStyle(secondary)
                    ObservedTokenChart(points: model.overviewUsageHistory, now: model.frame?.time ?? 0, emptyText: model.text("새 로그 대기"), compact: true)
                }.frame(width: width >= 600 ? 240 : width >= 480 ? 160 : 110)
                    .accessibilityLabel(model.text("관측 출력 토큰"))
                if width >= 480 { VStack(spacing: 6) {
                    Text(String(model.processCount)).font(.system(size: 20, weight: .semibold)).monospacedDigit()
                    Text(model.text("프로세스")).font(.system(size: 10)).foregroundStyle(secondary)
                }.frame(width: 60, height: 72).background(inset, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityElement(children: .combine) }
            }.frame(minHeight: 92)
            if model.sessions.contains(where: { $0.monitor.connectivity == .connected && $0.activity == .approvalWait }) {
                Label(model.text("Approval is waiting in Codex. Respond in the original terminal; Hub never approves commands."), systemImage: "hand.raised")
                    .font(.system(size: 11)).foregroundStyle(Color.primary)
            }
            Divider()
            VStack(spacing: 14) {
                HStack {
                    Text("CODEX PROCESSES").font(.system(size: 10, weight: .medium)).tracking(0.5)
                    Spacer(minLength: 8)
                    Text(model.processBreakdown).font(.system(size: 10))
                }.foregroundStyle(secondary)
                VStack(spacing: 4) {
                    ForEach(model.visibleSessions) { session in
                        sessionButton(session)
                    }
                    ForEach(model.unattachedProcesses, id: \.self) { process in
                        HStack(spacing: 10) {
                            Image(systemName: "questionmark.circle").foregroundStyle(attention)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Codex · PID " + String(process.pid)).font(.system(size: 13, weight: .medium))
                                Text(model.text("세션 정보 미확인")).font(.system(size: 10)).foregroundStyle(secondary)
                            }
                            Spacer(minLength: 8)
                            VStack(alignment: .trailing, spacing: 4) {
                                Text(model.text("확인 중")).font(.system(size: 11)).foregroundStyle(secondary)
                                Text("— " + model.rateUnit.suffix).font(.system(size: 12, weight: .medium))
                            }
                        }.padding(.horizontal, 12).frame(minHeight: 64).background(inset, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                if model.processCount == 0 {
                    Text(model.text("실행 중인 Codex가 없습니다")).foregroundStyle(secondary)
                    Button(model.text("연결 확인")) { model.page = .connection; model.refresh?() }.disabled(model.busy || model.refresh == nil)
                } else if model.visibleSessions.isEmpty && model.unattachedProcesses.isEmpty {
                    Text(model.text("대기 중인 항목은 설정에 따라 숨겨져 있습니다.")).font(.system(size: 11)).foregroundStyle(secondary)
                }
            }
        }
    }

    private func sessionButton(_ session: SessionPresentation) -> some View {
        let accessibility = session.title + ", " + model.status(for: session) + ", " + model.rate(for: session) + " " + model.rateUnit.suffix + ", " + model.text("상세정보")
        return Button { model.page = .detail(session.id) } label: { processRow(session) }
            .buttonStyle(.plain)
            .background(inset, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel(accessibility)
            .help(session.identity + " · " + model.text("상세정보"))
    }

    private func processRow(_ session: SessionPresentation) -> some View {
        let waiting = session.activity == .idle && session.monitor.connectivity == .connected
        let needsAttention = model.error != nil || session.monitor.connectivity != .connected || session.activity == .unknown
        return HStack(spacing: 10) {
            Image(systemName: needsAttention ? "exclamationmark.circle" : waiting ? "pause.circle" : "circle.inset.filled")
                .foregroundStyle(needsAttention ? attention : waiting ? secondary : session.activity == .generating ? active : Color.primary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(session.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(session.modelDescription.isEmpty ? model.text("모델 미확인") : session.modelDescription)
                    .font(.system(size: 10)).foregroundStyle(secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text(model.status(for: session)).font(.system(size: 11)).foregroundStyle(secondary).lineLimit(1)
                Text(model.rate(for: session) + " " + model.rateUnit.suffix).font(.system(size: 12, weight: .medium)).monospacedDigit().lineLimit(1)
            }
            Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(secondary).accessibilityHidden(true)
        }.padding(.horizontal, 12).frame(minHeight: 64).contentShape(Rectangle())
    }
    private func detail(_ session: SessionPresentation) -> some View {
        SessionGraphics(model: model, session: session, wide: width >= 600)
    }

    private var preferences: some View {
        Group {
            Picker(model.text("Language"), selection: $model.language) {
                Text(model.text("System default")).tag(AppLanguage.system)
                Text("한국어").tag(AppLanguage.korean)
                Text("English").tag(AppLanguage.english)
            }.onChange(of: model.language) { _, language in model.saveLanguage?(language) }
            Divider()
            modePicker
            Picker(model.text("속도 단위"), selection: Binding(get: { model.rateUnit }, set: { model.updateRateUnit?($0) })) {
                ForEach(RateUnit.allCases, id: \.self) { unit in
                    Text(model.text(unit == .second ? "초당 · tok/s" : "분당 · tok/m")).tag(unit)
                }
            }.disabled(model.updateRateUnit == nil)
            Text(model.text("Live requires complete managed visible text and a supported model. Warm-up and unavailable measurements remain —.")).font(.system(size: 11))
            Divider()
            Toggle(model.text("Hide idle sessions"), isOn: $model.hideIdle).onChange(of: model.hideIdle) { model.saveDisplayPreferences?() }
            Toggle(model.text("Start at login"), isOn: Binding(get: { model.startAtLogin }, set: { model.updateLogin?($0) })).disabled(model.updateLogin == nil)
            Text(model.text(model.loginStatus)).font(.system(size: 11))
            Divider()
            Picker(model.text("Metadata retention"), selection: Binding(get: { model.retentionDays }, set: { model.updateRetention?($0) })) {
                ForEach([1, 7, 30, 90], id: \.self) { Text(model.language.resolved == .korean ? "\($0)일" : "\($0) days").tag($0) }
            }.disabled(!model.canManageMetadata || model.updateRetention == nil || model.busy)
            Text(model.text("Prompt and response text are never stored. Clearing metadata preserves original Codex logs.")).font(.system(size: 11))
            Button(model.text("Clear collected metadata"), role: .destructive) { model.confirmClear = true }.disabled(!model.canManageMetadata || model.clearMetadata == nil || model.busy)
            Divider()
            Text(model.text("Quitting Hub stops monitoring, not your Codex sessions.")).font(.system(size: 11))
            Button(model.text("Quit Codex Hub")) { model.quit?() }.disabled(model.quit == nil)
        }
    }
    private var connection: some View {
        Group {
            Text(model.text("Keep your terminal.")).font(.system(size: 24, weight: .semibold))
            Text(model.text("Logs compatibility mode observes saved metadata without restarting Codex."))
            Text(model.codexHome).font(.system(size: 11)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Text(model.text("로그는 1초 간격으로 자동 수집합니다.")).font(.system(size: 11))
            Button(model.text("Codex 경로 선택…")) { model.chooseHome?() }.disabled(model.chooseHome == nil || model.busy || model.hooksBusy)
            Button(model.text(model.checkingConnection ? "연결 확인 중…" : "지금 확인")) { model.refresh?() }.disabled(model.busy || model.refresh == nil)
            Divider()
            hooksControls
            Divider()
            if !model.diagnostics.isEmpty {
                Text(model.text("Collection diagnostics")).font(.headline)
                ForEach(Array(model.diagnostics.enumerated()), id: \.offset) { _, text in Text(model.text(text)).textSelection(.enabled) }
                Divider()
            }
            value("Managed direct", model.helperPath == nil ? "Helper unavailable" : "Experimental · unverified")
            Text(model.text("Start a new run yourself in a terminal. Existing sessions are never resumed or replayed. Relay behavior and G0 await user QA."))
            copyValue("Bundled helper", model.helperPath)
            copyValue("Installed Codex", model.codexPath)
            Button(model.text("Choose Codex executable…")) { model.chooseCodex?() }.disabled(model.chooseCodex == nil || model.doctorBusy)
            Button(model.text(model.doctorBusy ? "Checking version…" : "Check helper compatibility")) { model.runDoctor?() }
                .disabled(model.runDoctor == nil || model.helperPath == nil || model.codexPath == nil || model.doctorBusy)
            Text(model.text(model.doctorResult)).font(.system(size: 11))
            copyValue("서버 타이밍 수집 실행 명령", model.managedCommand)
            Text(model.text("새 관리형 Codex 실행에만 적용됩니다. 전역 설정은 바꾸지 않으며 기존 프로세스에는 소급 적용되지 않습니다.")).font(.system(size: 11))
            Text(model.text("Run from your intended project directory. Additional flags, prompts, profiles and resume commands are not supported.")).font(.system(size: 11))
            Text(model.text("Live estimates require a managed direct run with supported model metadata and complete visible-text observation. Unsupported models and missing evidence remain unavailable."))
            Text(model.text("A collection error does not mean your Codex task failed. Check the original terminal for task status.")).font(.system(size: 11))
        }
    }
    private var modePicker: some View {
        Picker(model.text("속도 계산 방식"), selection: Binding(get: { model.measurementMode }, set: { model.updateMeasurementMode?($0) })) {
            ForEach(MeasurementMode.allCases, id: \.self) { Text(model.text($0.label)).tag($0) }
        }.disabled(model.updateMeasurementMode == nil)
    }
    private var hooksControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.text("Optional compatibility hooks")).font(.headline)
            Text(model.codexHome + "/hooks.json").font(.system(size: 11)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Text(model.text(model.hooksResult)).font(.system(size: 11)).textSelection(.enabled)
            Button(model.text(model.hooksBusy ? "Working…" : "Check hook status")) { model.hookAction?(.status) }
            HStack {
                Button(model.text("Install hooks…")) { model.hookAction?(.install) }
                Button(model.text("Remove hooks…")) { model.hookAction?(.uninstall) }
            }
            Text(model.text("State only, never token usage. Installation requires confirmation; manually review and trust in Codex /hooks. No automatic feature enablement.")).font(.system(size: 11))
        }.disabled(model.hooksBusy || model.helperPath == nil || model.hookAction == nil)
    }
    private func value(_ label: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline) { Text(model.text(label)); Spacer(minLength: 12); Text(model.text(text)).multilineTextAlignment(.trailing).monospacedDigit() }.accessibilityElement(children: .combine)
    }
    private func copyValue(_ label: String, _ text: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(model.text(label)); Spacer(); Button(model.text("Copy")) {
                guard let text else { return }
                model.copyMetadata(text, label: label)
            }.disabled(text == nil).accessibilityLabel(model.text("Copy") + " " + model.text(label)) }
            Text(text ?? model.text("Unavailable")).font(.system(size: 11)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}


@MainActor extension HubPresentation {
    func copyMetadata(_ text: String, label: String) {
        NSPasteboard.general.clearContents()
        notice = NSPasteboard.general.setString(text, forType: .string)
            ? self.text("Copied") + ": " + self.text(label) : self.text("Clipboard write failed.")
    }
}
