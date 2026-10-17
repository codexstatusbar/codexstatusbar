import SwiftUI
import Charts
import CodexHubCore

struct SessionGraphics: View {
    let model: HubPresentation
    let session: SessionPresentation
    @Environment(\.colorScheme) private var colorScheme

    private struct Bin: Identifiable {
        let id: Int
        let tokens: Double
        var offset: Double { Double(id) * 10 - 295 }
    }
    private var points: [UsageHistoryPoint] { model.usageHistory[session.id] ?? [] }
    private var bins: [Bin] {
        let now = model.frame?.time ?? 0
        let groups = Dictionary(grouping: points) { min(29, max(0, Int(($0.time - now + 300) / 10))) }
        return groups.keys.sorted().map { Bin(id: $0, tokens: groups[$0, default: []].reduce(0) { $0 + Double($1.outputTokens) }) }
    }
    private var observedOutput: String {
        guard !points.isEmpty else { return "—" }
        var total = 0
        for point in points {
            let sum = total.addingReportingOverflow(point.outputTokens)
            guard !sum.overflow else { return "—" }
            total = sum.partialValue
        }
        return SessionPresentation.tokens(total)
    }
    private var context: Double? {
        guard let used = session.usageDetails?.contextTokens,
              let window = session.usageDetails?.contextWindow, window > 0 else { return nil }
        return min(1, max(0, Double(used) / Double(window)))
    }
    private var statusColor: Color {
        if model.error != nil || session.monitor.connectivity != .connected || session.activity == .unknown {
            return colorScheme == .dark ? Color(red: 1, green: 0.65, blue: 0.25) : Color(red: 0.65, green: 0.33, blue: 0.03)
        }
        if session.activity == .generating {
            return colorScheme == .dark ? Color(red: 0.26, green: 0.87, blue: 0.55) : Color(red: 0.04, green: 0.45, blue: 0.23)
        }
        return session.activity == .idle ? .secondary : .primary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill").font(.system(size: 17)).foregroundStyle(.secondary)
                    .frame(width: 34, height: 34).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text(session.cwd ?? model.text("미확인")).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 6)
                Text(model.status(for: session)).font(.system(size: 11, weight: .medium)).foregroundStyle(statusColor)
                    .padding(.horizontal, 8).padding(.vertical, 5).background(.quaternary, in: Capsule())
            }
            HStack(spacing: 10) {
                metric("현재 속도", model.rate(for: session) + " " + model.rateUnit.suffix, icon: "bolt.fill")
                Divider().frame(height: 36)
                metric("관측 출력 · 5분", observedOutput, icon: "chart.bar.xaxis")
                Divider().frame(height: 36)
                metric("마지막 보고", session.lastObserved?.formatted(date: .omitted, time: .standard) ?? "—", icon: "clock")
            }.padding(10).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            usageChart
            Divider()
            Text(model.text("프로세스 정보")).font(.system(size: 12, weight: .semibold))
            VStack(spacing: 0) {
                information("PID", session.process.map { String($0.pid) } ?? "—", icon: "cpu")
                Divider()
                information("모델 / 추론 강도", session.modelDescription.isEmpty ? "미확인" : session.modelDescription, icon: "sparkles")
                Divider()
                information("수집 방식", model.text(session.source), icon: "point.3.connected.trianglepath.dotted")
                Divider()
                information("요청 속도 모드", session.usageDetails?.serviceTier?.displayName ?? "미확인", icon: "speedometer")
                Divider()
                information("기본 속도 설정", model.configuredServiceTier?.displayName ?? "미확인", icon: "slider.horizontal.3")
            }.padding(.horizontal, 10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            Text(model.text("사용량 요약")).font(.system(size: 12, weight: .semibold))
            HStack(spacing: 12) {
                ZStack {
                    Circle().stroke(.quaternary, lineWidth: 5)
                    if let context {
                        Circle().trim(from: 0, to: context)
                            .stroke(AngularGradient(colors: [.blue, .indigo], center: .center), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    Text(context == nil ? "—" : session.contextDescription).font(.system(size: 11, weight: .semibold)).minimumScaleFactor(0.7).lineLimit(1)
                }.frame(width: 52, height: 52)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(model.text("컨텍스트 사용"))
                    .accessibilityValue(model.text(session.contextDescription))
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.text("컨텍스트 사용")).font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(model.text(session.contextDescription)).font(.system(size: 15, weight: .semibold)).monospacedDigit()
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 5) {
                    tokenLine("입력", session.monitor.counter.baseline?.inputTokens)
                    tokenLine("출력", session.monitor.counter.baseline?.outputTokens)
                    tokenLine("캐시", session.monitor.counter.baseline?.cachedInputTokens)
                }
            }.padding(.vertical, 6)
            ForEach(session.limitDescriptions(language: model.language), id: \.self) { Text($0).font(.system(size: 12)).foregroundStyle(.secondary) }
        }
    }

    private var usageChart: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.text("관측 출력 토큰")).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(model.text("최근 5분 · 10초 단위")).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if bins.isEmpty {
                Text(model.text("새 사용량 로그를 기다리는 중입니다"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 110)
                    .overlay(alignment: .bottom) { Divider() }
            } else {
                Chart(bins) { bin in
                    BarMark(x: .value("Time", bin.offset), y: .value("Output tokens", bin.tokens), width: .fixed(6))
                        .foregroundStyle(LinearGradient(colors: [.blue, .indigo], startPoint: .top, endPoint: .bottom))
                        .cornerRadius(2)
                }
                .chartXScale(domain: -300.0...0.0)
                .chartXAxis(.hidden)
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
                .frame(height: 110)
                .accessibilityLabel(model.text("관측 출력 토큰"))
                HStack {
                    Text(model.text("5분 전"))
                    Spacer()
                    Text(model.text("지금"))
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Text(model.text("앱 실행 이후 관측값입니다. 과거 누적 사용량은 차트에 넣지 않습니다."))
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private func metric(_ title: String, _ value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(model.text(title), systemImage: icon).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 13, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func information(_ title: String, _ value: String, icon: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 16)
            Text(model.text(title)).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(model.text(value)).multilineTextAlignment(.trailing).textSelection(.enabled)
        }.font(.system(size: 12)).padding(.vertical, 8)
    }

    private func tokenLine(_ title: String, _ count: Int?) -> some View {
        HStack(spacing: 6) {
            Text(model.text(title)).foregroundStyle(.secondary)
            Text(count.map(SessionPresentation.tokens) ?? "—").monospacedDigit()
        }.font(.system(size: 11))
    }
}
