import Foundation

public struct SMSMessage: Equatable {
    public let text: String
    public let date: Date
    public let service: String?

    public init(text: String, date: Date, service: String? = nil) {
        self.text = text
        self.date = date
        self.service = service
    }
}

public struct DetectedVerificationCode: Equatable {
    public let code: String
    public let message: SMSMessage

    public init(code: String, message: SMSMessage) {
        self.code = code
        self.message = message
    }
}
