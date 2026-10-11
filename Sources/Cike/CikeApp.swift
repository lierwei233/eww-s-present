import AppKit
import AVKit
import Combine
import CoreGraphics
import SwiftUI
import WebKit

@main
struct CikeApp: App {
    @StateObject private var contextMonitor = ContextMonitor()
    @StateObject private var mealRecommendations = MeituanTopOneStore()
    @StateObject private var sspaiTopOne = SspaiTopOneStore()
    @StateObject private var aiCoverGeneration = AICoverGeneration()

    var body: some Scene {
        MenuBarExtra {
            RecommendationPopover(
                contextMonitor: contextMonitor,
                mealRecommendations: mealRecommendations,
                sspaiTopOne: sspaiTopOne,
                aiCoverGeneration: aiCoverGeneration
            )
                .frame(width: 370)
        } label: {
            if let image = MenuBarLogo.image {
                Image(nsImage: image)
                    .renderingMode(.original)
                    .frame(width: 18, height: 18)
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            AICoverSettingsView(generation: aiCoverGeneration)
        }
    }
}

enum MealPeriod: String, Sendable, Hashable {
    case lunch, afternoonTea, dinner, night
}

private enum CikePalette {
    static let glassTint = Color(red: 0.980, green: 0.976, blue: 0.965).opacity(0.52)
    static let logoSurface = Color(red: 0.941, green: 0.933, blue: 0.918).opacity(0.72)
    static let cardSurface = Color(red: 1.0, green: 0.992, blue: 0.973).opacity(0.48)
    static let smallCardSurface = Color(red: 1.0, green: 0.992, blue: 0.973).opacity(0.33)
    static let secondaryActionSurface = Color(red: 0.984, green: 0.976, blue: 0.957).opacity(0.60)
    static let primaryText = Color.primary.opacity(0.78)
    static let primaryAction = Color(red: 0.227, green: 0.227, blue: 0.235).opacity(0.84)
}

private enum MenuBarLogo {
    @MainActor
    static var image: NSImage? {
        let renderer = ImageRenderer(
            content: OpenFocusLogo(lineWidth: 1.45, color: .white)
                .frame(width: 18, height: 18)
        )
        renderer.scale = 2
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = false
        return image
    }
}

struct OpenFocusMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let inset = rect.width * 0.12
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.midY),
            radius: min(rect.width, rect.height) / 2 - inset,
            startAngle: .degrees(-28),
            endAngle: .degrees(-62),
            clockwise: false
        )
        return path
    }
}

private struct OpenFocusLogo: View {
    var lineWidth: CGFloat
    var color: Color = .primary.opacity(0.8)

    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            let radius = size / 2 - size * 0.12
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let angle = -CGFloat.pi / 4
            ZStack {
                OpenFocusMark()
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                Circle()
                    .fill(color)
                    .frame(width: lineWidth * 2.2, height: lineWidth * 2.2)
                    .position(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            }
        }
    }
}

private enum AdviceScene {
    case lunch, afternoonTea, dinner, night, content, breath, breakReminder, travel

    static func meal(at date: Date, calendar: Calendar = .current) -> AdviceScene? {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        guard let hour = parts.hour, let minute = parts.minute else { return nil }
        let time = hour * 60 + minute
        if (11 * 60 + 30)..<(13 * 60 + 30) ~= time { return .lunch }
        if (15 * 60)..<(16 * 60) ~= time { return .afternoonTea }
        if (16 * 60 + 30)..<(19 * 60 + 30) ~= time { return .dinner }
        if time >= 22 * 60 || time < 60 { return .night }
        return nil
    }

    static func holidayName(at date: Date, calendar: Calendar = .current) -> String? {
        let parts = calendar.dateComponents([.month, .day], from: date)
        guard let month = parts.month, let day = parts.day else { return nil }
        if month == 10 && (1...7).contains(day) { return "国庆" }
        if month == 5 && (1...5).contains(day) { return "五一" }
        if month == 4 && (4...6).contains(day) { return "清明" }
        if month == 1 && (1...3).contains(day) { return "元旦" }

        let lunar = Calendar(identifier: .chinese).dateComponents([.month, .day], from: date)
        if lunar.month == 1 && (1...7).contains(lunar.day ?? 0) { return "春节" }
        if lunar.month == 5 && lunar.day == 5 { return "端午" }
        if lunar.month == 8 && lunar.day == 15 { return "中秋" }
        return nil
    }

    static func travelTitle(at date: Date) -> String {
        "\(holidayName(at: date) ?? "假日")出游灵感"
    }

    var eventID: String {
        switch self {
        case .lunch: "lunch"
        case .afternoonTea: "afternoon_tea"
        case .dinner: "dinner"
        case .night: "night_snack"
        case .content: "content"
        case .breath: "breath"
        case .breakReminder: "break_reminder"
        case .travel: "travel"
        }
    }
}

@MainActor
private final class ContextMonitor: ObservableObject {
    @Published private(set) var scene: AdviceScene = .content
    @Published private(set) var presentedScene: AdviceScene?
    @Published private(set) var continuousUseMinutes = 0

    private let travelPreviewKey = "Cike.previewTravelRecommendation"
    private let breathPresentationPrefix = "Cike.breathPresentation"
    private let useSessionStartKey = "Cike.continuousUseStartedAt"
    private let breakReminderCountPrefix = "Cike.breakReminderCount"
    private let restBreakThreshold: TimeInterval = 5 * 60
    private var timer: Timer?
    private var appActivationObserver: NSObjectProtocol?
    private var continuousUseStartedAt: Date?
    private var lastExternalBundleID: String?
    private var presentationStartedAt: Date?

    init() {
        continuousUseStartedAt = UserDefaults.standard.object(forKey: useSessionStartKey) as? Date
        refresh()
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier {
                    self.refresh()
                }
            }
        }
        scheduleTimer()
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    private func refresh(now: Date = .now) {
        refreshContinuousUse(now: now)
        let frontmostID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if let frontmostID, frontmostID != Bundle.main.bundleIdentifier {
            lastExternalBundleID = frontmostID
        }

        if UserDefaults.standard.bool(forKey: travelPreviewKey) {
            setScene(.travel)
            return
        }

        if let meal = AdviceScene.meal(at: now), canPresent(meal, at: now) {
            setScene(meal)
            return
        }
        if canOfferBreakReminder {
            setScene(.breakReminder)
            return
        }
        if canOfferBreath(at: now) {
            setScene(.breath)
            return
        }
        setScene(.content)
    }

    private func setScene(_ newScene: AdviceScene) {
        // Avoid publishing every second when the scene has not changed.
        switch (scene, newScene) {
        case (.lunch, .lunch), (.afternoonTea, .afternoonTea), (.dinner, .dinner), (.night, .night),
             (.content, .content), (.breath, .breath), (.breakReminder, .breakReminder):
            break
        default:
            scene = newScene
        }
    }

    func recordPresentation(of scene: AdviceScene, now: Date = .now) {
        if let meal = MealPeriod(scene) {
            let key = mealCountKey(for: meal, at: now)
            let count = UserDefaults.standard.integer(forKey: key)
            guard count < 2 else { return }
            UserDefaults.standard.set(count + 1, forKey: key)
        } else if scene == .breath {
            UserDefaults.standard.set(true, forKey: breathPresentationKey(at: now))
        } else if scene == .breakReminder, let sessionKey = continuousUseSessionKey {
            let key = "\(breakReminderCountPrefix).\(sessionKey)"
            UserDefaults.standard.set(UserDefaults.standard.integer(forKey: key) + 1, forKey: key)
        }
    }

    @discardableResult
    func beginPresentation() -> AdviceScene {
        refresh()
        let selectedScene = scene
        presentedScene = selectedScene
        presentationStartedAt = .now
        recordEvent(
            what: "assistant_opened",
            appBundleID: lastExternalBundleID,
            intent: selectedScene.eventID
        )
        recordPresentation(of: selectedScene)
        if selectedScene == .travel {
            UserDefaults.standard.removeObject(forKey: travelPreviewKey)
        }
        return selectedScene
    }

    func showTravelWhenHolidayContentIsExhausted() {
        guard AdviceScene.holidayName(at: .now) != nil else { return }
        scene = .travel
        presentedScene = .travel
    }

    func endPresentation() {
        if let presentationStartedAt {
            recordEvent(
                what: "assistant_closed",
                appBundleID: lastExternalBundleID,
                intent: presentedScene?.eventID,
                durationSeconds: max(0, Int(Date.now.timeIntervalSince(presentationStartedAt)))
            )
        }
        presentationStartedAt = nil
        presentedScene = nil
    }

    func recordExternalAction(_ action: String, destination: URL) {
        recordEvent(
            what: action,
            appBundleID: lastExternalBundleID,
            intent: presentedScene?.eventID,
            targetID: ContextEventStore.opaqueID(for: destination.absoluteString)
        )
    }

    private func recordEvent(
        what: String,
        at date: Date = .now,
        appBundleID: String?,
        surface: String? = nil,
        intent: String? = nil,
        targetID: String? = nil,
        durationSeconds: Int? = nil
    ) {
        let event = ContextEvent(
            when: date,
            appBundleID: appBundleID,
            surface: surface,
            what: what,
            inference: intent.map { ContextEvent.Inference(intent: $0, source: "current_rules") },
            targetID: targetID,
            durationSeconds: durationSeconds
        )
        Task { await ContextEventStore.shared.record(event) }
    }

    private func canPresent(_ scene: AdviceScene, at date: Date) -> Bool {
        guard let meal = MealPeriod(scene) else { return false }
        return UserDefaults.standard.integer(forKey: mealCountKey(for: meal, at: date)) < 2
    }

    private func canOfferBreath(at date: Date) -> Bool {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        guard let hour = parts.hour, let minute = parts.minute,
              [10, 14, 20].contains(hour), minute < 30 else { return false }
        return !UserDefaults.standard.bool(forKey: breathPresentationKey(at: date))
    }

    private func refreshContinuousUse(now: Date) {
        let idleSeconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .null)
        guard idleSeconds < restBreakThreshold else {
            continuousUseStartedAt = nil
            continuousUseMinutes = 0
            UserDefaults.standard.removeObject(forKey: useSessionStartKey)
            return
        }
        if continuousUseStartedAt == nil {
            continuousUseStartedAt = now.addingTimeInterval(-min(idleSeconds, 30))
            UserDefaults.standard.set(continuousUseStartedAt, forKey: useSessionStartKey)
        }
        let minutes = max(0, Int(now.timeIntervalSince(continuousUseStartedAt ?? now) / 60))
        continuousUseMinutes = minutes
    }

    private var continuousUseSessionKey: String? {
        guard let continuousUseStartedAt else { return nil }
        return String(Int(continuousUseStartedAt.timeIntervalSince1970))
    }

    private var canOfferBreakReminder: Bool {
        guard let sessionKey = continuousUseSessionKey else { return false }
        let count = UserDefaults.standard.integer(forKey: "\(breakReminderCountPrefix).\(sessionKey)")
        if count == 0 { return continuousUseMinutes >= 45 }
        if count == 1 { return continuousUseMinutes >= 60 }
        return false
    }

    private func breathPresentationKey(at date: Date) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        return "\(breathPresentationPrefix).\(Self.dayFormatter.string(from: date)).\(hour)"
    }

    private func mealCountKey(for meal: MealPeriod, at date: Date) -> String {
        let day = Self.dayFormatter.string(from: date)
        return "Cike.mealPresentation.\(day).\(meal.rawValue)"
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = .current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

private extension MealPeriod {
    init?(_ scene: AdviceScene) {
        switch scene {
        case .lunch: self = .lunch
        case .afternoonTea: self = .afternoonTea
        case .dinner: self = .dinner
        case .night: self = .night
        default: return nil
        }
    }
}

private struct RecommendationPopover: View {
    @ObservedObject var contextMonitor: ContextMonitor
    @ObservedObject var mealRecommendations: MeituanTopOneStore
    @ObservedObject var sspaiTopOne: SspaiTopOneStore
    @ObservedObject var aiCoverGeneration: AICoverGeneration
    private var scene: AdviceScene { contextMonitor.presentedScene ?? contextMonitor.scene }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.bottom, 26)
            if aiCoverGeneration.isShowingSetup {
                AICoverSetupAdvice(generation: aiCoverGeneration)
            } else {
                switch scene {
                case .content:
                    if let projects = sspaiTopOne.article?.githubProjects {
                        GitHubTrendingAdvice(projects: projects, contextMonitor: contextMonitor)
                    } else {
                        ContentAdvice(article: sspaiTopOne.article, contentStore: sspaiTopOne, aiCoverGeneration: aiCoverGeneration, contextMonitor: contextMonitor)
                    }
                case .breath: BreathAdvice()
                case .breakReminder: BreakReminderAdvice(minutes: contextMonitor.continuousUseMinutes)
                case .lunch: FoodAdvice(meal: .lunch, mealRecommendations: mealRecommendations, contextMonitor: contextMonitor)
                case .afternoonTea: FoodAdvice(meal: .afternoonTea, mealRecommendations: mealRecommendations, contextMonitor: contextMonitor)
                case .dinner: FoodAdvice(meal: .dinner, mealRecommendations: mealRecommendations, contextMonitor: contextMonitor)
                case .night: FoodAdvice(meal: .night, mealRecommendations: mealRecommendations, contextMonitor: contextMonitor)
                case .travel: TravelAdvice(contextMonitor: contextMonitor)
                }
            }
            footer.padding(.top, 14)
        }
        .padding(18)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(CikePalette.glassTint)
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .background(PopoverWindowCornerRadius(
            radius: 18,
            onPresentation: beginPresentation,
            onDismissal: {
                contextMonitor.endPresentation()
                sspaiTopOne.clearPresentation()
            }
        ))
    }

    private func beginPresentation() {
        if contextMonitor.beginPresentation() == .content {
            Task {
                if await sspaiTopOne.loadNext() == .exhausted {
                    contextMonitor.showTravelWhenHolidayContentIsExhausted()
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 9).fill(CikePalette.logoSurface)
                OpenFocusLogo(lineWidth: 1.45, color: .primary.opacity(0.72)).padding(6)
            }
            .frame(width: 29, height: 29)
            HStack(spacing: 4) {
                Text("此刻").font(.system(size: 14, weight: .semibold)).foregroundStyle(CikePalette.primaryText)
                Text("· \(subtitle)").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Text(Date.now, format: .dateTime.hour().minute())
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.tertiary)
        }
    }

    private var subtitle: String {
        switch scene {
        case .content: sspaiTopOne.article?.githubProjects == nil ? "留一篇好内容慢慢读" : "看看本周热门项目"
        case .breath: "需要换换气么"
        case .breakReminder: "连续用太久了，休息一下"
        case .lunch: "来一份午餐吧"
        case .afternoonTea: "来一份下午茶吧"
        case .dinner: "来一份晚餐吧"
        case .night: "来一份夜宵吧"
        case .travel: AdviceScene.travelTitle(at: .now)
        }
    }

    private var footer: some View {
        HStack {
            HStack(spacing: 6) {
                Circle().fill(Color.primary.opacity(0.22)).frame(width: 4, height: 4)
                Text("只给一个方向 · 你始终可以按自己的节奏决定")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            Button("退出") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BreathAdvice: View {
    private var advice: (title: String, detail: String) {
        switch Calendar.current.component(.hour, from: .now) {
        case 10:
            ("站起来，看看远处 30 秒。", "不用解决什么，只让眼睛离开屏幕一会儿。")
        case 14:
            ("去接一杯水，慢慢喝完。", "先离开座位两分钟，回来再继续。")
        default:
            ("把肩膀放松，深呼吸三次。", "今天还没结束，但这一分钟可以只留给自己。")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(advice.title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(CikePalette.primaryText)
            Text(advice.detail)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Label("大约 30 秒", systemImage: "timer")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(minHeight: 96, alignment: .top)
    }
}

private struct BreakReminderAdvice: View {
    let minutes: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("你已经连续用 Mac \(minutes) 分钟了。")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(CikePalette.primaryText)
            Text("现在起身走几步，再回来继续。")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Label("离开屏幕 3 分钟", systemImage: "figure.walk")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(minHeight: 96, alignment: .top)
    }
}

private struct GitHubTrendingAdvice: View {
    let projects: [GitHubTrendingProject]
    @ObservedObject var contextMonitor: ContextMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("GitHub 本周热门 Top 3")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(CikePalette.primaryText)
                .padding(.bottom, 2)

            ForEach(projects.indices, id: \.self) { index in
                let project = projects[index]
                Button {
                    contextMonitor.recordExternalAction("github_project_opened", destination: project.url)
                    NSWorkspace.shared.open(project.url)
                } label: {
                    HStack(alignment: .top, spacing: 11) {
                        Text("\(index + 1)")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .frame(width: 19, height: 23)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(project.name)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(CikePalette.primaryText)
                                .lineLimit(2)
                            Text(project.summary)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .lineLimit(3)
                            HStack(spacing: 7) {
                                if let language = project.language { Text(language) }
                                if let stars = project.weeklyStars { Text("本周新增 \(stars) Stars") }
                            }
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 2)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.top, 3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(CikePalette.cardSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("打开第 \(index + 1) 名项目 \(project.name)")
            }
        }
        .frame(minHeight: 96, alignment: .top)
    }
}

private struct ContentAdvice: View {
    var article: SspaiArticle?
    @ObservedObject var contentStore: SspaiTopOneStore
    @ObservedObject var aiCoverGeneration: AICoverGeneration
    @ObservedObject var contextMonitor: ContextMonitor
    @StateObject private var videoState = ContentVideoState()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let article {
                if let videoURL = article.videoURL, videoState.hasStarted {
                    InlineContentVideo(videoURL: videoURL, articleURL: article.url,
                                       player: videoState.player, isPlaying: videoState.isPlaying)
                        .id(article.url)
                        .frame(height: 190)
                        .overlay(alignment: videoState.isPlaying ? .bottomTrailing : .center) {
                            Button { videoState.toggle(videoURL) } label: {
                                Image(systemName: videoState.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: videoState.isPlaying ? 12 : 19))
                                    .foregroundStyle(.white)
                                    .frame(width: videoState.isPlaying ? 34 : 48,
                                           height: videoState.isPlaying ? 34 : 48)
                                    .background(.black.opacity(0.65), in: Circle())
                                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                                           alignment: videoState.isPlaying ? .bottomTrailing : .center)
                                    .padding(videoState.isPlaying ? 10 : 0)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(videoState.isPlaying ? "暂停视频" : "继续播放视频")
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    ZStack {
                        if let coverURL = aiCoverGeneration.imageURL(for: article) ?? article.coverURL {
                            AsyncImage(url: coverURL, transaction: Transaction(animation: .easeInOut(duration: 0.18))) { phase in
                                switch phase {
                                case .success(let image):
                                    image.resizable().scaledToFill()
                                case .failure:
                                    coverPlaceholder(for: article, failedToLoadOriginal: true)
                                default:
                                    coverPlaceholder(for: article, failedToLoadOriginal: false)
                                }
                            }
                        } else {
                            coverPlaceholder(for: article, failedToLoadOriginal: false)
                        }
                        if let videoURL = article.videoURL {
                            Button { videoState.toggle(videoURL) } label: {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 19))
                                    .foregroundStyle(.white)
                                    .frame(width: 48, height: 48)
                                    .background(.black.opacity(0.65), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("播放视频")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: article.videoURL == nil ? 118 : 190)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            Text(article?.title ?? emptyTitle)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(CikePalette.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(3)
            Text(article?.metadataText.isEmpty == false ? article!.metadataText : emptyDetail)
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if let article {
                Button {
                    contextMonitor.recordExternalAction("article_opened", destination: article.url)
                    NSWorkspace.shared.open(article.url)
                } label: {
                    Label(article.videoURL == nil ? "阅读原文" : "观看原视频", systemImage: "arrow.up.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(GlassActionStyle(isPrimary: true))
            }
        }
        .frame(minHeight: 96, alignment: .top)
        .onChange(of: article?.url) { _, _ in
            videoState.reset()
        }
        .onDisappear { videoState.pause() }
        .task(id: "\(article?.url.absoluteString ?? "")|\(contentStore.isCheckingCover)|\(aiCoverGeneration.hasAPIKey)") {
            if let article, !contentStore.isCheckingCover {
                aiCoverGeneration.generateIfNeeded(for: article)
            }
        }
    }

    private var emptyTitle: String {
        switch contentStore.lastLoadResult {
        case .exhausted: "暂时没有新的推荐了。"
        case .unavailable: "暂时没能获取新内容。"
        case .loaded, nil: "正在为你找一篇值得读的内容。"
        }
    }

    private var emptyDetail: String {
        switch contentStore.lastLoadResult {
        case .exhausted: "有新内容时，再来看看。"
        case .unavailable: "稍后再点开试试。"
        case .loaded, nil: "内容加载后会附上原文链接。"
        }
    }

    @ViewBuilder
    private func coverPlaceholder(for article: SspaiArticle, failedToLoadOriginal: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(CikePalette.smallCardSurface)
            if contentStore.isCheckingCover {
                Text("正在查找原文配图")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else if aiCoverGeneration.isGenerating(article) {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("正在生成这篇内容的封面")
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            } else if !aiCoverGeneration.hasAPIKey {
                VStack(spacing: 8) {
                    Text(aiCoverGeneration.keychainError ?? "设置 API Key 后可生成封面")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    HStack(spacing: 12) {
                        if aiCoverGeneration.keychainError != nil {
                            Button("重试读取") {
                                if aiCoverGeneration.retryAPIKeyAccess() {
                                    aiCoverGeneration.generateIfNeeded(for: article, force: failedToLoadOriginal)
                                }
                            }
                        }
                        Button("设置密钥") { aiCoverGeneration.isShowingSetup = true }
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
            } else if aiCoverGeneration.hasFailed(article) {
                Text("这篇内容暂时未能生成封面")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else if failedToLoadOriginal {
                Text("正在准备替代封面")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .task { aiCoverGeneration.generateIfNeeded(for: article, force: true) }
            }
        }
    }
}

@MainActor
private final class ContentVideoState: ObservableObject {
    @Published var isPlaying = false
    @Published var hasStarted = false
    let player = AVPlayer()
    private var loadedURL: URL?

    func toggle(_ url: URL) {
        if loadedURL != url {
            if url.host == "www.youtube.com" || url.host == "www.youtube-nocookie.com" {
                player.replaceCurrentItem(with: nil)
            } else {
                player.replaceCurrentItem(with: AVPlayerItem(url: url))
            }
            loadedURL = url
        }
        hasStarted = true
        if isPlaying {
            pause()
        } else {
            player.play()
            isPlaying = true
        }
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func reset() {
        pause()
        player.replaceCurrentItem(with: nil)
        loadedURL = nil
        hasStarted = false
    }
}

private struct InlineContentVideo: View {
    let videoURL: URL
    let articleURL: URL
    let player: AVPlayer
    let isPlaying: Bool

    var body: some View {
        Group {
            if videoURL.host == "www.youtube.com" || videoURL.host == "www.youtube-nocookie.com" {
                EmbeddedYouTubeVideo(videoURL: videoURL, articleURL: articleURL, isPlaying: isPlaying)
            } else {
                NativeContentVideo(player: player)
            }
        }
    }
}

private struct NativeContentVideo: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }
}

private struct EmbeddedYouTubeVideo: NSViewRepresentable {
    let videoURL: URL
    let articleURL: URL
    let isPlaying: Bool

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.underPageBackgroundColor = .black
        var components = URLComponents(url: videoURL, resolvingAgainstBaseURL: false)
        let existingQueryItems = components?.queryItems ?? []
        components?.queryItems = existingQueryItems + [
            URLQueryItem(name: "enablejsapi", value: "1"),
            URLQueryItem(name: "autoplay", value: isPlaying ? "1" : "0"),
            URLQueryItem(name: "playsinline", value: "1")
        ]
        let embedURL = components?.url ?? videoURL
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;width:100%;height:100%;background:#111}iframe{border:0;width:100%;height:100%}</style>
        <script>
        var wantedPlaying = \(isPlaying ? "true" : "false");
        function setPlaying(playing) {
          wantedPlaying = playing;
          var frame = document.getElementById('video');
          if (frame && frame.contentWindow) {
            frame.contentWindow.postMessage(JSON.stringify({event:'command',func:playing?'playVideo':'pauseVideo',args:[]}), '*');
          }
        }
        </script></head><body><iframe id="video" src="\(embedURL.absoluteString)" onload="setPlaying(wantedPlaying)" allow="autoplay; encrypted-media; picture-in-picture" allowfullscreen referrerpolicy="strict-origin-when-cross-origin"></iframe></body></html>
        """
        webView.loadHTMLString(html, baseURL: articleURL)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        nsView.evaluateJavaScript("setPlaying(\(isPlaying ? "true" : "false"))", completionHandler: nil)
    }
}

private struct PopoverWindowCornerRadius: NSViewRepresentable {
    var radius: CGFloat
    var onPresentation: () -> Void
    var onDismissal: () -> Void

    func makeNSView(context: Context) -> WindowCornerRadiusView {
        let view = WindowCornerRadiusView()
        view.radius = radius
        view.onPresentation = onPresentation
        view.onDismissal = onDismissal
        return view
    }

    func updateNSView(_ nsView: WindowCornerRadiusView, context: Context) {
        nsView.radius = radius
        nsView.onPresentation = onPresentation
        nsView.onDismissal = onDismissal
        nsView.updateWindow()
    }
}

private final class WindowCornerRadiusView: NSView {
    var radius: CGFloat = 18
    var onPresentation: () -> Void = {}
    var onDismissal: () -> Void = {}
    private var lastContentSize = NSSize.zero
    private var observers: [NSObjectProtocol] = []
    private var isPresented = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installWindowObservers()
        DispatchQueue.main.async { [weak self] in
            self?.updateWindow()
        }
    }

    private func installWindowObservers() {
        guard let window, observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.markPresented()
                }
            },
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.markDismissed()
                }
            }
        ]
    }

    private func markPresented() {
        guard !isPresented else { return }
        isPresented = true
        onPresentation()
    }

    private func markDismissed() {
        guard isPresented else { return }
        isPresented = false
        onDismissal()
    }

    override func layout() {
        super.layout()
        DispatchQueue.main.async { [weak self] in
            self?.updateWindow()
        }
    }

    func updateWindow() {
        guard let window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear

        var views: [NSView] = []
        var currentView = window.contentView
        while let view = currentView {
            views.append(view)
            currentView = view.superview
        }

        for view in views {
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.clear.cgColor
            view.layer?.cornerRadius = radius
            view.layer?.cornerCurve = .continuous
            view.layer?.masksToBounds = true
        }

        let contentSize = bounds.size
        guard contentSize.width > 0, contentSize.height > 0,
              abs(contentSize.width - lastContentSize.width) > 0.5 || abs(contentSize.height - lastContentSize.height) > 0.5
        else { return }

        lastContentSize = contentSize
        window.setContentSize(contentSize)
    }
}

private struct FoodAdvice: View {
    let meal: MealPeriod
    @ObservedObject var mealRecommendations: MeituanTopOneStore
    @ObservedObject var contextMonitor: ContextMonitor

    private var order: String {
        switch meal {
        case .lunch: "照烧鸡腿饭 + 时蔬"
        case .afternoonTea: "燕麦拿铁 + 黄油可颂"
        case .dinner: "番茄牛腩饭"
        case .night: "鲜肉小馄饨 + 紫菜蛋皮"
        }
    }
    private var price: String {
        switch meal {
        case .lunch: "示例 ¥29"
        case .afternoonTea: "示例 ¥28"
        case .dinner: "示例 ¥36"
        case .night: "示例 ¥22"
        }
    }

    var body: some View {
        let topOne = mealRecommendations.topOne(for: meal)
        let deliveryURL = topOne?.landingURL ?? URL(string: "https://waimai.meituan.com/")!
        let nearbyURL = URL(string: meal == .afternoonTea ? "https://maps.apple.com/?q=咖啡" : "https://maps.apple.com/?q=馄饨")!
        VStack(alignment: .leading, spacing: 11) {
            VStack(alignment: .leading, spacing: 12) {
                Text(topOne?.itemName ?? order)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(CikePalette.primaryText)
                HStack(alignment: .firstTextBaseline) {
                    Text(topOne?.priceText ?? price).font(.system(size: 20, weight: .semibold)).foregroundStyle(CikePalette.primaryText)
                    Spacer()
                    Text(topOne?.deliveryText ?? "预计送达 25–35 分钟").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Button {
                        contextMonitor.recordExternalAction("delivery_opened", destination: deliveryURL)
                        NSWorkspace.shared.open(deliveryURL)
                    } label: {
                        Label("打开美团外卖", systemImage: "arrow.up.right").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(GlassActionStyle(isPrimary: true))
                    Button {
                        contextMonitor.recordExternalAction("nearby_food_opened", destination: nearbyURL)
                        NSWorkspace.shared.open(nearbyURL)
                    } label: {
                        Label("附近堂食", systemImage: "location").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(GlassActionStyle())
                }
            }
            .padding(13)
            .background(CikePalette.cardSurface, in: RoundedRectangle(cornerRadius: 14))
        }
        .task(id: meal) {
            await mealRecommendations.loadTopOne(for: meal)
        }
    }
}

private struct TravelAdvice: View {
    @ObservedObject var contextMonitor: ContextMonitor
    private let sights: [(String, String, String)] = [
        ("西湖 · 苏堤", "湖边散步 / 自然风景", "免费"),
        ("灵隐飞来峰", "山林古寺 / 文化历史", "示例 ¥45"),
        ("中国茶叶博物馆", "茶文化 / 安静室内", "免费 · 示例")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("去杭州，慢慢逛两天。")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(CikePalette.primaryText)
            Text("按轻松、不赶路的方向，先替你排好一份计划。")
                .font(.system(size: 11)).foregroundStyle(.secondary)

            HStack(spacing: 8) {
                summaryCell(title: "出行方式", main: "高铁到杭州", detail: "约 1 小时 · 价格待查询")
                summaryCell(title: "住宿建议", main: "湖滨商圈", detail: "交通方便 · 房价待查询")
            }
            Divider()
            HStack {
                Text("偏好景点 Top 3").font(.system(size: 11, weight: .semibold))
                Spacer()
                Text("偏好示例").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            VStack(spacing: 6) {
                ForEach(Array(sights.enumerated()), id: \.offset) { index, sight in
                    HStack(spacing: 8) {
                        Text("\(index + 1)").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                            .frame(width: 21, height: 21).background(CikePalette.secondaryActionSurface, in: RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sight.0).font(.system(size: 10, weight: .medium))
                            Text(sight.1).font(.system(size: 8)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(sight.2).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                    }
                    .padding(7)
                    .background(CikePalette.smallCardSurface, in: RoundedRectangle(cornerRadius: 9))
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                Label("Day 1　杭州东 → 湖滨入住 → 西湖散步", systemImage: "1.circle")
                Label("Day 2　灵隐飞来峰 → 茶叶博物馆 → 返程", systemImage: "2.circle")
            }
            .font(.system(size: 9)).foregroundStyle(.secondary)
            Button {
                let url = URL(string: "https://maps.apple.com/?q=杭州西湖")!
                contextMonitor.recordExternalAction("travel_map_opened", destination: url)
                NSWorkspace.shared.open(url)
            } label: {
                Label("在地图中查看行程", systemImage: "map").frame(maxWidth: .infinity)
            }
            .buttonStyle(GlassActionStyle(isPrimary: true))
        }
    }

    private func summaryCell(title: String, main: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 9)).foregroundStyle(.tertiary)
            Text(main).font(.system(size: 11, weight: .semibold))
            Text(detail).font(.system(size: 8)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(CikePalette.cardSurface, in: RoundedRectangle(cornerRadius: 11))
    }
}

private func eyebrow(_ text: String) -> some View {
    Text(text.uppercased())
        .font(.system(size: 9, weight: .medium, design: .rounded))
        .tracking(0.4)
        .foregroundStyle(.secondary)
}

private struct GlassActionStyle: ButtonStyle {
    var isPrimary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .medium))
            .padding(.vertical, 8)
            .padding(.horizontal, 8)
            .foregroundStyle(isPrimary ? Color.white.opacity(0.98) : Color.primary.opacity(0.76))
            .background(isPrimary ? CikePalette.primaryAction : CikePalette.secondaryActionSurface, in: RoundedRectangle(cornerRadius: 9))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
