import SwiftUI
import Charts
import CodexHubCore

struct SessionGraphics: View {
    let model: HubPresentation
    let session: SessionPresentation
    let wide: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var points: [UsageHistoryPoint] { model.usageHistory[session.id] ?? [] }
    private var context: Double? {
        guard let used = session.usageDetails?.contextTokens,
              let window = session.usageDetails?.contextWindow, window > 0 else { return nil }
        return min(1, max(0, Double(used) / Double(window)))
    }
    private var statusColor: Color {
        ProcessTint.status(session, failed: model.error != nil, dark: colorScheme == .dark)
    }

    private var baseline: TokenUsage? { session.monitor.counter.baseline }
    private var lastTurn: TurnRecord? {
        session.monitor.turns.values.filter { $0.outcome != nil }.max { ($0.endedAt ?? 0) < ($1.endedAt ?? 0) }
    }
    private var sourceStatus: String { model.status(for: session) + " · " + model.text(session.source) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            hero
            if let main = model.mainSession(for: session) {
                Button { model.page = .detail(main.id) } label: {
                    Label(model.text("Back to main session"), systemImage: "arrow.turn.up.left")
                }.buttonStyle(.bordered)
            }
            section("요약", icon: "list.bullet.rectangle") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: wide ? 4 : 2), spacing: 10) {
                    metric("작업 상태 / 수집 방식", sourceStatus, icon: "doc.text")
                    metric(model.measurementMode.label, model.rate(for: session) + " " + model.rateUnit.suffix, icon: "bolt.fill")
                    metric(lastTurn?.isObservedAveragePartial == true ? "직전 관측 구간 평균 · 도구 포함" : "직전 작업 평균 · 도구 포함", lastTurn?.workAverage.map { model.displayRate($0) + " " + model.rateUnit.suffix } ?? model.text("미확인"), icon: "chart.bar")
                    metric("모델 / 추론 강도", session.model ?? model.text("미확인"), icon: "cube", subtitle: session.usageDetails?.reasoningEffort)
                }
                measurementNotes
            }
            section("토큰 사용량", icon: "cylinder.split.1x2") {
                if wide {
                    HStack(spacing: 20) { contextBlock; Divider().frame(height: 56); tokenCounters }
                } else {
                    VStack(alignment: .leading, spacing: 14) { contextBlock; tokenCounters }
                }
                note("누적 토큰에는 이전 이력이 포함될 수 있습니다. 컨텍스트와 사용 한도는 마지막 보고값입니다.")
            }
            section("관측 출력 추이", icon: "chart.bar.xaxis") { usageChart }
            if !model.auxiliarySessions(for: session).isEmpty { auxiliarySessions }
            HStack(alignment: .top, spacing: 12) {
                Label(model.text("남은 사용 한도"), systemImage: "clock")
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 5) {
                    if session.limitDescriptions(language: model.language).isEmpty { Text(model.text("미확인")) }
                    ForEach(session.limitDescriptions(language: model.language), id: \.self) { Text($0) }
                }.multilineTextAlignment(.trailing)
            }.font(.system(size: 12)).padding(12).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            section("프로세스 / 연결 정보", icon: "terminal") {
                columns {
                    information("Controller PID", session.process.map { String($0.pid) })
                    information("Server PID", session.server.map { String($0.pid) })
                    information("Controller start identity", session.process?.osStartTime)
                    if let server = session.server { information("Server start identity", server.osStartTime) }
                    information("Working directory", session.cwd, copyable: true)
                } right: {
                    information("작업 상태 / 수집 방식", sourceStatus)
                    information("실행 방식", session.observedSource == .directRelay ? model.text("Managed direct") : session.rootObserved ? "CLI" : nil)
                    information("요청 속도 모드", session.usageDetails?.serviceTier?.displayName)
                    information("기본 속도 설정", model.configuredServiceTier?.displayName)
                }
                note("기본 설정과 프로세스별 설정은 다를 수 있습니다. 실제 처리 모드는 요청과 다를 수 있습니다.")
            }
            section("고급 측정 정보", icon: "waveform.path.ecg") {
                columns {
                    information("Thread ID", session.id.threadID, copyable: true)
                    information("Run ID", session.id.runID, copyable: true)
                    information("Current turn ID", session.monitor.activeTurnID, copyable: true)
                } right: {
                    information("속도 계산 범위", model.coverage)
                    information("Last observation", session.lastObserved?.formatted(date: .numeric, time: .standard))
                    if model.measurementMode == .reported { information("계산 기준", model.text("사용량 증가량 ÷ 도구 시간을 뺀 보고 구간")) }
                    Text(model.text(session.rootObserved ? "측정과 중복 여부가 확인된 세션만 합계에 포함합니다." : "중복 여부가 확인되지 않아 합계에서 제외된 세션입니다.")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            section("최근 보고된 누적 사용량", icon: "doc.plaintext") {
                columns {
                    information("Output · includes reasoning", baseline.map { $0.outputTokens.formatted() })
                    information("Reasoning · included above", baseline?.reasoningOutputTokens.map { $0.formatted() })
                } right: {
                    information("Non-reasoning output", baseline?.nonReasoningOutputTokens.map { $0.formatted() })
                    information("Current turn reported output", session.measurement == .reported ? session.monitor.activeTurnID.flatMap { session.monitor.turns[$0] }?.outputTokens.formatted() : nil)
                }
            }
        }
    }

    private var hero: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill").font(.system(size: 22)).foregroundStyle(.blue)
                .frame(width: 46, height: 46).background(.quaternary, in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 5) {
                Text(session.title).font(.system(size: 18, weight: .semibold)).lineLimit(1)
                Text(session.cwd ?? model.text("미확인")).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Label(sourceStatus, systemImage: "circle.fill").font(.system(size: 11)).foregroundStyle(statusColor)
                .padding(.horizontal, 10).padding(.vertical, 7).background(.quaternary, in: Capsule())
        }
    }

    private var contextBlock: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 7)
                if let context {
                    Circle().trim(from: 0, to: context)
                        .stroke(AngularGradient(colors: [.blue, .indigo], center: .center), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                Text(context == nil ? "—" : session.contextDescription).font(.system(size: 13, weight: .semibold)).minimumScaleFactor(0.7).lineLimit(1)
            }.frame(width: 64, height: 64).accessibilityElement(children: .ignore)
                .accessibilityLabel(model.text("컨텍스트 사용")).accessibilityValue(model.text(session.contextDescription))
            Text(model.text("컨텍스트 사용")).font(.system(size: 12)).foregroundStyle(.secondary)
        }.padding(.vertical, 4)
    }

    private var tokenCounters: some View {
        HStack(alignment: .top, spacing: 16) {
            counter("누적 입력 토큰", baseline?.inputTokens)
            Divider().frame(height: 42)
            counter("누적 출력 토큰", baseline?.outputTokens)
            Divider().frame(height: 42)
            counter("캐시 입력 토큰", baseline?.cachedInputTokens)
        }.frame(maxWidth: .infinity)
    }

    private var measurementNotes: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.measurementMode == .live, let reason = session.liveUnavailableReason {
                note("Live: " + reason)
            }
            if session.hookCompletionCandidate { note("작업 종료 신호를 받았습니다. 최종 상태를 확인하고 있습니다.") }
            if session.sourceReconciliationPending { note("수집 원본의 사용량을 대조하는 중입니다.") }
            if session.observationStopped { note("수집이 중단되어 새로운 사용량 기준이 필요합니다.") }
        }
    }

    private var auxiliarySessions: some View {
        section("Auxiliary sessions", icon: "point.3.connected.trianglepath.dotted", showsDivider: false) {
            note("Each session keeps its own speed and chart. Inherited counters are not added together.")
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .top), GridItem(.flexible(), alignment: .top)], alignment: .leading, spacing: 16) {
                ForEach(model.auxiliarySessions(for: session)) { child in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.text("Auxiliary") + " · " + String(child.id.threadID.suffix(8)))
                            .font(.system(size: 12, weight: .semibold)).lineLimit(1).help(child.id.threadID)
                        Text(child.modelDescription).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                            .help(child.modelDescription)
                        HStack {
                            Text(model.status(for: child)).font(.system(size: 10)).lineLimit(1)
                                .foregroundStyle(ProcessTint.status(child, failed: model.error != nil, dark: colorScheme == .dark))
                            Spacer(minLength: 4)
                            Text(model.rate(for: child) + " " + model.rateUnit.suffix)
                                .font(.system(size: 11, weight: .medium)).monospacedDigit().lineLimit(1)
                        }
                        Button { model.page = .detail(child.id) } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(model.text("보고 출력 · 30분")).font(.system(size: 10)).foregroundStyle(.secondary)
                                ObservedTokenChart(points: model.usageHistory[child.id] ?? [], now: model.frame?.time ?? 0,
                                                   emptyText: model.text("새 로그 대기"), compact: true, wallClockOffset: model.chartWallClockOffset)
                                    .allowsHitTesting(false)
                            }.frame(maxWidth: .infinity, minHeight: 56).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(model.text("상세정보") + " " + String(child.id.threadID.suffix(8)))
                            .help(model.text("상세정보"))
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var usageChart: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.text("관측 출력 토큰")).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(model.text("최근 30분 · 1분 단위")).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            ObservedTokenChart(points: points, now: model.frame?.time ?? 0, emptyText: model.text("새 사용량 로그를 기다리는 중입니다"), wallClockOffset: model.chartWallClockOffset)
            HStack {
                Text(model.text("30분 전"))
                Spacer()
                Text(model.text("지금"))
            }.font(.system(size: 10)).foregroundStyle(.secondary)
            Text(model.text("저장된 최근 30분 관측값입니다. 누적 사용량을 새 데이터로 추가하지 않습니다."))
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private func section<Content: View>(_ title: String, icon: String, showsDivider: Bool = true, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(model.text(title), systemImage: icon).font(.system(size: 13, weight: .semibold))
            content()
            if showsDivider { Divider().padding(.top, 4) }
        }.padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func columns<Left: View, Right: View>(@ViewBuilder left: () -> Left, @ViewBuilder right: () -> Right) -> some View {
        if wide {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 0) { left() }.frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                VStack(alignment: .leading, spacing: 0) { right() }.frame(maxWidth: .infinity, alignment: .leading)
            }.fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 0) { left(); right() }
        }
    }

    private func metric(_ title: String, _ value: String, icon: String, subtitle: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(model.text(title), systemImage: icon).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 15, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
            if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, minHeight: 62, alignment: .leading).padding(10)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    private func information(_ title: String, _ value: String?, copyable: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(model.text(title)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            Text(value.map { copyable ? $0 : model.text($0) } ?? model.text("Unavailable"))
                .lineLimit(copyable ? 1 : 2).truncationMode(.middle).multilineTextAlignment(.trailing).textSelection(.enabled)
                .help(value ?? model.text("Unavailable"))
            if copyable {
                Button { if let value { model.copyMetadata(value, label: title) } } label: {
                    Image(systemName: "doc.on.doc").frame(width: 24, height: 24).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(value == nil)
                    .accessibilityLabel(model.text("Copy") + " " + model.text(title))
            }
        }.font(.system(size: 12)).padding(.vertical, 6)
    }

    private func counter(_ title: String, _ count: Int?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(model.text(title)).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(count.map(SessionPresentation.tokens) ?? "—").font(.system(size: 16, weight: .semibold)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func note(_ message: String) -> some View {
        Label(model.text(message), systemImage: "info.circle").font(.system(size: 11)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 7))
    }
}


struct ObservedTokenChart: View {
    let points: [UsageHistoryPoint]
    let now: Double
    let emptyText: String
    var compact = false
    var wallClockOffset: Double = 0

    struct Bin: Identifiable {
        let id: Double
        let tokens: Double
    }
    private var windowEnd: Double {
        (floor((now + wallClockOffset) / UsageHistoryPoint.binSeconds) + 1) * UsageHistoryPoint.binSeconds
    }
    var bins: [Bin] {
        let groups = Dictionary(grouping: points.filter {
            $0.time + wallClockOffset >= windowEnd - UsageHistoryPoint.windowSeconds && $0.time <= now
        }) { floor(($0.time + wallClockOffset) / UsageHistoryPoint.binSeconds) * UsageHistoryPoint.binSeconds }
        return groups.keys.sorted().map { Bin(id: $0, tokens: groups[$0, default: []].reduce(0) { $0 + Double($1.outputTokens) }) }
    }

    var body: some View {
        Group {
            if bins.isEmpty {
                Text(emptyText).font(.system(size: compact ? 10 : 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: compact ? 56 : 110)
            } else {
                Chart(bins) { bin in
                    BarMark(x: .value("Time", bin.id + UsageHistoryPoint.binSeconds / 2 - windowEnd), y: .value("Output tokens", bin.tokens), width: .fixed(compact ? 4 : 9))
                        .foregroundStyle(LinearGradient(colors: [.blue, .indigo], startPoint: .top, endPoint: .bottom))
                        .cornerRadius(2)
                }
                .chartXScale(domain: -UsageHistoryPoint.windowSeconds...0.0)
                .chartXAxis(.hidden)
                .chartYAxis { if !compact { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) } }
                .frame(height: compact ? 56 : 110)
            }
        }
    }
}

// State colors are shared by the process list and detail view.
enum ProcessTint {
    static func status(_ session: SessionPresentation, failed: Bool, dark: Bool) -> Color {
        if failed || session.monitor.connectivity != .connected || session.activity == .unknown {
            return dark ? Color(red: 1, green: 0.65, blue: 0.25) : Color(red: 0.65, green: 0.33, blue: 0.03)
        }
        switch session.activity {
        case .generating: return dark ? Color(red: 0.26, green: 0.87, blue: 0.55) : Color(red: 0.04, green: 0.45, blue: 0.23)
        case .working: return .blue
        case .toolRunning, .approvalWait: return .purple
        default: return .secondary
        }
    }

    static func project(_ title: String) -> Color {
        let index = title.utf8.reduce(0) { ($0 + Int($1)) % 3 }
        return [Color.blue, .indigo, .cyan][index]
    }
}
