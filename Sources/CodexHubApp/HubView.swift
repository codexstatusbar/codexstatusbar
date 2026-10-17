import SwiftUI
import AppKit
import CodexHubCore

struct HubView: View {
    @Bindable var model: HubPresentation
    @Environment(\.colorScheme) private var colorScheme
    var height: CGFloat = 520
    private var dark: Bool { colorScheme == .dark }
    private var panel: Color { dark ? Color(white: 0.19) : Color(nsColor: .windowBackgroundColor) }
    private var inset: Color { dark ? Color(white: 0.055) : Color(white: 0.94) }
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
        .font(.system(size: 13)).frame(width: 380, height: height)
        .background(panel)
        .alert(model.text("Clear collected metadata?"), isPresented: $model.confirmClear) {
            Button(model.text("Cancel"), role: .cancel) {}
            Button(model.text("Clear metadata"), role: .destructive) { model.clearMetadata?() }
        } message: { Text(model.text("Deletes Hub metadata only. Original Codex logs and sessions are kept.")) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if model.page == .overview {
                Image(systemName: "waveform.path.ecg.rectangle").font(.system(size: 15)).accessibilityHidden(true)
                Text("Codex Hub").font(.system(size: 16, weight: .medium))
            } else {
                Button { model.page = .overview } label: {
                    Image(systemName: "chevron.left").frame(width: 24, height: 28)
                }.buttonStyle(.plain).accessibilityLabel(model.text("뒤로")).keyboardShortcut("[", modifiers: .command)
                Text(title).font(.system(size: 15, weight: .semibold))
            }
            Spacer(minLength: 8)
            Button { model.close?() } label: {
                HStack(spacing: 6) {
                    if model.page == .overview {
                        Image(systemName: model.activeProcessCount > 0 ? "circle.inset.filled" : "pause.circle")
                            .foregroundStyle(model.activeProcessCount > 0 ? active : secondary)
                        Text(model.activitySummary).foregroundStyle(secondary)
                    }
                    Image(systemName: model.page == .overview ? "chevron.down" : "xmark").foregroundStyle(secondary)
                }.font(.system(size: 11)).frame(minHeight: 28).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(model.text("닫기") + ", " + model.activitySummary).help(model.text("닫기")).keyboardShortcut(.cancelAction)
        }.padding(.horizontal, 16).padding(.vertical, 12)
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
                VStack(spacing: 6) {
                    Text(String(model.processCount)).font(.system(size: 20, weight: .semibold)).monospacedDigit()
                    Text(model.text("프로세스")).font(.system(size: 10)).foregroundStyle(secondary)
                }.frame(width: 60, height: 72).background(inset, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityElement(children: .combine)
            }.frame(minHeight: 92)
            if model.sessions.contains(where: { $0.monitor.connectivity == .connected && $0.activity == .approvalWait }) {
                Label(model.text("Approval is waiting in Codex. Respond in the original terminal; Hub never approves commands."), systemImage: "hand.raised")
                    .font(.system(size: 11)).foregroundStyle(attention)
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
        let needsAttention = model.error != nil || session.monitor.connectivity != .connected || session.activity == .unknown || session.activity == .approvalWait
        return HStack(spacing: 10) {
            Image(systemName: needsAttention ? "exclamationmark.circle" : waiting ? "pause.circle" : "circle.inset.filled")
                .foregroundStyle(needsAttention ? attention : waiting ? secondary : active).accessibilityHidden(true)
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
        let monitor = session.monitor
        let baseline = monitor.counter.baseline
        let last = monitor.turns.values.filter { $0.outcome != nil }.max { ($0.endedAt ?? 0) < ($1.endedAt ?? 0) }
        return Group {
            Text(session.title).font(.headline)
            value("작업 상태 / 수집 방식", "\(model.status(for: session)) · \(session.source)")
            value(model.measurementMode.label, model.rate(for: session) + " " + model.rateUnit.suffix)
            if let last, model.measurementMode != .server {
                value(last.isObservedAveragePartial ? "직전 관측 구간 평균 · 도구 포함" : "직전 작업 평균 · 도구 포함", last.workAverage.map { model.displayRate($0) + " " + model.rateUnit.suffix } ?? "미확인")
            }
            if model.measurementMode == .reported {
                value(model.text("계산 기준"), model.text("사용량 증가량 ÷ 도구 시간을 뺀 보고 구간"))
            }
            if model.measurementMode == .server {
                Text(model.text("서버 타이밍은 관리형 실행에서 수집합니다. TBT 집계 범위와 요청별 토큰 대응이 검증되기 전에는 tok/s로 변환하지 않습니다.")).font(.system(size: 11))
                if let timing = session.serverTiming {
                    value("서버 추론 시간", timing.inferenceMilliseconds.map { "\($0) ms" } ?? "—")
                    value("서버 첫 토큰 시간", timing.firstTokenMilliseconds.map { "\($0) ms" } ?? "—")
                    value("서버 TBT 원본", timing.betweenTokenMilliseconds.map { "\($0) ms" } ?? "—")
                    value("서버 출력 토큰", timing.sampledTokens.map(String.init) ?? "—")
                    value("출력 이벤트 수", timing.outputDeltaCount.map(String.init) ?? "—")
                    value("출력 이벤트 평균 간격", timing.outputDeltaMeanMilliseconds.map { "\($0.formatted(.number.precision(.fractionLength(0...2)))) ms" } ?? "—")
                    value("서버 관측 범위", timing.coverage ?? "—")
                    Text(model.text("출력 이벤트 수는 토큰 수와 다릅니다. 이벤트 간격의 역수를 tok/s로 표시하지 않습니다.")).font(.system(size: 11))
                }
            }
            if model.measurementMode == .live, let reason = session.liveUnavailableReason {
                Text(model.text("Live: " + reason)).font(.system(size: 11)).textSelection(.enabled)
            }
            if session.hookCompletionCandidate { Text(model.text("작업 종료 신호를 받았습니다. 최종 상태를 확인하고 있습니다.")) }
            if session.sourceReconciliationPending { Text(model.text("수집 원본의 사용량을 대조하는 중입니다.")) }
            if session.observationStopped { Text(model.text("수집이 중단되어 새로운 사용량 기준이 필요합니다.")) }
            value("모델 / 추론 강도", session.modelDescription.isEmpty ? "미확인" : session.modelDescription)
            value("요청 속도 모드", session.usageDetails?.serviceTier?.displayName ?? "미확인")
            value("기본 속도 설정", model.configuredServiceTier?.displayName ?? "미확인")
            Text(model.text("기본 설정과 프로세스별 설정은 다를 수 있습니다. 실제 처리 모드는 요청과 다를 수 있습니다.")).font(.system(size: 11))
            value("컨텍스트 사용", session.contextDescription)
            value("누적 입력·출력 토큰", session.tokenDescription)
            value("캐시 입력 토큰", baseline.map { SessionPresentation.tokens($0.cachedInputTokens) } ?? "미확인")
            ForEach(session.limitDescriptions(language: model.language), id: \.self) { value("남은 사용 한도", $0) }
            Text(model.text("누적 토큰에는 이전 이력이 포함될 수 있습니다. 컨텍스트와 사용 한도는 마지막 보고값입니다.")).font(.system(size: 11))
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
            Text(model.text("Last reported cumulative snapshot")).font(.headline)
            value("Output · includes reasoning", baseline.map { String($0.outputTokens) } ?? "Unavailable")
            value("Reasoning · included above", baseline?.reasoningOutputTokens.map(String.init) ?? "Unavailable")
            value("Non-reasoning output", baseline?.nonReasoningOutputTokens.map(String.init) ?? "Unavailable")
            value("Last observation", session.lastObserved?.formatted() ?? "Unavailable")
            Text(model.text(session.rootObserved ? "측정과 중복 여부가 확인된 세션만 합계에 포함합니다." : "중복 여부가 확인되지 않아 합계에서 제외된 세션입니다."))
            value("속도 계산 범위", model.coverage)
        }
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
                NSPasteboard.general.clearContents()
                if NSPasteboard.general.setString(text, forType: .string) { model.notice = model.text("Copied") + ": " + model.text(label) }
                else { model.notice = "Clipboard write failed." }
            }.disabled(text == nil).accessibilityLabel(model.text("Copy") + " " + model.text(label)) }
            Text(text ?? model.text("Unavailable")).font(.system(size: 11)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}
