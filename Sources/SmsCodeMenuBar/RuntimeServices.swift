import AppKit
import ApplicationServices
import CoreServices
import Foundation
import SmsCodeCore

final class MessagesChangeMonitor {
    private let watchedURL: URL
    private let onChange: () -> Void
    private let queue = DispatchQueue(label: "local.sms-code-menubar.messages-monitor")
    private var stream: FSEventStreamRef?

    init(watchedURL: URL, onChange: @escaping () -> Void) {
        self.watchedURL = watchedURL
        self.onChange = onChange
    }

    func start() {
        guard stream == nil else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let monitor = Unmanaged<MessagesChangeMonitor>.fromOpaque(info).takeUnretainedValue()
            monitor.onChange()
        }

        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [watchedURL.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
        )

        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        stop()
    }
}

final class AccessibilityReader {
    func hasPermission() -> Bool {
        AXIsProcessTrusted()
    }

    func requestPermissionPrompt() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func focusedElement() -> FocusedElementSnapshot? {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        ) == .success else {
            return nil
        }

        let element = resolveWebFocus(focused as! AXUIElement)
        return FocusedElementSnapshot(
            role: stringAttribute(kAXRoleAttribute, from: element),
            title: stringAttribute(kAXTitleAttribute, from: element),
            description: stringAttribute(kAXDescriptionAttribute, from: element),
            placeholder: stringAttribute(kAXPlaceholderValueAttribute, from: element),
            value: stringAttribute(kAXValueAttribute, from: element),
            width: width(from: element),
            context: contextText(around: element),
            siblingTextInputCount: siblingTextInputCount(around: element)
        )
    }

    func focusedElementDiagnostic() -> String {
        let trusted = AXIsProcessTrusted()
        let snapshot = focusedElement()
        let lines = [
            "createdAt=\(ISO8601DateFormatter().string(from: Date()))",
            "accessibilityTrusted=\(trusted)",
            snapshot?.diagnosticText ?? "focusedElement=nil"
        ]
        return lines.joined(separator: "\n")
    }

    func targetContext() -> AutomationTargetContext {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let focused = rawFocusedElement().map(resolveWebFocus)
        let webArea = focused.flatMap(webAreaNear)

        let urlString = webArea.flatMap { stringAttribute("AXURL", from: $0) }
        let title = webArea.flatMap { stringAttribute(kAXTitleAttribute, from: $0) }
            ?? focused.flatMap { stringAttribute(kAXTitleAttribute, from: $0) }
        let pageText = focused.map { contextText(around: $0) }

        return AutomationTargetContext(
            bundleIdentifier: frontmost?.bundleIdentifier,
            applicationName: frontmost?.localizedName,
            urlString: urlString,
            title: title,
            pageText: pageText
        )
    }

    func findLoginButtonNearFocus(matcher: LoginButtonMatcher) -> AXUIElement? {
        let log = ButtonScanLog()

        guard let focusedElement = rawFocusedElement() else {
            log.append("ERROR: 无法获取焦点元素")
            log.flush()
            return nil
        }

        let start = resolveWebFocus(focusedElement)
        let focusedRole = stringAttribute(kAXRoleAttribute, from: start) ?? "nil"
        log.append("焦点 role=\(focusedRole)")

        var visited = Set<AXUIElementHash>()
        let roots = searchRoots(from: start)
        log.append("搜索根数量=\(roots.count)")

        var bestCandidate: ButtonCandidate?

        for (rootIndex, root) in roots.enumerated() {
            var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
            var scannedForRoot = 0

            while !queue.isEmpty, scannedForRoot < 600 {
                let current = queue.removeFirst()
                scannedForRoot += 1

                let hash = AXUIElementHash(element: current.element)
                if visited.contains(hash) { continue }
                visited.insert(hash)

                let role = stringAttribute(kAXRoleAttribute, from: current.element) ?? ""
                let title = stringAttribute(kAXTitleAttribute, from: current.element)
                let desc = stringAttribute(kAXDescriptionAttribute, from: current.element)
                let value = stringAttribute(kAXValueAttribute, from: current.element)

                if let candidate = candidate(
                    element: current.element,
                    role: role,
                    title: title,
                    desc: desc,
                    value: value,
                    rootIndex: rootIndex,
                    depth: current.depth,
                    matcher: matcher,
                    log: log
                ), candidate.score > (bestCandidate?.score ?? Int.min) {
                    bestCandidate = candidate
                }

                guard current.depth < 8 else { continue }

                var children: CFTypeRef?
                if AXUIElementCopyAttributeValue(current.element, kAXChildrenAttribute as CFString, &children) == .success,
                   let childElements = children as? [AXUIElement] {
                    for child in childElements.prefix(90) {
                        queue.append((child, current.depth + 1))
                    }
                }
            }
        }

        if let bestCandidate {
            log.append("选中: score=\(bestCandidate.score) root=\(bestCandidate.rootIndex) depth=\(bestCandidate.depth) \(bestCandidate.summary)")
        } else {
            log.append("未找到匹配按钮")
        }

        log.flush()
        return bestCandidate?.element
    }

    func currentAutomationAnchor() -> AXUIElement? {
        rawFocusedElement().map(resolveWebFocus)
    }

    func findVerificationRequestButtonNearFocus(matcher: VerificationRequestButtonMatcher) -> AXUIElement? {
        findVerificationRequestButton(near: nil, matcher: matcher)
    }

    func findVerificationRequestButtonInWebArea(matcher: VerificationRequestButtonMatcher) -> AXUIElement? {
        let roots = frontmostWebAreaRoots()
        guard !roots.isEmpty else {
            logRequestButtonScan(candidates: [], result: "未找到前台网页搜索根", matched: "nil")
            return nil
        }

        for root in roots {
            if let button = scanForVerificationRequestButton(in: root, matcher: matcher) {
                return button
            }
        }

        return nil
    }

    private func scanForVerificationRequestButton(in root: AXUIElement, matcher: VerificationRequestButtonMatcher) -> AXUIElement? {
        var visited = Set<AXUIElementHash>()
        var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
        var scanned = 0
        var allCandidates: [String] = []

        while !queue.isEmpty, scanned < 2_500 {
            let current = queue.removeFirst()
            scanned += 1

            let hash = AXUIElementHash(element: current.element)
            if visited.contains(hash) { continue }
            visited.insert(hash)

            let role = stringAttribute(kAXRoleAttribute, from: current.element) ?? ""
            let title = stringAttribute(kAXTitleAttribute, from: current.element)
            let desc = stringAttribute(kAXDescriptionAttribute, from: current.element)
            let value = stringAttribute(kAXValueAttribute, from: current.element)

            if matcher.isActionableRole(role) {
                let isMatch = matcher.isRequestCodeButton(role: role, title: title, description: desc, value: value)
                allCandidates.append("[depth=\(current.depth)] \(matcher.describeCandidate(role: role, title: title, description: desc, value: value)) -> match=\(isMatch)")
            }

            if matcher.isRequestCodeButton(role: role, title: title, description: desc, value: value) {
                logRequestButtonScan(candidates: allCandidates, result: "选中", matched: matcher.describeCandidate(role: role, title: title, description: desc, value: value))
                return current.element
            }

            guard current.depth < 16 else { continue }

            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(current.element, kAXChildrenAttribute as CFString, &children) == .success,
               let childElements = children as? [AXUIElement] {
                for child in childElements.prefix(120) {
                    queue.append((child, current.depth + 1))
                }
            }
        }

        logRequestButtonScan(candidates: allCandidates, result: "未找到", matched: "nil")
        return nil
    }

    private func logRequestButtonScan(candidates: [String], result: String, matched: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let content = """
        === Request Button Scan \(timestamp) ===
        结果: \(result)
        匹配: \(matched)
        扫描到的可交互候选 (\(candidates.count) 个):
        \(candidates.joined(separator: "\n"))
        === End ===

        """
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/SmsCodeMenuBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("request-button-scan.log")
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            if let data = content.data(using: .utf8) {
                handle.write(data)
            }
            try? handle.close()
        } else {
            try? content.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    func findVerificationRequestButton(near anchor: AXUIElement?, matcher: VerificationRequestButtonMatcher) -> AXUIElement? {
        var visited = Set<AXUIElementHash>()
        let roots = searchRootsNearAnchor(anchor)
        var bestCandidate: ButtonCandidate?

        for (rootIndex, root) in roots.enumerated() {
            var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
            var scannedForRoot = 0

            while !queue.isEmpty, scannedForRoot < 600 {
                let current = queue.removeFirst()
                scannedForRoot += 1

                let hash = AXUIElementHash(element: current.element)
                if visited.contains(hash) { continue }
                visited.insert(hash)

                let role = stringAttribute(kAXRoleAttribute, from: current.element) ?? ""
                let title = stringAttribute(kAXTitleAttribute, from: current.element)
                let desc = stringAttribute(kAXDescriptionAttribute, from: current.element)
                let value = stringAttribute(kAXValueAttribute, from: current.element)
                let isRequestButton = matcher.isRequestCodeButton(
                    role: role,
                    title: title,
                    description: desc,
                    value: value
                )

                if isRequestButton {
                    let candidate = ButtonCandidate(
                        element: current.element,
                        score: requestCodeScore(title: title, desc: desc, value: value, depth: current.depth, rootIndex: rootIndex, isTextFallback: role == "AXStaticText" || role == "AXText"),
                        rootIndex: rootIndex,
                        depth: current.depth,
                        summary: matcher.describeCandidate(role: role, title: title, description: desc, value: value)
                    )
                    if candidate.score > (bestCandidate?.score ?? Int.min) {
                        bestCandidate = candidate
                    }
                }

                guard current.depth < 8 else { continue }

                var children: CFTypeRef?
                if AXUIElementCopyAttributeValue(current.element, kAXChildrenAttribute as CFString, &children) == .success,
                   let childElements = children as? [AXUIElement] {
                    for child in childElements.prefix(90) {
                        queue.append((child, current.depth + 1))
                    }
                }
            }
        }

        return bestCandidate?.element
    }

    func clickVerificationRequestControlNearAccountField(
        near anchor: AXUIElement?,
        matcher: VerificationRequestButtonMatcher
    ) -> Bool {
        guard let anchor else { return false }
        let roots = searchRoots(from: anchor).prefix(6)
        let anchorFrame = frame(of: anchor)
        var visited = Set<AXUIElementHash>()
        var bestCandidate: ButtonCandidate?
        var candidates: [String] = []

        for (rootIndex, root) in roots.enumerated() {
            var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
            var scannedForRoot = 0

            while !queue.isEmpty, scannedForRoot < 700 {
                let current = queue.removeFirst()
                scannedForRoot += 1

                let hash = AXUIElementHash(element: current.element)
                if visited.contains(hash) { continue }
                visited.insert(hash)

                let role = stringAttribute(kAXRoleAttribute, from: current.element) ?? ""
                let title = stringAttribute(kAXTitleAttribute, from: current.element)
                let desc = stringAttribute(kAXDescriptionAttribute, from: current.element)
                let value = stringAttribute(kAXValueAttribute, from: current.element)

                if matcher.isRequestCodeButton(role: role, title: title, description: desc, value: value) {
                    let summary = matcher.describeCandidate(role: role, title: title, description: desc, value: value)
                    let candidate = ButtonCandidate(
                        element: current.element,
                        score: requestCodeControlScore(
                            title: title,
                            desc: desc,
                            value: value,
                            elementFrame: frame(of: current.element),
                            anchorFrame: anchorFrame,
                            depth: current.depth,
                            rootIndex: rootIndex,
                            isTextFallback: role == "AXStaticText" || role == "AXText"
                        ),
                        rootIndex: rootIndex,
                        depth: current.depth,
                        summary: summary
                    )
                    candidates.append("[root=\(rootIndex) depth=\(current.depth)] \(summary) score=\(candidate.score)")
                    if candidate.score > (bestCandidate?.score ?? Int.min) {
                        bestCandidate = candidate
                    }
                }

                guard current.depth < 8 else { continue }

                var children: CFTypeRef?
                if AXUIElementCopyAttributeValue(current.element, kAXChildrenAttribute as CFString, &children) == .success,
                   let childElements = children as? [AXUIElement] {
                    for child in childElements.prefix(90) {
                        queue.append((child, current.depth + 1))
                    }
                }
            }
        }

        if let bestCandidate, bestCandidate.score >= 60 {
            logRequestButtonScan(candidates: candidates, result: "局部发码控件选中", matched: bestCandidate.summary)
            return clickWebAction(bestCandidate.element)
        }

        logRequestButtonScan(candidates: candidates, result: "局部发码控件未找到", matched: "nil")
        return clickEmbeddedSendAreaNearAccountField(near: anchor)
    }

    func clickVerificationRequestControl(
        inProcessID processID: pid_t?,
        matcher: VerificationRequestButtonMatcher
    ) -> Bool {
        guard let processID else { return false }
        let roots = webAreaRoots(for: processID)
        var visited = Set<AXUIElementHash>()
        var bestCandidate: ButtonCandidate?
        var candidates: [String] = []

        for (rootIndex, root) in roots.enumerated() {
            var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
            var scannedForRoot = 0

            while !queue.isEmpty, scannedForRoot < 5_000 {
                let current = queue.removeFirst()
                scannedForRoot += 1

                let hash = AXUIElementHash(element: current.element)
                if visited.contains(hash) { continue }
                visited.insert(hash)

                let role = stringAttribute(kAXRoleAttribute, from: current.element) ?? ""
                let title = stringAttribute(kAXTitleAttribute, from: current.element)
                let desc = stringAttribute(kAXDescriptionAttribute, from: current.element)
                let value = stringAttribute(kAXValueAttribute, from: current.element)

                if matcher.isRequestCodeButton(role: role, title: title, description: desc, value: value) {
                    let summary = matcher.describeCandidate(role: role, title: title, description: desc, value: value)
                    let candidate = ButtonCandidate(
                        element: current.element,
                        score: requestCodeScore(
                            title: title,
                            desc: desc,
                            value: value,
                            depth: current.depth,
                            rootIndex: rootIndex,
                            isTextFallback: role == "AXStaticText" || role == "AXText"
                        ),
                        rootIndex: rootIndex,
                        depth: current.depth,
                        summary: summary
                    )
                    candidates.append("[root=\(rootIndex) depth=\(current.depth)] \(summary) score=\(candidate.score)")
                    if candidate.score > (bestCandidate?.score ?? Int.min) {
                        bestCandidate = candidate
                    }
                }

                guard current.depth < 16 else { continue }

                var children: CFTypeRef?
                if AXUIElementCopyAttributeValue(current.element, kAXChildrenAttribute as CFString, &children) == .success,
                   let childElements = children as? [AXUIElement] {
                    for child in childElements.prefix(160) {
                        queue.append((child, current.depth + 1))
                    }
                }
            }
        }

        guard let bestCandidate, bestCandidate.score >= 60 else {
            logRequestButtonScan(candidates: candidates, result: "进程发码控件未找到 pid=\(processID)", matched: "nil")
            return false
        }

        logRequestButtonScan(candidates: candidates, result: "进程发码控件选中 pid=\(processID)", matched: bestCandidate.summary)
        return clickWebAction(bestCandidate.element)
    }

    func findPrimaryRequestActionNearAccountField(
        near anchor: AXUIElement?,
        matcher: VerificationRequestButtonMatcher
    ) -> AXUIElement? {
        guard let anchor else { return nil }
        let roots = searchRoots(from: anchor).prefix(5)
        let anchorFrame = frame(of: anchor)
        var visited = Set<AXUIElementHash>()
        var bestCandidate: ButtonCandidate?
        var candidates: [String] = []

        for (rootIndex, root) in roots.enumerated() {
            var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
            var scannedForRoot = 0

            while !queue.isEmpty, scannedForRoot < 500 {
                let current = queue.removeFirst()
                scannedForRoot += 1

                let hash = AXUIElementHash(element: current.element)
                if visited.contains(hash) { continue }
                visited.insert(hash)

                let role = stringAttribute(kAXRoleAttribute, from: current.element) ?? ""
                let title = stringAttribute(kAXTitleAttribute, from: current.element)
                let desc = stringAttribute(kAXDescriptionAttribute, from: current.element)
                let value = stringAttribute(kAXValueAttribute, from: current.element)

                if isPrimaryRequestActionCandidate(role: role, title: title, desc: desc, value: value) {
                    let summary = matcher.describeCandidate(role: role, title: title, description: desc, value: value)
                    let candidate = ButtonCandidate(
                        element: current.element,
                        score: primaryRequestActionScore(
                            role: role,
                            title: title,
                            desc: desc,
                            value: value,
                            elementFrame: frame(of: current.element),
                            anchorFrame: anchorFrame,
                            depth: current.depth,
                            rootIndex: rootIndex
                        ),
                        rootIndex: rootIndex,
                        depth: current.depth,
                        summary: summary
                    )
                    candidates.append("[root=\(rootIndex) depth=\(current.depth)] \(summary) score=\(candidate.score)")
                    if candidate.score > (bestCandidate?.score ?? Int.min) {
                        bestCandidate = candidate
                    }
                }

                guard current.depth < 7 else { continue }

                var children: CFTypeRef?
                if AXUIElementCopyAttributeValue(current.element, kAXChildrenAttribute as CFString, &children) == .success,
                   let childElements = children as? [AXUIElement] {
                    for child in childElements.prefix(80) {
                        queue.append((child, current.depth + 1))
                    }
                }
            }
        }

        if let bestCandidate, bestCandidate.score >= 60 {
            logRequestButtonScan(
                candidates: candidates,
                result: "局部主按钮兜底选中",
                matched: bestCandidate.summary
            )
            return bestCandidate.element
        }

        logRequestButtonScan(
            candidates: candidates,
            result: "局部主按钮兜底未找到",
            matched: "nil"
        )
        return nil
    }

    private func clickEmbeddedSendAreaNearAccountField(near anchor: AXUIElement) -> Bool {
        let roots = searchRoots(from: anchor).prefix(6)
        let anchorFrame = frame(of: anchor)
        let anchorSnapshot = snapshot(from: anchor)
        let anchorSearchable = [
            anchorSnapshot.title,
            anchorSnapshot.description,
            anchorSnapshot.placeholder,
            anchorSnapshot.context
        ]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()

        if let anchorFrame,
           isPhoneLikeField(anchorSnapshot),
           containsPhoneRowRequestCodeSignal(anchorSearchable) {
            let clickPoint = CGPoint(
                x: anchorFrame.maxX + min(96, max(48, anchorFrame.width * 0.38)),
                y: anchorFrame.midY
            )
            logRequestButtonScan(
                candidates: [anchorSnapshot.diagnosticText.replacingOccurrences(of: "\n", with: " ")],
                result: "点击手机号框右侧发码区",
                matched: "anchor phone field"
            )
            return clickScreenPoint(clickPoint)
        }

        var visited = Set<AXUIElementHash>()
        var bestField: (element: AXUIElement, score: Int, summary: String)?
        var candidates: [String] = []

        for (rootIndex, root) in roots.enumerated() {
            var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
            var scannedForRoot = 0

            while !queue.isEmpty, scannedForRoot < 700 {
                let current = queue.removeFirst()
                scannedForRoot += 1

                let hash = AXUIElementHash(element: current.element)
                if visited.contains(hash) { continue }
                visited.insert(hash)

                let role = stringAttribute(kAXRoleAttribute, from: current.element)
                if isTextInputRole(role) {
                    let snapshot = snapshot(from: current.element)
                    let searchable = [
                        snapshot.title,
                        snapshot.description,
                        snapshot.placeholder,
                        snapshot.context
                    ]
                        .compactMap { $0 }
                        .joined(separator: " ")
                        .lowercased()

                    if searchable.contains("验证码") || searchable.contains("校验码") || searchable.contains("verification code") {
                        let score = embeddedVerificationFieldScore(
                            fieldFrame: frame(of: current.element),
                            anchorFrame: anchorFrame,
                            depth: current.depth,
                            rootIndex: rootIndex
                        )
                        let summary = snapshot.diagnosticText.replacingOccurrences(of: "\n", with: " ")
                        candidates.append("[root=\(rootIndex) depth=\(current.depth)] \(summary) score=\(score)")
                        if score > (bestField?.score ?? Int.min) {
                            bestField = (current.element, score, summary)
                        }
                    }
                }

                guard current.depth < 8 else { continue }

                var children: CFTypeRef?
                if AXUIElementCopyAttributeValue(current.element, kAXChildrenAttribute as CFString, &children) == .success,
                   let childElements = children as? [AXUIElement] {
                    for child in childElements.prefix(90) {
                        queue.append((child, current.depth + 1))
                    }
                }
            }
        }

        guard let bestField, bestField.score >= 40, let fieldFrame = frame(of: bestField.element) else {
            logRequestButtonScan(candidates: candidates, result: "验证码框右侧发码区未找到", matched: "nil")
            return false
        }

        let clickPoint = CGPoint(
            x: fieldFrame.maxX - min(70, max(36, fieldFrame.width * 0.22)),
            y: fieldFrame.midY
        )
        logRequestButtonScan(candidates: candidates, result: "点击验证码框右侧发码区", matched: bestField.summary)
        return clickScreenPoint(clickPoint)
    }

    private func isPhoneLikeField(_ snapshot: FocusedElementSnapshot) -> Bool {
        let searchable = [
            snapshot.title,
            snapshot.description,
            snapshot.placeholder,
            snapshot.context
        ]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()

        if searchable.contains("手机号") || searchable.contains("手机号码") || searchable.contains("phone") || searchable.contains("mobile") {
            return true
        }

        let digits = (snapshot.value ?? "").filter(\.isNumber)
        return digits.count >= 7
    }

    private func containsRequestCodeSignal(_ text: String) -> Bool {
        text.contains("获取验证码")
            || text.contains("发送验证码")
            || text.contains("获取校验码")
            || text.contains("发送校验码")
            || text.contains("send code")
            || text.contains("get code")
            || text.contains("send sms")
            || text.contains("verification code")
    }

    private func containsPhoneRowRequestCodeSignal(_ text: String) -> Bool {
        text.contains("获取验证码")
            || text.contains("获取校验码")
            || text.contains("get code")
            || text.contains("get sms")
    }

    func checkRequiredAgreementNearFocus(matcher: RequiredAgreementMatcher) -> String? {
        checkRequiredAgreement(near: nil, matcher: matcher)
    }

    func checkRequiredAgreement(near anchor: AXUIElement?, matcher: RequiredAgreementMatcher) -> String? {
        checkRequiredAgreement(
            in: searchRootsNearAnchor(anchor),
            matcher: matcher,
            logPrefix: "局部协议框"
        )
    }

    func checkRequiredAgreement(
        inProcessID processID: pid_t?,
        matcher: RequiredAgreementMatcher
    ) -> String? {
        guard let processID else { return nil }
        return checkRequiredAgreement(
            in: webAreaRoots(for: processID),
            matcher: matcher,
            logPrefix: "进程协议框 pid=\(processID)"
        )
    }

    private func checkRequiredAgreement(
        in roots: [AXUIElement],
        matcher: RequiredAgreementMatcher,
        logPrefix: String
    ) -> String? {
        var visited = Set<AXUIElementHash>()
        var bestCandidate: ButtonCandidate?
        var scannedTotal = 0
        var checkboxCount = 0
        var rejectedSamples: [String] = []

        for (rootIndex, root) in roots.enumerated() {
            var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
            var scannedForRoot = 0

            while !queue.isEmpty, scannedForRoot < 2_500 {
                let current = queue.removeFirst()
                scannedForRoot += 1
                scannedTotal += 1

                let hash = AXUIElementHash(element: current.element)
                if visited.contains(hash) { continue }
                visited.insert(hash)

                let role = stringAttribute(kAXRoleAttribute, from: current.element)
                let title = stringAttribute(kAXTitleAttribute, from: current.element)
                let desc = stringAttribute(kAXDescriptionAttribute, from: current.element)
                let value = stringAttribute(kAXValueAttribute, from: current.element)
                let context = agreementContext(around: current.element)

                if role == "AXCheckBox" {
                    checkboxCount += 1
                }

                if matcher.isAgreementCheckbox(
                    role: role,
                    title: title,
                    description: desc,
                    value: value,
                    context: context
                ), !isCheckboxChecked(current.element) {
                    let summary = matcher.describeCandidate(
                        role: role,
                        title: title,
                        description: desc,
                        value: value,
                        context: context
                    )
                    let candidate = ButtonCandidate(
                        element: current.element,
                        score: agreementScore(title: title, desc: desc, value: value, context: context, depth: current.depth, rootIndex: rootIndex),
                        rootIndex: rootIndex,
                        depth: current.depth,
                        summary: summary
                    )
                    if candidate.score > (bestCandidate?.score ?? Int.min) {
                        bestCandidate = candidate
                    }
                } else if role == "AXCheckBox", rejectedSamples.count < 8 {
                    let summary = matcher.describeCandidate(
                        role: role,
                        title: title,
                        description: desc,
                        value: value,
                        context: context
                    )
                    rejectedSamples.append(summary)
                }

                guard current.depth < 12 else { continue }

                var children: CFTypeRef?
                if AXUIElementCopyAttributeValue(current.element, kAXChildrenAttribute as CFString, &children) == .success,
                   let childElements = children as? [AXUIElement] {
                    for child in childElements.prefix(140) {
                        queue.append((child, current.depth + 1))
                    }
                }
            }
        }

        guard let bestCandidate else {
            appendAutomationLog(
                fileName: "agreement-checkbox.log",
                line: "\(logPrefix)未找到 roots=\(roots.count) scanned=\(scannedTotal) checkboxes=\(checkboxCount) rejected=\(rejectedSamples.joined(separator: " || "))"
            )
            return nil
        }

        let checked = checkCheckbox(bestCandidate.element)
        appendAutomationLog(
            fileName: "agreement-checkbox.log",
            line: "\(logPrefix)\(checked ? "已勾选" : "勾选失败") roots=\(roots.count) scanned=\(scannedTotal) checkboxes=\(checkboxCount): \(bestCandidate.summary)"
        )
        return checked ? bestCandidate.summary : nil
    }

    func focusVerificationFieldNearFocus(classifier: FocusedElementClassifier) -> Bool {
        guard let element = findVerificationFieldNearFocus(classifier: classifier) else {
            return false
        }
        return focusElement(element)
    }

    func findVerificationFieldNearFocus(classifier: FocusedElementClassifier) -> AXUIElement? {
        guard let focusedElement = rawFocusedElement() else { return nil }

        let start = resolveWebFocus(focusedElement)
        var visited = Set<AXUIElementHash>()

        for root in searchRoots(from: start) {
            var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
            var scannedForRoot = 0

            while !queue.isEmpty, scannedForRoot < 500 {
                let current = queue.removeFirst()
                scannedForRoot += 1

                let hash = AXUIElementHash(element: current.element)
                if visited.contains(hash) { continue }
                visited.insert(hash)

                let role = stringAttribute(kAXRoleAttribute, from: current.element)
                if isTextInputRole(role) {
                    let snapshot = snapshot(from: current.element)
                    if classifier.isStrongVerificationField(snapshot)
                        || classifier.shouldPasteInVerificationContext(snapshot) {
                        return current.element
                    }
                }

                guard current.depth < 8 else { continue }

                var children: CFTypeRef?
                if AXUIElementCopyAttributeValue(current.element, kAXChildrenAttribute as CFString, &children) == .success,
                   let childElements = children as? [AXUIElement] {
                    for child in childElements.prefix(80) {
                        queue.append((child, current.depth + 1))
                    }
                }
            }
        }

        return nil
    }

    func findVerificationFieldNearAnchor(
        _ anchor: AXUIElement?,
        classifier: FocusedElementClassifier
    ) -> AXUIElement? {
        guard anchor != nil else { return nil }
        return findVerificationField(
            in: searchRootsNearAnchor(anchor),
            classifier: classifier,
            logPrefix: "锚点重定位验证码框"
        )
    }

    func findVerificationFieldForIncomingCode(classifier: FocusedElementClassifier) -> AXUIElement? {
        findVerificationField(
            in: incomingVerificationSearchRoots(),
            classifier: classifier,
            logPrefix: "全局重定位验证码框"
        )
    }

    func findVerificationFieldForIncomingCode(
        inProcessID processID: pid_t?,
        classifier: FocusedElementClassifier
    ) -> AXUIElement? {
        guard let processID else { return nil }
        return findVerificationField(
            in: webAreaRoots(for: processID),
            classifier: classifier,
            logPrefix: "进程重定位验证码框 pid=\(processID)"
        )
    }

    private func findVerificationField(
        in roots: [AXUIElement],
        classifier: FocusedElementClassifier,
        logPrefix: String
    ) -> AXUIElement? {
        var visited = Set<AXUIElementHash>()
        var bestCandidate: ButtonCandidate?
        var scannedTotal = 0
        var textInputCount = 0
        var rejectedSamples: [String] = []

        for (rootIndex, root) in roots.enumerated() {
            var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
            var scannedForRoot = 0

            while !queue.isEmpty, scannedForRoot < 5_000 {
                let current = queue.removeFirst()
                scannedForRoot += 1
                scannedTotal += 1

                let hash = AXUIElementHash(element: current.element)
                if visited.contains(hash) { continue }
                visited.insert(hash)

                let role = stringAttribute(kAXRoleAttribute, from: current.element)
                if isTextInputRole(role) {
                    textInputCount += 1
                    let snapshot = snapshot(from: current.element)
                    if classifier.isSafeVerificationFieldForRefocus(snapshot) {
                        let candidate = ButtonCandidate(
                            element: current.element,
                            score: verificationFieldScore(snapshot: snapshot, depth: current.depth, rootIndex: rootIndex),
                            rootIndex: rootIndex,
                            depth: current.depth,
                            summary: snapshot.diagnosticText
                        )
                        if candidate.score > (bestCandidate?.score ?? Int.min) {
                            bestCandidate = candidate
                        }
                    } else if rejectedSamples.count < 8 {
                        rejectedSamples.append(snapshot.diagnosticText.replacingOccurrences(of: "\n", with: " "))
                    }
                }

                guard current.depth < 16 else { continue }

                var children: CFTypeRef?
                if AXUIElementCopyAttributeValue(current.element, kAXChildrenAttribute as CFString, &children) == .success,
                   let childElements = children as? [AXUIElement] {
                    for child in childElements.prefix(160) {
                        queue.append((child, current.depth + 1))
                    }
                }
            }
        }

        if let bestCandidate {
            appendAutomationLog(
                fileName: "verification-field-refocus.log",
                line: "\(logPrefix): roots=\(roots.count) scanned=\(scannedTotal) textInputs=\(textInputCount)\n\(bestCandidate.summary)"
            )
        } else {
            appendAutomationLog(
                fileName: "verification-field-refocus.log",
                line: "\(logPrefix): 未找到 roots=\(roots.count) scanned=\(scannedTotal) textInputs=\(textInputCount) rejected=\(rejectedSamples.joined(separator: " || "))"
            )
        }
        return bestCandidate?.element
    }

    func focusElement(_ element: AXUIElement) -> Bool {
        let error = AXUIElementSetAttributeValue(
            element,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )
        return error == .success
    }

    func verificationSnapshot(of element: AXUIElement, classifier: FocusedElementClassifier) -> FocusedElementSnapshot? {
        let snapshot = snapshot(from: element)
        guard classifier.isStrongVerificationField(snapshot)
            || classifier.shouldPasteInVerificationContext(snapshot) else {
            return nil
        }
        return snapshot
    }

    private struct ButtonCandidate {
        let element: AXUIElement
        let score: Int
        let rootIndex: Int
        let depth: Int
        let summary: String
    }

    private func candidate(
        element: AXUIElement,
        role: String,
        title: String?,
        desc: String?,
        value: String?,
        rootIndex: Int,
        depth: Int,
        matcher: LoginButtonMatcher,
        log: ButtonScanLog
    ) -> ButtonCandidate? {
        let summary = matcher.describeCandidate(role: role, title: title, description: desc, value: value)
        let isBlack = matcher.isBlacklisted(title: title, description: desc, value: value)

        if matcher.isActionableRole(role) {
            let isLogin = matcher.isLoginButton(role: role, title: title, description: desc, value: value)
            log.append("[root=\(rootIndex) depth=\(depth)] 候选 \(summary) -> isLogin=\(isLogin) isBlack=\(isBlack)")
            guard isLogin, !isBlack else { return nil }
            return ButtonCandidate(
                element: element,
                score: score(title: title, desc: desc, value: value, depth: depth, rootIndex: rootIndex, isTextFallback: false),
                rootIndex: rootIndex,
                depth: depth,
                summary: summary
            )
        }

        if isClickableTextRole(role) {
            let isLoginText = matcher.isClickableLoginText(title: title, description: desc, value: value)
            log.append("[root=\(rootIndex) depth=\(depth)] 文字候选 \(summary) -> isLoginText=\(isLoginText) isBlack=\(isBlack)")
            guard isLoginText, !isBlack else { return nil }
            return ButtonCandidate(
                element: element,
                score: score(title: title, desc: desc, value: value, depth: depth, rootIndex: rootIndex, isTextFallback: true),
                rootIndex: rootIndex,
                depth: depth,
                summary: summary
            )
        }

        return nil
    }

    private func searchRoots(from element: AXUIElement) -> [AXUIElement] {
        var roots: [AXUIElement] = []
        var current: AXUIElement? = element

        for _ in 0..<10 {
            guard let node = current else { break }
            roots.append(node)
            current = parent(of: node)
        }

        return roots
    }

    private func score(title: String?, desc: String?, value: String?, depth: Int, rootIndex: Int, isTextFallback: Bool) -> Int {
        let text = [title, desc, value]
            .compactMap { $0 }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .first { !$0.isEmpty } ?? ""

        var score = isTextFallback ? 70 : 100

        if text == "登录/注册" || text == "登录" || text == "立即登录" || text == "login" || text == "log in" {
            score += 50
        } else if text.contains("登录/注册") || text.contains("登录") || text.contains("login") {
            score += 25
        }

        if text.count > 20 {
            score -= 20
        }

        score -= depth * 3
        score -= rootIndex
        return score
    }

    private func requestCodeScore(title: String?, desc: String?, value: String?, depth: Int, rootIndex: Int, isTextFallback: Bool) -> Int {
        let text = [title, desc, value]
            .compactMap { $0 }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .first { !$0.isEmpty } ?? ""

        var score = isTextFallback ? 80 : 110
        if text == "发送验证码" || text == "获取验证码" || text == "send code" || text == "get code" {
            score += 50
        } else if text.contains("验证码") || text.contains("verification code") || text.contains("sms code") {
            score += 35
        } else if text.contains("动态码") || text.contains("校验码") || text.contains("sms") || text.contains("code") {
            score += 20
        }

        if text.count > 24 {
            score -= 15
        }

        score -= depth * 4
        score -= rootIndex * 2
        return score
    }

    private func requestCodeControlScore(
        title: String?,
        desc: String?,
        value: String?,
        elementFrame: CGRect?,
        anchorFrame: CGRect?,
        depth: Int,
        rootIndex: Int,
        isTextFallback: Bool
    ) -> Int {
        var score = requestCodeScore(
            title: title,
            desc: desc,
            value: value,
            depth: depth,
            rootIndex: rootIndex,
            isTextFallback: isTextFallback
        )

        if let elementFrame, let anchorFrame {
            let dx = abs(elementFrame.midX - anchorFrame.midX)
            let dy = elementFrame.midY - anchorFrame.midY
            if dy >= 20, dy <= 170 {
                score += 45
            }
            if dx <= 380 {
                score += 25
            }
            score -= min(60, Int((dx + abs(dy)) / 24))
        }

        return score
    }

    private func embeddedVerificationFieldScore(fieldFrame: CGRect?, anchorFrame: CGRect?, depth: Int, rootIndex: Int) -> Int {
        var score = 80
        if let fieldFrame, let anchorFrame {
            let dx = abs(fieldFrame.midX - anchorFrame.midX)
            let dy = fieldFrame.midY - anchorFrame.midY
            if dy >= 20, dy <= 170 {
                score += 45
            }
            if dx <= 260 {
                score += 20
            }
            if fieldFrame.width >= 160, fieldFrame.height >= 28 {
                score += 15
            }
            score -= min(70, Int((dx + abs(dy)) / 24))
        }
        score -= depth * 4
        score -= rootIndex * 5
        return score
    }

    private func isPrimaryRequestActionCandidate(role: String, title: String?, desc: String?, value: String?) -> Bool {
        guard role == "AXButton" || role == "AXStaticText" || role == "AXText" else {
            return false
        }

        let text = normalizedCandidateText(title: title, desc: desc, value: value)
        guard !text.isEmpty else { return false }

        let blocked = [
            "微信",
            "qq",
            "微博",
            "apple",
            "支付宝",
            "抖音",
            "飞书",
            "火山",
            "扫码",
            "二维码",
            "密码登录",
            "员工登录",
            "close",
            "关闭",
            "社区",
            "精选",
            "免费使用",
            "免费开始",
            "联系销售",
            "移动端下载"
        ]
        if blocked.contains(where: { text.contains($0.lowercased()) }) {
            return false
        }

        let allowed = [
            "登录",
            "登录/注册",
            "立即登录",
            "log in",
            "login"
        ]
        return allowed.contains { text == $0 || text.contains($0) }
    }

    private func primaryRequestActionScore(
        role: String,
        title: String?,
        desc: String?,
        value: String?,
        elementFrame: CGRect?,
        anchorFrame: CGRect?,
        depth: Int,
        rootIndex: Int
    ) -> Int {
        let text = normalizedCandidateText(title: title, desc: desc, value: value)
        var score = role == "AXButton" ? 120 : 80

        if text == "登录" || text == "登录/注册" || text == "立即登录" || text == "login" || text == "log in" {
            score += 50
        }

        if let elementFrame, let anchorFrame {
            let anchorMid = CGPoint(x: anchorFrame.midX, y: anchorFrame.midY)
            let elementMid = CGPoint(x: elementFrame.midX, y: elementFrame.midY)
            let dx = abs(elementMid.x - anchorMid.x)
            let dy = elementMid.y - anchorMid.y

            if dy >= -20, dy <= 260 {
                score += 35
            }
            if dx <= 360 {
                score += 25
            }
            if elementFrame.width >= 80, elementFrame.height >= 28 {
                score += 15
            }

            score -= min(80, Int((dx + abs(dy)) / 18))
        }

        if text.count > 12 {
            score -= 30
        }

        score -= depth * 4
        score -= rootIndex * 5
        return score
    }

    private func normalizedCandidateText(title: String?, desc: String?, value: String?) -> String {
        [title, desc, value]
            .compactMap { $0 }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .first { !$0.isEmpty } ?? ""
    }

    private func agreementScore(title: String?, desc: String?, value: String?, context: String?, depth: Int, rootIndex: Int) -> Int {
        let text = [title, desc, value, context]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()

        var score = 100
        if text.contains("同意") || text.contains("agree") {
            score += 30
        }
        if text.contains("协议") || text.contains("terms") {
            score += 20
        }
        if text.contains("隐私") || text.contains("privacy") {
            score += 20
        }

        score -= depth * 3
        score -= rootIndex * 2
        return score
    }

    private func verificationFieldScore(snapshot: FocusedElementSnapshot, depth: Int, rootIndex: Int) -> Int {
        let searchable = [
            snapshot.title,
            snapshot.description,
            snapshot.placeholder,
            snapshot.context
        ]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()

        var score = 100
        if searchable.contains("验证码") || searchable.contains("校验码") || searchable.contains("动态码") {
            score += 45
        }
        if searchable.contains("sms") || searchable.contains("code") || searchable.contains("verification") {
            score += 30
        }
        if snapshot.siblingTextInputCount >= 4 && snapshot.siblingTextInputCount <= 8 {
            score += 25
        }
        if let width = snapshot.width, width >= 24, width <= 120 {
            score += 10
        }

        score -= depth * 2
        score -= rootIndex
        return score
    }

    private func snapshot(from element: AXUIElement) -> FocusedElementSnapshot {
        FocusedElementSnapshot(
            role: stringAttribute(kAXRoleAttribute, from: element),
            title: stringAttribute(kAXTitleAttribute, from: element),
            description: stringAttribute(kAXDescriptionAttribute, from: element),
            placeholder: stringAttribute(kAXPlaceholderValueAttribute, from: element),
            value: stringAttribute(kAXValueAttribute, from: element),
            width: width(from: element),
            context: contextText(around: element),
            siblingTextInputCount: siblingTextInputCount(around: element)
        )
    }

    func pressButton(_ button: AXUIElement) -> Bool {
        let pressError = AXUIElementPerformAction(button, kAXPressAction as CFString)
        if pressError == .success {
            return true
        }

        let clickError = AXUIElementPerformAction(button, "AXClick" as CFString)
        if clickError == .success {
            return true
        }

        return simulateMouseClick(on: button)
    }

    func clickWebAction(_ element: AXUIElement) -> Bool {
        let role = stringAttribute(kAXRoleAttribute, from: element)
        if role == "AXStaticText" || role == "AXText" {
            return simulateMouseClick(on: element)
        }
        return pressButton(element)
    }

    private func simulateMouseClick(on element: AXUIElement) -> Bool {
        var positionValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              let position = positionValue,
              CFGetTypeID(position) == AXValueGetTypeID() else {
            return false
        }

        var origin = CGPoint.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin) else { return false }

        var sizeValue: CFTypeRef?
        var size = CGSize.zero
        if AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
           let sizeVal = sizeValue,
           CFGetTypeID(sizeVal) == AXValueGetTypeID() {
            _ = AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
        }

        let centerX = origin.x + size.width / 2
        let centerY = origin.y + size.height / 2

        return clickScreenPoint(CGPoint(x: centerX, y: centerY))
    }

    private func clickScreenPoint(_ point: CGPoint) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }

        let mouseDown = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
        let mouseUp = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)

        mouseDown?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.05)
        mouseUp?.post(tap: .cghidEventTap)

        return true
    }

    private struct AXUIElementHash: Hashable {
        let pointer: ObjectIdentifier

        init(element: AXUIElement) {
            self.pointer = ObjectIdentifier(element as AnyObject)
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(pointer)
        }

        static func == (lhs: AXUIElementHash, rhs: AXUIElementHash) -> Bool {
            lhs.pointer == rhs.pointer
        }
    }

    private final class ButtonScanLog {
        private var lines: [String] = []
        private let timestamp: String

        init() {
            timestamp = ISO8601DateFormatter().string(from: Date())
        }

        func append(_ line: String) {
            lines.append(line)
        }

        func flush() {
            let content = """
            === Button Scan \(timestamp) ===
            \(lines.joined(separator: "\n"))
            === End ===

            """
            let directory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/SmsCodeMenuBar", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent("login-button-scan.log")
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                if let data = content.data(using: .utf8) {
                    handle.write(data)
                }
                try? handle.close()
            } else {
                try? content.write(to: fileURL, atomically: true, encoding: .utf8)
            }
        }
    }

    private func rawFocusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        ) == .success, let focused else {
            return nil
        }

        return (focused as! AXUIElement)
    }

    private func resolveWebFocus(_ element: AXUIElement) -> AXUIElement {
        var current = element

        for _ in 0..<3 {
            let role = stringAttribute(kAXRoleAttribute, from: current) ?? ""
            guard role == "AXWebArea" || role == "AXGroup" else {
                break
            }

            var inner: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                current,
                kAXFocusedUIElementAttribute as CFString,
                &inner
            ) == .success, let inner else {
                break
            }

            let next = inner as! AXUIElement
            guard !CFEqual(next, current) else { break }
            current = next
        }

        return current
    }

    private func webAreaNear(_ element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element

        for _ in 0..<10 {
            guard let node = current else { break }
            let role = stringAttribute(kAXRoleAttribute, from: node)
            if role == "AXWebArea" {
                return node
            }
            current = parent(of: node)
        }

        return nil
    }

    private func searchRootsNearAnchor(_ anchor: AXUIElement?) -> [AXUIElement] {
        var roots: [AXUIElement] = []

        if let anchor {
            roots.append(anchor)
            if let webArea = webAreaNear(anchor) {
                roots.append(webArea)
            }
            roots.append(contentsOf: searchRoots(from: anchor))
            return uniqueElements(roots)
        }

        guard let focusedElement = rawFocusedElement() else {
            return []
        }

        let start = resolveWebFocus(focusedElement)
        roots.append(start)
        if let webArea = webAreaNear(start) {
            roots.append(webArea)
        }
        roots.append(contentsOf: searchRoots(from: start))
        return uniqueElements(roots)
    }

    private func incomingVerificationSearchRoots() -> [AXUIElement] {
        var roots: [AXUIElement] = []

        if let focusedElement = rawFocusedElement() {
            let start = resolveWebFocus(focusedElement)
            if let webArea = webAreaNear(start) {
                roots.append(webArea)
            }
            roots.append(contentsOf: searchRoots(from: start))
        }

        roots.append(contentsOf: frontmostWebAreaRoots())
        return uniqueElements(roots)
    }

    private func frontmostWebAreaRoots() -> [AXUIElement] {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return []
        }

        return webAreaRoots(for: app.processIdentifier)
    }

    private func webAreaRoots(for processID: pid_t) -> [AXUIElement] {
        guard processID != ProcessInfo.processInfo.processIdentifier else {
            return []
        }

        let appElement = AXUIElementCreateApplication(processID)
        let windows = childrenAttribute(kAXWindowsAttribute, from: appElement)
        let roots = windows.isEmpty ? childrenAttribute(kAXChildrenAttribute, from: appElement) : windows
        let webAreas = roots.flatMap { webAreaDescendants(of: $0, maxDepth: 22, maxNodes: 20_000) }

        if !webAreas.isEmpty {
            return webAreas
        }

        return roots
    }

    private func webAreaDescendants(of element: AXUIElement, maxDepth: Int, maxNodes: Int) -> [AXUIElement] {
        var output: [AXUIElement] = []
        var visitedCount = 0

        func walk(_ node: AXUIElement, depth: Int) {
            guard depth <= maxDepth, visitedCount < maxNodes else { return }
            visitedCount += 1

            if stringAttribute(kAXRoleAttribute, from: node) == "AXWebArea" {
                output.append(node)
            }

            for child in childrenAttribute(kAXChildrenAttribute, from: node).prefix(120) {
                walk(child, depth: depth + 1)
            }
        }

        walk(element, depth: 0)
        return output
    }

    private func childrenAttribute(_ attribute: String, from element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let elements = value as? [AXUIElement] else {
            return []
        }
        return elements
    }

    private func uniqueElements(_ elements: [AXUIElement]) -> [AXUIElement] {
        var seen = Set<AXUIElementHash>()
        var output: [AXUIElement] = []

        for element in elements {
            let hash = AXUIElementHash(element: element)
            guard !seen.contains(hash) else { continue }
            seen.insert(hash)
            output.append(element)
        }

        return output
    }

    private func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func width(from element: AXUIElement) -> Double? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value) == .success,
              let axValue = value,
              CFGetTypeID(axValue) == AXValueGetTypeID() else {
            return nil
        }

        var size = CGSize.zero
        guard AXValueGetValue((axValue as! AXValue), .cgSize, &size) else {
            return nil
        }
        return Double(size.width)
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              let positionRef = positionValue,
              CFGetTypeID(positionRef) == AXValueGetTypeID() else {
            return nil
        }

        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let sizeRef = sizeValue,
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else {
            return nil
        }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else {
            return nil
        }

        return CGRect(origin: origin, size: size)
    }

    private func contextText(around element: AXUIElement) -> String {
        var fragments: [String] = []
        var current: AXUIElement? = element

        for depth in 0..<6 {
            guard let node = current else { break }
            fragments.append(contentsOf: textFragments(from: node))
            fragments.append(contentsOf: deepTextDescendants(of: node, maxDepth: 2, maxNodes: 40))
            if depth < 4 {
                fragments.append(contentsOf: siblingText(around: node))
                if let parentNode = parent(of: node) {
                    fragments.append(contentsOf: deepTextDescendants(of: parentNode, maxDepth: 1, maxNodes: 30))
                }
            }
            current = parent(of: node)
        }

        return unique(fragments)
            .prefix(120)
            .joined(separator: " ")
    }

    private func agreementContext(around element: AXUIElement) -> String {
        var fragments = textFragments(from: element)
        if let parentNode = parent(of: element) {
            fragments.append(contentsOf: deepTextDescendants(of: parentNode, maxDepth: 3, maxNodes: 80))
            fragments.append(contentsOf: siblingText(around: element))
        }
        fragments.append(contextText(around: element))

        return unique(fragments)
            .prefix(160)
            .joined(separator: " ")
    }

    private func deepTextDescendants(of element: AXUIElement, maxDepth: Int, maxNodes: Int) -> [String] {
        var fragments: [String] = []
        var visited = 0

        func walk(_ node: AXUIElement, depth: Int) {
            guard depth <= maxDepth, visited < maxNodes else { return }
            visited += 1

            let role = stringAttribute(kAXRoleAttribute, from: node) ?? ""
            if role == "AXStaticText" || role == "AXTextField" || role == "AXTextArea" || role == "AXHeading" || role == "AXLabel" {
                if let value = stringAttribute(kAXValueAttribute, from: node), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    fragments.append(value)
                }
                if let title = stringAttribute(kAXTitleAttribute, from: node), !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    fragments.append(title)
                }
            }

            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &children) == .success,
               let childElements = children as? [AXUIElement] {
                for child in childElements.prefix(15) {
                    walk(child, depth: depth + 1)
                }
            }
        }

        walk(element, depth: 0)
        return fragments
    }

    private func textFragments(from element: AXUIElement) -> [String] {
        var fragments = [
            stringAttribute(kAXRoleAttribute, from: element),
            stringAttribute(kAXTitleAttribute, from: element),
            stringAttribute(kAXDescriptionAttribute, from: element),
            stringAttribute(kAXPlaceholderValueAttribute, from: element),
            stringAttribute(kAXValueAttribute, from: element)
        ]
            .compactMap { $0 }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        var children: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
           let childElements = children as? [AXUIElement] {
            for child in childElements.prefix(20) {
                fragments.append(contentsOf: [
                    stringAttribute(kAXTitleAttribute, from: child),
                    stringAttribute(kAXDescriptionAttribute, from: child),
                    stringAttribute(kAXValueAttribute, from: child)
                ].compactMap { $0 })
            }
        }

        return fragments
    }

    private func siblingText(around element: AXUIElement) -> [String] {
        guard let parent = parent(of: element) else { return [] }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, kAXChildrenAttribute as CFString, &children) == .success,
              let siblings = children as? [AXUIElement],
              let index = siblings.firstIndex(where: { CFEqual($0, element) }) else {
            return []
        }

        let lowerBound = max(0, index - 3)
        let upperBound = min(siblings.count, index + 4)

        return siblings[lowerBound..<upperBound]
            .filter { !CFEqual($0, element) }
            .flatMap { sibling in
                [
                    stringAttribute(kAXTitleAttribute, from: sibling),
                    stringAttribute(kAXDescriptionAttribute, from: sibling),
                    stringAttribute(kAXValueAttribute, from: sibling)
                ].compactMap { $0 }
            }
    }

    private func siblingTextInputCount(around element: AXUIElement) -> Int {
        guard let parent = parent(of: element) else { return 0 }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, kAXChildrenAttribute as CFString, &children) == .success,
              let siblings = children as? [AXUIElement] else {
            return 0
        }

        return siblings.filter { sibling in
            isTextInputRole(stringAttribute(kAXRoleAttribute, from: sibling))
        }.count
    }

    private func isCheckboxChecked(_ element: AXUIElement) -> Bool {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &rawValue) == .success,
              let rawValue else {
            return false
        }

        if let number = rawValue as? NSNumber {
            return number.boolValue
        }

        if let value = rawValue as? String {
            let normalized = value.lowercased()
            return normalized == "1" || normalized == "true" || normalized == "yes" || normalized == "on" || normalized == "checked"
        }

        return false
    }

    private func checkCheckbox(_ element: AXUIElement) -> Bool {
        if isCheckboxChecked(element) {
            return true
        }

        _ = pressButton(element)
        if isCheckboxChecked(element) {
            return true
        }

        if let frame = frame(of: element) {
            _ = clickScreenPoint(CGPoint(x: frame.midX, y: frame.midY))
            if isCheckboxChecked(element) {
                return true
            }
        }

        let setError = AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            NSNumber(value: 1)
        )
        return setError == .success && isCheckboxChecked(element)
    }

    private func parent(of element: AXUIElement) -> AXUIElement? {
        var parent: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success else {
            return nil
        }
        return parent.map { $0 as! AXUIElement }
    }

    private func unique(_ fragments: [String]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []

        for fragment in fragments {
            let trimmed = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            output.append(trimmed)
        }

        return output
    }

    private func isTextInputRole(_ role: String?) -> Bool {
        guard let role else { return false }
        return role == "AXTextField"
            || role == "AXTextArea"
            || role == "AXComboBox"
            || role == "AXSearchField"
    }

    private func isClickableTextRole(_ role: String?) -> Bool {
        guard let role else { return false }
        return role == "AXStaticText"
            || role == "AXText"
    }

    private func appendAutomationLog(fileName: String, line: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let content = "[\(timestamp)] \(line)\n"
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/SmsCodeMenuBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent(fileName)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            if let data = content.data(using: .utf8) {
                handle.write(data)
            }
            try? handle.close()
        } else {
            try? content.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }
}

final class KeyboardTyper {
    func type(_ text: String) throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw RuntimeError("无法创建键盘事件源")
        }

        for character in text {
            guard let key = KeyStroke(character: character) else {
                throw RuntimeError("无法输入字符：\(character)")
            }
            post(source: source, keyCode: key.keyCode, isDown: true, flags: key.needsShift ? .maskShift : [])
            post(source: source, keyCode: key.keyCode, isDown: false, flags: key.needsShift ? .maskShift : [])
        }
    }

    private func post(source: CGEventSource, keyCode: CGKeyCode, isDown: Bool, flags: CGEventFlags = []) {
        let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: isDown)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }

    func paste() {
        guard AXIsProcessTrusted(),
              let source = CGEventSource(stateID: .hidSystemState) else {
            return
        }

        let commandKeyCode = CGKeyCode(55)
        let vKeyCode = CGKeyCode(9)

        post(source: source, keyCode: commandKeyCode, isDown: true)
        Thread.sleep(forTimeInterval: 0.02)
        post(source: source, keyCode: vKeyCode, isDown: true, flags: .maskCommand)
        Thread.sleep(forTimeInterval: 0.04)
        post(source: source, keyCode: vKeyCode, isDown: false, flags: .maskCommand)
        Thread.sleep(forTimeInterval: 0.02)
        post(source: source, keyCode: commandKeyCode, isDown: false)
    }
}

private struct KeyStroke {
    let keyCode: CGKeyCode
    let needsShift: Bool

    init?(character: Character) {
        let lower = String(character).lowercased()
        if let keyCode = Self.keyCodes[lower] {
            self.keyCode = keyCode
            self.needsShift = String(character) != lower
            return
        }
        return nil
    }

    private static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
        "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32,
        "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46
    ]
}

final class SystemPasteboardStore: ClipboardStoring {
    func write(_ text: String) {
        NSPasteboard.general.setString(text, forType: .string)
    }

    func read() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    func clear() {
        NSPasteboard.general.clearContents()
    }
}

final class ClipboardManager {
    private let controller = TemporaryClipboardController(store: SystemPasteboardStore())

    @discardableResult
    func copyTemporary(_ text: String) -> Bool {
        controller.copyTemporary(text)
    }

    func currentText() -> String? {
        controller.currentText()
    }
}

final class NotificationService {
    func showClipboardFallback() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            #"display notification "当前输入框不够确定，请按 Cmd+V 粘贴。" with title "验证码已复制""#
        ]
        try? process.run()
    }

    func showEmailClipboardFallback() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            #"display notification "邮箱验证码已复制；当前焦点或页面未通过严格填码检查，请按 Cmd+V。" with title "验证码已复制""#
        ]
        try? process.run()
    }
}

final class LaunchAtLoginManager {
    private let label = "local.sms-code-menubar"

    var isEnabled: Bool {
        installedProgramArguments() == expectedProgramArguments()
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try install()
        } else {
            try uninstall()
        }
    }

    private func install() throws {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": expectedProgramArguments(),
            "RunAtLoad": true,
            "KeepAlive": false
        ]

        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: plistURL, options: .atomic)
    }

    private func uninstall() throws {
        guard FileManager.default.fileExists(atPath: plistURL.path) else { return }
        try FileManager.default.removeItem(at: plistURL)
    }

    private func expectedProgramArguments() -> [String] {
        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension == "app" {
            return ["/usr/bin/open", "-n", bundleURL.path]
        }

        return [Bundle.main.executablePath ?? CommandLine.arguments[0]]
    }

    private func installedProgramArguments() -> [String]? {
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ),
              let dictionary = plist as? [String: Any] else {
            return nil
        }
        return dictionary["ProgramArguments"] as? [String]
    }

    private var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
}

enum SystemSettingsOpener {
    static func openFullDiskAccess() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct RuntimeError: Error, LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}
