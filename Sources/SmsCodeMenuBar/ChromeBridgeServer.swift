import Foundation
import Network

struct ChromeBridgeResult: Codable, Equatable {
    let sessionID: String
    let commandType: String?
    let status: String
    let message: String
    let filledPhone: Bool?
    let checkedAgreement: Bool?
    let clickedNextStep: Bool?
    let clickedRequest: Bool?
    let focusedVerification: Bool?
    let manualInterventionRequired: Bool?
    let filledCode: Bool?
    let clickedLogin: Bool?
}

final class ChromeBridgeServer {
    private enum CommandType {
        static let phoneLogin = "phoneLogin"
        static let emailLogin = "emailLogin"
        static let fillCode = "fillCode"
        static let reloadExtension = "reloadExtension"
    }

    private struct DebugEnqueueRequest: Codable {
        let phoneNumber: String
        let accountName: String?
        let targetHost: String?
    }

    private struct DebugFillCodeRequest: Codable {
        let code: String
        let targetHost: String?
        let autoSubmit: Bool?
    }

    private struct BridgeCommand: Codable {
        let type: String
        let sessionID: String
        let phoneNumber: String?
        let verificationCode: String?
        let accountName: String?
        let targetHost: String?
        let createdAt: TimeInterval
        let autoSubmit: Bool?
        let requiresVisibleTab: Bool?
    }

    private struct CommandResponse: Codable {
        let command: BridgeCommand?
    }

    private let queue = DispatchQueue(label: "local.sms-code-menubar.chrome-bridge")
    private let stateQueue = DispatchQueue(label: "local.sms-code-menubar.chrome-bridge.state")
    private let port: NWEndpoint.Port = 47873
    private let isDebugEndpointEnabled: Bool
    private var listener: NWListener?
    private var pendingCommands: [BridgeCommand] = []
    private var deliveredSessionIDs = Set<String>()
    private var results: [String: ChromeBridgeResult] = [:]

    var endpointDescription: String {
        "127.0.0.1:\(port.rawValue)"
    }

    init(isDebugEndpointEnabled: Bool = false) {
        self.isDebugEndpointEnabled = isDebugEndpointEnabled
    }

    func start() throws {
        guard listener == nil else { return }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: port)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func enqueuePhoneLogin(
        phoneNumber: String,
        accountName: String,
        targetHost: String?
    ) -> String {
        let sessionID = UUID().uuidString
        let command = BridgeCommand(
            type: CommandType.phoneLogin,
            sessionID: sessionID,
            phoneNumber: phoneNumber,
            verificationCode: nil,
            accountName: accountName,
            targetHost: targetHost,
            createdAt: Date().timeIntervalSince1970,
            autoSubmit: nil,
            requiresVisibleTab: targetHost == nil
        )

        enqueue(command)
        return sessionID
    }

    func enqueueEmailLogin(email: String, accountName: String, targetHost: String?) -> String {
        let sessionID = UUID().uuidString
        enqueue(BridgeCommand(
            type: CommandType.emailLogin,
            sessionID: sessionID,
            phoneNumber: email,
            verificationCode: nil,
            accountName: accountName,
            targetHost: targetHost,
            createdAt: Date().timeIntervalSince1970,
            autoSubmit: nil,
            requiresVisibleTab: targetHost == nil
        ))
        return sessionID
    }

    func enqueueVerificationCode(
        code: String,
        targetHost: String?,
        autoSubmit: Bool
    ) -> String {
        let sessionID = UUID().uuidString
        let command = BridgeCommand(
            type: CommandType.fillCode,
            sessionID: sessionID,
            phoneNumber: nil,
            verificationCode: code,
            accountName: nil,
            targetHost: targetHost,
            createdAt: Date().timeIntervalSince1970,
            autoSubmit: autoSubmit,
            requiresVisibleTab: targetHost == nil
        )

        enqueue(command)
        return sessionID
    }

    func enqueueExtensionReload() -> String {
        let sessionID = UUID().uuidString
        let command = BridgeCommand(
            type: CommandType.reloadExtension,
            sessionID: sessionID,
            phoneNumber: nil,
            verificationCode: nil,
            accountName: nil,
            targetHost: nil,
            createdAt: Date().timeIntervalSince1970,
            autoSubmit: nil,
            requiresVisibleTab: false
        )

        enqueue(command)
        return sessionID
    }

    private func enqueue(_ command: BridgeCommand) {
        stateQueue.sync {
            cleanupExpiredCommands(now: Date().timeIntervalSince1970)
            pendingCommands.append(command)
            deliveredSessionIDs.remove(command.sessionID)
            results.removeValue(forKey: command.sessionID)
        }
    }

    func result(sessionID: String) -> ChromeBridgeResult? {
        stateQueue.sync {
            results[sessionID]
        }
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            guard let self else {
                connection.cancel()
                return
            }

            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let response = self.response(for: request)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func response(for request: String) -> Data {
        let lines = request.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return jsonResponse(["ok": false, "error": "bad request"], status: "400 Bad Request")
        }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            return jsonResponse(["ok": false, "error": "bad request"], status: "400 Bad Request")
        }

        let method = String(parts[0])
        let path = String(parts[1])

        if method == "OPTIONS" {
            return emptyResponse(status: "204 No Content")
        }

        if method == "GET", path.hasPrefix("/ping") {
            return jsonResponse(["ok": true, "service": "SmsCodeMenuBar Chrome Bridge"])
        }

        if method == "GET", path.hasPrefix("/command") {
            let host = queryValue(named: "host", in: path)
            let visible = queryValue(named: "visible", in: path).map { $0 == "1" || $0 == "true" } ?? false
            return commandResponse(forHost: host, isVisibleTab: visible)
        }

        if method == "POST", path.hasPrefix("/result") {
            let body = request.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
            return storeResult(body: body)
        }

        if method == "POST", path.hasPrefix("/debug/enqueue"), isDebugEndpointEnabled {
            let body = request.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
            return debugEnqueue(body: body)
        }

        if method == "POST", path.hasPrefix("/debug/fill-code"), isDebugEndpointEnabled {
            let body = request.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
            return debugFillCode(body: body)
        }

        if method == "POST", path.hasPrefix("/debug/reload-extension"), isDebugEndpointEnabled {
            return debugReloadExtension()
        }

        return jsonResponse(["ok": false, "error": "not found"], status: "404 Not Found")
    }

    private func debugEnqueue(body: String) -> Data {
        guard let data = body.data(using: .utf8),
              let request = try? JSONDecoder().decode(DebugEnqueueRequest.self, from: data) else {
            return jsonResponse(["ok": false, "error": "invalid debug request"], status: "400 Bad Request")
        }

        let sessionID = enqueuePhoneLogin(
            phoneNumber: request.phoneNumber,
            accountName: request.accountName ?? "调试账号",
            targetHost: request.targetHost
        )
        return jsonResponse(["ok": true, "sessionID": sessionID])
    }

    private func debugFillCode(body: String) -> Data {
        guard let data = body.data(using: .utf8),
              let request = try? JSONDecoder().decode(DebugFillCodeRequest.self, from: data) else {
            return jsonResponse(["ok": false, "error": "invalid debug fill request"], status: "400 Bad Request")
        }

        let sessionID = enqueueVerificationCode(
            code: request.code,
            targetHost: request.targetHost,
            autoSubmit: request.autoSubmit ?? false
        )
        return jsonResponse(["ok": true, "sessionID": sessionID])
    }

    private func debugReloadExtension() -> Data {
        let sessionID = enqueueExtensionReload()
        return jsonResponse(["ok": true, "sessionID": sessionID])
    }

    private func commandResponse(forHost host: String?, isVisibleTab: Bool) -> Data {
        let command = stateQueue.sync {
            cleanupExpiredCommands(now: Date().timeIntervalSince1970)
            guard let command = pendingCommands.first(where: { command in
                !deliveredSessionIDs.contains(command.sessionID)
                    && (!(command.requiresVisibleTab ?? false) || isVisibleTab)
                    && hostMatches(currentHost: host, targetHost: command.targetHost)
            }) else {
                return Optional<BridgeCommand>.none
            }

            deliveredSessionIDs.insert(command.sessionID)
            return command
        }

        do {
            let data = try JSONEncoder().encode(CommandResponse(command: command))
            return httpResponse(body: data)
        } catch {
            return jsonResponse(["ok": false, "error": "encode failed"], status: "500 Internal Server Error")
        }
    }

    private func storeResult(body: String) -> Data {
        guard let data = body.data(using: .utf8),
              let result = try? JSONDecoder().decode(ChromeBridgeResult.self, from: data) else {
            return jsonResponse(["ok": false, "error": "invalid result"], status: "400 Bad Request")
        }

        stateQueue.sync {
            results[result.sessionID] = result
            pendingCommands.removeAll { $0.sessionID == result.sessionID }
        }

        return jsonResponse(["ok": true])
    }

    private func cleanupExpiredCommands(now: TimeInterval) {
        pendingCommands.removeAll { command in
            now - command.createdAt > commandLifetime(command)
        }
    }

    private func commandLifetime(_ command: BridgeCommand) -> TimeInterval {
        switch command.type {
        case CommandType.phoneLogin, CommandType.emailLogin:
            return 15
        case CommandType.fillCode:
            return 30
        case CommandType.reloadExtension:
            return 30
        default:
            return 15
        }
    }

    private func hostMatches(currentHost: String?, targetHost: String?) -> Bool {
        guard let target = normalizedHost(targetHost) else { return true }
        guard let current = normalizedHost(currentHost) else { return false }
        return current == target || current.hasSuffix(".\(target)") || target.hasSuffix(".\(current)")
    }

    private func normalizedHost(_ host: String?) -> String? {
        guard let raw = host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else {
            return nil
        }

        let withoutPort = raw.split(separator: ":").first.map(String.init) ?? raw
        return withoutPort.hasPrefix("www.") ? String(withoutPort.dropFirst(4)) : withoutPort
    }

    private func queryValue(named name: String, in path: String) -> String? {
        guard let components = URLComponents(string: "http://localhost\(path)") else { return nil }
        return components.queryItems?.first { $0.name == name }?.value
    }

    private func jsonResponse(_ object: [String: Any], status: String = "200 OK") -> Data {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return httpResponse(body: data, status: status)
    }

    private func emptyResponse(status: String) -> Data {
        httpResponse(body: Data(), status: status)
    }

    private func httpResponse(body: Data, status: String = "200 OK") -> Data {
        let headers = [
            "HTTP/1.1 \(status)",
            "Content-Type: application/json; charset=utf-8",
            "Content-Length: \(body.count)",
            "Access-Control-Allow-Origin: *",
            "Access-Control-Allow-Methods: GET, POST, OPTIONS",
            "Access-Control-Allow-Headers: Content-Type",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")

        var response = Data(headers.utf8)
        response.append(body)
        return response
    }
}
