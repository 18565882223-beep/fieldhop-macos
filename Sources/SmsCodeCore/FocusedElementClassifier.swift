import Foundation

public struct FocusedElementSnapshot: Equatable {
    public let role: String?
    public let title: String?
    public let description: String?
    public let placeholder: String?
    public let value: String?
    public let width: Double?
    public let context: String?
    public let siblingTextInputCount: Int

    public init(
        role: String? = nil,
        title: String? = nil,
        description: String? = nil,
        placeholder: String? = nil,
        value: String? = nil,
        width: Double? = nil,
        context: String? = nil,
        siblingTextInputCount: Int = 0
    ) {
        self.role = role
        self.title = title
        self.description = description
        self.placeholder = placeholder
        self.value = value
        self.width = width
        self.context = context
        self.siblingTextInputCount = siblingTextInputCount
    }

    public var diagnosticText: String {
        [
            "role=\(role ?? "nil")",
            "title=\(title ?? "nil")",
            "description=\(description ?? "nil")",
            "placeholder=\(placeholder ?? "nil")",
            "valueLength=\(value?.count.description ?? "nil")",
            "width=\(width.map { String(Int($0)) } ?? "nil")",
            "siblingTextInputCount=\(siblingTextInputCount)",
            "context=\(context ?? "nil")"
        ].joined(separator: "\n")
    }
}

public struct FocusedElementClassifier {
    private let keywords: [String]

    public init(keywords: [String] = VerificationCodeExtractor.defaultKeywords) {
        self.keywords = keywords
    }

    public func isStrongVerificationField(_ snapshot: FocusedElementSnapshot) -> Bool {
        let searchable = searchableText(from: snapshot)
        let hasVerificationKeyword = hasVerificationKeyword(in: searchable)

        if isTextInput(snapshot.role), hasVerificationKeyword {
            return true
        }

        if isOtpLikeFocusedContainer(snapshot, hasVerificationKeyword: hasVerificationKeyword) {
            return true
        }

        if isLikelySegmentedOtpInput(snapshot) {
            return true
        }

        let trimmedValue = snapshot.value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard isTextInput(snapshot.role), trimmedValue.isEmpty else {
            return false
        }

        if let width = snapshot.width, width >= 48, width <= 180 {
            return true
        }

        if isMediumEmptyTextFieldInNonSearchContext(snapshot, searchable: searchable) {
            return true
        }

        return false
    }

    public func shouldPasteInVerificationContext(_ snapshot: FocusedElementSnapshot) -> Bool {
        let searchable = [
            snapshot.title,
            snapshot.description,
            snapshot.placeholder,
            snapshot.context
        ]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()

        guard hasVerificationKeyword(in: searchable) else { return false }
        guard !isInteractiveCommand(snapshot.role) else { return false }
        guard !isKnownNonVerificationTextTarget(snapshot, searchable: searchable) else { return false }

        if isTextInput(snapshot.role) {
            return true
        }

        return isAmbiguousBrowserContainer(snapshot.role)
    }

    public func shouldPasteAggressively(_ snapshot: FocusedElementSnapshot) -> Bool {
        if isInteractiveCommand(snapshot.role) {
            return false
        }
        return isTextInput(snapshot.role)
    }

    public func isSafeVerificationFieldForRefocus(_ snapshot: FocusedElementSnapshot) -> Bool {
        guard isTextInput(snapshot.role) else { return false }

        let searchable = searchableText(from: snapshot)
        if isKnownNonVerificationTextTarget(snapshot, searchable: searchable) {
            return false
        }

        if isLikelyPhoneField(snapshot) {
            return false
        }

        let trimmedValue = snapshot.value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmedValue.isEmpty || trimmedValue.count <= 1 else { return false }

        if hasVerificationKeyword(in: searchable) {
            return true
        }

        if isLikelySegmentedOtpInput(snapshot) {
            return true
        }

        if isMediumEmptyTextFieldInNonSearchContext(snapshot, searchable: searchable) {
            return true
        }

        return shouldPasteAggressively(snapshot)
    }

    public func isLikelyPhoneField(_ snapshot: FocusedElementSnapshot) -> Bool {
        guard isTextInput(snapshot.role) else { return false }

        let searchable = searchableText(from: snapshot)
        if isAddressBarOrSearchContext(snapshot, searchable: searchable) {
            return false
        }

        let phoneHints = [
            "手机号",
            "手机号码",
            "手机",
            "电话",
            "phone",
            "mobile",
            "tel"
        ]
        if phoneHints.contains(where: { searchable.contains($0) }) {
            return true
        }

        let trimmedValue = snapshot.value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let digits = trimmedValue.filter(\.isNumber)
        return digits.count >= 7 && digits.count <= 15
    }

    public func isAcceptableAccountField(_ snapshot: FocusedElementSnapshot) -> Bool {
        guard isTextInput(snapshot.role) else { return false }
        guard snapshot.role != "AXTextArea", snapshot.role != "AXSearchField" else { return false }

        let searchable = searchableText(from: snapshot)
        if isAddressBarOrSearchContext(snapshot, searchable: searchable) {
            return false
        }

        let blockedHints = [
            "正文",
            "评论",
            "comment",
            "message",
            "search",
            "搜索"
        ]
        if blockedHints.contains(where: { searchable.contains($0) }) {
            return false
        }

        if let width = snapshot.width, width >= 620 {
            return false
        }

        return true
    }

    private func isOtpLikeFocusedContainer(
        _ snapshot: FocusedElementSnapshot,
        hasVerificationKeyword: Bool
    ) -> Bool {
        guard hasVerificationKeyword else { return false }

        if isInteractiveCommand(snapshot.role) {
            return false
        }

        guard isFocusedContainer(snapshot.role) else {
            return false
        }

        let trimmedValue = snapshot.value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmedValue.count > 1 {
            return false
        }

        return true
    }

    private func searchableText(from snapshot: FocusedElementSnapshot) -> String {
        [
            snapshot.title,
            snapshot.description,
            snapshot.placeholder,
            snapshot.context
        ]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
    }

    private func hasVerificationKeyword(in searchable: String) -> Bool {
        keywords.contains { searchable.contains($0.lowercased()) }
    }

    private func isLikelySegmentedOtpInput(_ snapshot: FocusedElementSnapshot) -> Bool {
        guard isTextInput(snapshot.role) else { return false }
        guard snapshot.siblingTextInputCount >= 4, snapshot.siblingTextInputCount <= 8 else { return false }

        let trimmedValue = snapshot.value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmedValue.count <= 1 else { return false }

        if let width = snapshot.width {
            return width >= 24 && width <= 90
        }

        return true
    }

    private func isMediumEmptyTextFieldInNonSearchContext(
        _ snapshot: FocusedElementSnapshot,
        searchable: String
    ) -> Bool {
        guard snapshot.role == "AXTextField" else { return false }

        let trimmedValue = snapshot.value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmedValue.isEmpty else { return false }

        guard let width = snapshot.width, width >= 180, width <= 520 else { return false }

        if isAddressBarOrSearchContext(snapshot, searchable: searchable) {
            return false
        }

        return true
    }

    private func isAddressBarOrSearchContext(
        _ snapshot: FocusedElementSnapshot,
        searchable: String
    ) -> Bool {
        if snapshot.role == "AXSearchField" {
            return true
        }

        let addressBarHints = [
            "address and search",
            "address bar",
            "地址栏",
            "地址栏",
            "url",
            "网址"
        ]
        if addressBarHints.contains(where: { searchable.contains($0) }) {
            return true
        }

        let searchHints = [
            "搜索",
            "search",
            "查找",
            "find"
        ]
        if searchHints.contains(where: { searchable.contains($0) }) {
            return true
        }

        if let width = snapshot.width, width >= 600 {
            return true
        }

        return false
    }

    private func isTextInput(_ role: String?) -> Bool {
        guard let role else { return false }
        return role == "AXTextField"
            || role == "AXTextArea"
            || role == "AXComboBox"
            || role == "AXSearchField"
    }

    private func isInteractiveCommand(_ role: String?) -> Bool {
        guard let role else { return false }
        return role == "AXButton"
            || role == "AXLink"
            || role == "AXMenuItem"
            || role == "AXCheckBox"
            || role == "AXRadioButton"
    }

    private func isFocusedContainer(_ role: String?) -> Bool {
        guard let role else { return false }
        return role == "AXGroup"
            || role == "AXWebArea"
    }

    private func isAmbiguousBrowserContainer(_ role: String?) -> Bool {
        guard let role else { return false }
        return role == "AXGroup"
            || role == "AXWebArea"
            || role == "AXWindow"
    }

    private func isKnownNonVerificationTextTarget(_ snapshot: FocusedElementSnapshot, searchable: String) -> Bool {
        guard isTextInput(snapshot.role) else { return false }

        if snapshot.role == "AXTextArea" {
            return true
        }

        let directText = [
            snapshot.title,
            snapshot.description,
            snapshot.placeholder
        ]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()

        let directAccountHints = [
            "手机号",
            "手机号码",
            "电话",
            "phone",
            "mobile",
            "tel",
            "账号",
            "账户",
            "account"
        ]
        if directAccountHints.contains(where: { directText.contains($0) }) {
            return true
        }

        let blockedHints = [
            "address and search",
            "address bar",
            "search",
            "搜索",
            "正文",
            "message",
            "comment",
            "评论"
        ]

        if blockedHints.contains(where: { searchable.contains($0) }) {
            return true
        }

        if let width = snapshot.width, width >= 360 {
            return true
        }

        return false
    }
}
