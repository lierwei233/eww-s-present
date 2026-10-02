import AppKit
import ApplicationServices
import Combine
import SwiftUI

@main
struct CikeApp: App {
    @StateObject private var contextMonitor = ContextMonitor()
    @StateObject private var mealRecommendations = MeituanTopOneStore()
    @StateObject private var sspaiTopOne = SspaiTopOneStore()

    var body: some Scene {
        MenuBarExtra {
            RecommendationPopover(
                contextMonitor: contextMonitor,
                mealRecommendations: mealRecommendations,
                sspaiTopOne: sspaiTopOne
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
    }
}

enum MealPeriod: String, Sendable, Hashable {
    case lunch, dinner, night
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
    case lunch, dinner, night, reply, content, chatPermission, chatUnavailable

    static func meal(at date: Date, calendar: Calendar = .current) -> AdviceScene? {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        guard let hour = parts.hour, let minute = parts.minute else { return nil }
        let time = hour * 60 + minute
        if (11 * 60 + 30)..<(13 * 60 + 30) ~= time { return .lunch }
        if (16 * 60 + 30)..<(19 * 60 + 30) ~= time { return .dinner }
        if time >= 22 * 60 || time < 60 { return .night }
        return nil
    }

    static func isHolidayTravelWindow(_ date: Date, calendar: Calendar = .current) -> Bool {
        let parts = calendar.dateComponents([.month, .day], from: date)
        guard let month = parts.month, let day = parts.day else { return false }
        return (month == 9 && day >= 20) || (month == 10 && day <= 7)
    }
}

@MainActor
private final class ContextMonitor: ObservableObject {
    @Published private(set) var scene: AdviceScene = .reply
    @Published private(set) var presentedScene: AdviceScene?
    @Published private(set) var replySuggestion: String?
    @Published private(set) var chatDwellSeconds = 0
    @Published private(set) var chatDiagnostic = ""

    private let weChatBundleID = "com.tencent.xinWeChat"
    private var weChatBecameActiveAt: Date?
    private var lastContextReadAt: Date?
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    func requestAccessibilityPermission() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    private func refresh(now: Date = .now) {
        let isWeChatFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == weChatBundleID
        if isWeChatFrontmost {
            if weChatBecameActiveAt == nil { weChatBecameActiveAt = now }
            let elapsed = Int(now.timeIntervalSince(weChatBecameActiveAt ?? now))
            chatDwellSeconds = elapsed
            if elapsed >= 7 {
                if updateChatSuggestion(now: now) { return }
            }
        } else {
            weChatBecameActiveAt = nil
            lastContextReadAt = nil
            replySuggestion = nil
            chatDiagnostic = ""
            chatDwellSeconds = 0
        }

        if let meal = AdviceScene.meal(at: now), canPresent(meal, at: now) {
            setScene(meal)
            return
        }
        setScene(.content)
    }

    @discardableResult
    private func updateChatSuggestion(now: Date) -> Bool {
        guard AXIsProcessTrusted() else {
            chatDiagnostic = "macOS 尚未向当前签名版本开放辅助功能读取权限。请在系统设置中重新添加并开启此刻，然后回到这里。"
            setScene(.chatPermission)
            return true
        }
        if let lastContextReadAt, now.timeIntervalSince(lastContextReadAt) < 3 {
            return true
        }
        lastContextReadAt = now
        guard let snapshot = WeChatAccessibilityReader.focusedConversation(bundleID: weChatBundleID) else {
            replySuggestion = nil
            chatDiagnostic = "系统已授权，但微信没有提供当前焦点窗口。请回到微信对话，再点一下回复输入框。"
            setScene(.chatUnavailable)
            return true
        }
        guard snapshot.isReplyComposer else {
            replySuggestion = nil
            chatDiagnostic = "系统识别到焦点「\(snapshot.role.isEmpty ? "未知控件" : snapshot.role)」。请在微信回复框内点一下，让光标保持在输入框。"
            setScene(.chatUnavailable)
            return true
        }
        guard !snapshot.visibleText.isEmpty else {
            chatDiagnostic = "已识别到回复框，但微信没有提供可读取的可见对话文字。"
            setScene(.chatUnavailable)
            return true
        }
        replySuggestion = LocalReplyComposer.suggestion(for: snapshot.visibleText)
        chatDiagnostic = "已读取当前微信窗口的可见文字，并在本机生成建议。"
        setScene(.reply)
        return true
    }

    private func setScene(_ newScene: AdviceScene) {
        // Avoid publishing every second when the scene has not changed.
        switch (scene, newScene) {
        case (.lunch, .lunch), (.dinner, .dinner), (.night, .night), (.reply, .reply),
             (.content, .content), (.chatPermission, .chatPermission), (.chatUnavailable, .chatUnavailable):
            break
        default:
            scene = newScene
        }
    }

    func recordPresentation(of scene: AdviceScene, now: Date = .now) {
        guard let meal = MealPeriod(scene) else { return }
        let key = mealCountKey(for: meal, at: now)
        let count = UserDefaults.standard.integer(forKey: key)
        guard count < 2 else { return }
        UserDefaults.standard.set(count + 1, forKey: key)
    }

    func beginPresentation() {
        let selectedScene = scene
        presentedScene = selectedScene
        recordPresentation(of: selectedScene)
    }

    func endPresentation() {
        presentedScene = nil
    }

    private func canPresent(_ scene: AdviceScene, at date: Date) -> Bool {
        guard let meal = MealPeriod(scene) else { return false }
        return UserDefaults.standard.integer(forKey: mealCountKey(for: meal, at: date)) < 2
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
        case .dinner: self = .dinner
        case .night: self = .night
        default: return nil
        }
    }
}

private enum WeChatAccessibilityReader {
    struct FocusedConversation {
        let role: String
        let label: String
        let visibleText: [String]

        var isReplyComposer: Bool {
            let normalizedLabel = label.lowercased()
            if normalizedLabel.contains("搜索") || normalizedLabel.contains("search") { return false }
            if role == (kAXTextAreaRole as String) || role == "AXTextView" { return true }
            return role == (kAXTextFieldRole as String)
        }
    }

    static func focusedConversation(bundleID: String) -> FocusedConversation? {
        guard let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return nil }
        let appElement = AXUIElementCreateApplication(runningApp.processIdentifier)
        guard let focusRef = copyAttribute(kAXFocusedUIElementAttribute as CFString, from: appElement),
              CFGetTypeID(focusRef) == AXUIElementGetTypeID(),
              let windowRef = copyAttribute(kAXFocusedWindowAttribute as CFString, from: appElement),
              CFGetTypeID(windowRef) == AXUIElementGetTypeID() else { return nil }
        let focusedElement = unsafeDowncast(focusRef, to: AXUIElement.self)
        let role = (copyAttribute(kAXRoleAttribute as CFString, from: focusedElement) as? String) ?? ""
        let label = [kAXPlaceholderValueAttribute, kAXDescriptionAttribute, kAXTitleAttribute]
            .compactMap { copyAttribute($0 as CFString, from: focusedElement) as? String }
            .joined(separator: " ")
        let window = unsafeDowncast(windowRef, to: AXUIElement.self)
        var values: [String] = []
        collectText(from: window, depth: 0, values: &values)
        var unique: [String] = []
        for value in values where !unique.contains(value) { unique.append(value) }
        return FocusedConversation(role: role, label: label, visibleText: Array(unique.suffix(40)))
    }

    private static func collectText(from element: AXUIElement, depth: Int, values: inout [String]) {
        guard depth < 12, values.count < 100 else { return }
        let role = copyAttribute(kAXRoleAttribute as CFString, from: element) as? String
        if role == (kAXStaticTextRole as String) || role == (kAXTextFieldRole as String) || role == (kAXTextAreaRole as String) {
            let value = (copyAttribute(kAXValueAttribute as CFString, from: element) as? String)
                ?? (copyAttribute(kAXTitleAttribute as CFString, from: element) as? String)
            if let value {
                let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if cleaned.count >= 2 && cleaned.count <= 500 { values.append(cleaned) }
            }
        }
        guard let children = copyAttribute(kAXChildrenAttribute as CFString, from: element) as? [AXUIElement] else { return }
        for child in children { collectText(from: child, depth: depth + 1, values: &values) }
    }

    private static func copyAttribute(_ attribute: CFString, from element: AXUIElement) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &result) == .success else { return nil }
        return result
    }
}

private enum LocalReplyComposer {
    static func suggestion(for visibleText: [String]) -> String {
        let context = visibleText.suffix(20).joined(separator: " ")
        if containsAny(context, ["有空吗", "要不要一起", "一起去", "约吗", "出来吗", "周末有空"]) {
            return "「谢谢你想到我。我看看安排，晚点给你答复。」"
        }
        if containsAny(context, ["能不能帮", "可以帮我", "麻烦你", "方便帮", "帮我一下"]) {
            return "「我先确认一下手头的安排，稍后回复你。」"
        }
        if context.contains("？") || context.contains("?") {
            return "「我看到了，想清楚后认真回复你。」"
        }
        return "「我收到啦，给我一点时间想想，晚些回复你。」"
    }

    private static func containsAny(_ text: String, _ phrases: [String]) -> Bool {
        phrases.contains(where: text.contains)
    }
}

private struct RecommendationPopover: View {
    @ObservedObject var contextMonitor: ContextMonitor
    @ObservedObject var mealRecommendations: MeituanTopOneStore
    @ObservedObject var sspaiTopOne: SspaiTopOneStore
    private var scene: AdviceScene { contextMonitor.presentedScene ?? contextMonitor.scene }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.bottom, 16)
            switch scene {
            case .reply: ReplyAdvice(suggestion: contextMonitor.replySuggestion)
            case .content: ContentAdvice(article: sspaiTopOne.article, contentStore: sspaiTopOne)
            case .lunch: FoodAdvice(meal: .lunch, mealRecommendations: mealRecommendations)
            case .dinner: FoodAdvice(meal: .dinner, mealRecommendations: mealRecommendations)
            case .night: FoodAdvice(meal: .night, mealRecommendations: mealRecommendations)
            case .chatPermission: ChatPermissionAdvice(dwell: contextMonitor.chatDwellSeconds, diagnostic: contextMonitor.chatDiagnostic, onEnable: contextMonitor.requestAccessibilityPermission)
            case .chatUnavailable: ChatUnavailableAdvice(diagnostic: contextMonitor.chatDiagnostic)
            }
            footer.padding(.top, 14)
        }
        .padding(18)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .background(PopoverWindowCornerRadius(
            radius: 18,
            onPresentation: contextMonitor.beginPresentation,
            onDismissal: contextMonitor.endPresentation
        ))
    }

    private var header: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.66))
                OpenFocusLogo(lineWidth: 1.45, color: .primary.opacity(0.72)).padding(6)
            }
            .frame(width: 29, height: 29)
            HStack(spacing: 4) {
                Text("此刻").font(.system(size: 14, weight: .semibold))
                Text("· 私人管家").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Text(Date.now, format: .dateTime.hour().minute())
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.tertiary)
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

private struct ReplyAdvice: View {
    var suggestion: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            eyebrow("根据微信当前可见对话")
            Text(suggestion ?? "先回：「我看到了，给我一点时间想想，晚些回复你。」")
                .font(.system(size: 20, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(3)
            Text("建议在本机根据当前可见文字生成，不会自动发送。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Divider().padding(.vertical, 3)
            Label("先照顾好自己的感受，再决定下一步。", systemImage: "sparkle")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

private struct ContentAdvice: View {
    var article: SspaiArticle?
    @ObservedObject var contentStore: SspaiTopOneStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            eyebrow(article?.source ?? "此刻发现")
            Text(article?.title ?? "正在为你找一篇值得读的内容。")
                .font(.system(size: 20, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(3)
            Text(article.map { "一条来自 \($0.source) 的当下推荐。" } ?? "内容加载后会附上原文链接。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if let article {
                Link(destination: article.url) {
                    Label("阅读原文", systemImage: "arrow.up.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(GlassActionStyle(isPrimary: true))
            }
        }
        .task {
            await contentStore.loadRandom()
        }
    }
}

private struct ChatPermissionAdvice: View {
    let dwell: Int
    let diagnostic: String
    let onEnable: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            eyebrow("微信对话停留 \(dwell) 秒")
            Text("需要一点上下文，才能帮你想回复。")
                .font(.system(size: 19, weight: .semibold))
            Text("允许「此刻」读取微信当前窗口的可见文字。内容只在本机临时处理，不会保存、上传或自动发送。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button(action: onEnable) {
                Label("开启微信上下文辅助", systemImage: "hand.raised").frame(maxWidth: .infinity)
            }
            .buttonStyle(GlassActionStyle(isPrimary: true))
            Text(diagnostic).font(.system(size: 9)).foregroundStyle(.tertiary)
        }
    }
}

private struct ChatUnavailableAdvice: View {
    let diagnostic: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            eyebrow("微信对话")
            Text("我还没读到当前对话内容。")
                .font(.system(size: 19, weight: .semibold))
            Text(diagnostic.isEmpty ? "请保持目标聊天窗口在前台，并确认「此刻」拥有辅助功能权限。内容只在本机处理；建议生成后仍由你决定是否使用。" : diagnostic)
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
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

    private var title: String {
        switch meal {
        case .lunch: "午餐，吃份鸡腿饭吧。"
        case .dinner: "晚餐，来份热乎的牛肉饭。"
        case .night: "夜宵，吃碗馄饨吧。"
        }
    }
    private var timeHint: String {
        switch meal {
        case .lunch: "午间好好吃饭，下午继续有精神。"
        case .dinner: "一份扎实的晚餐，今晚就选它。"
        case .night: "一份刚刚好的热汤，不用再纠结。"
        }
    }
    private var order: String {
        switch meal {
        case .lunch: "照烧鸡腿饭 + 时蔬"
        case .dinner: "番茄牛腩饭"
        case .night: "鲜肉小馄饨 + 紫菜蛋皮"
        }
    }
    private var description: String {
        switch meal {
        case .lunch: "荤素搭配 · 午餐一份刚刚好"
        case .dinner: "热乎饱腹 · 晚餐不用再挑"
        case .night: "清爽热汤 · 适合夜里垫垫肚子"
        }
    }
    private var price: String {
        switch meal {
        case .lunch: "示例 ¥29"
        case .dinner: "示例 ¥36"
        case .night: "示例 ¥22"
        }
    }

    var body: some View {
        let topOne = mealRecommendations.topOne(for: meal)
        VStack(alignment: .leading, spacing: 11) {
            eyebrow(meal == .lunch ? "午餐时间 · 给你一个选择" : meal == .dinner ? "晚餐时间 · 给你一个选择" : "夜宵时间 · 给你一个选择")
            Text(title)
                .font(.system(size: 21, weight: .semibold))
            Text(timeHint)
                .font(.system(size: 12)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Text(topOne?.itemName ?? order)
                    .font(.system(size: 14, weight: .semibold))
                Text(topOne?.description ?? description)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline) {
                    Text(topOne?.priceText ?? price).font(.system(size: 19, weight: .semibold))
                    Spacer()
                    Text(topOne?.deliveryText ?? "预计送达 25–35 分钟").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Link(destination: topOne?.landingURL ?? URL(string: "https://waimai.meituan.com/")!) {
                        Label("打开美团外卖", systemImage: "arrow.up.right").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(GlassActionStyle(isPrimary: true))
                    Link(destination: URL(string: "https://maps.apple.com/?q=馄饨")!) {
                        Label("附近堂食", systemImage: "location").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(GlassActionStyle())
                }
            }
            .padding(13)
            .background(.white.opacity(0.38), in: RoundedRectangle(cornerRadius: 14))
            Text(topOne?.statusText ?? "示例推荐；商家、价格和距离需接入定位及平台后实时提供。")
                .font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .task(id: meal) {
            await mealRecommendations.loadTopOne(for: meal)
        }
    }
}

private struct TravelAdvice: View {
    private let sights: [(String, String, String)] = [
        ("西湖 · 苏堤", "湖边散步 / 自然风景", "免费"),
        ("灵隐飞来峰", "山林古寺 / 文化历史", "示例 ¥45"),
        ("中国茶叶博物馆", "茶文化 / 安静室内", "免费 · 示例")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            eyebrow("国庆假期将近 · 出游灵感")
            Text("去杭州，慢慢逛两天。")
                .font(.system(size: 21, weight: .semibold))
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
                            .frame(width: 21, height: 21).background(.white.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sight.0).font(.system(size: 10, weight: .medium))
                            Text(sight.1).font(.system(size: 8)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(sight.2).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                    }
                    .padding(7)
                    .background(.white.opacity(0.28), in: RoundedRectangle(cornerRadius: 9))
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                Label("Day 1　杭州东 → 湖滨入住 → 西湖散步", systemImage: "1.circle")
                Label("Day 2　灵隐飞来峰 → 茶叶博物馆 → 返程", systemImage: "2.circle")
            }
            .font(.system(size: 9)).foregroundStyle(.secondary)
            Link(destination: URL(string: "https://maps.apple.com/?q=杭州西湖")!) {
                Label("在地图中查看行程", systemImage: "map").frame(maxWidth: .infinity)
            }
            .buttonStyle(GlassActionStyle(isPrimary: true))
            Text("示例计划；车次、房价、门票与偏好需接入数据后确认。")
                .font(.system(size: 8)).foregroundStyle(.tertiary)
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
        .background(.white.opacity(0.34), in: RoundedRectangle(cornerRadius: 11))
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
            .foregroundStyle(isPrimary ? Color.white : Color.primary.opacity(0.78))
            .background(isPrimary ? Color.primary.opacity(0.78) : Color.white.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
