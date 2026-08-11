import CoreFoundation
import Foundation
import Testing
@testable import SmsCodeCore

struct EmailMIMEParserTests {
    private let parser = EmailMIMEParser()

    @Test func parsesUTF8PlainTextAndEncodedSubject() throws {
        let subject = Data("登录验证码".utf8).base64EncodedString()
        let raw = """
        Subject: =?UTF-8?B?\(subject)?=\r
        Content-Type: text/plain; charset=UTF-8\r
        Content-Transfer-Encoding: quoted-printable\r
        \r
        =E6=82=A8=E7=9A=84=E9=AA=8C=E8=AF=81=E7=A0=81=E6=98=AF 654321
        """

        let result = try parser.parse(Data(raw.utf8))
        #expect(result.subject == "登录验证码")
        #expect(result.body.contains("验证码是 654321"))
    }

    @Test func parsesMultipartBase64HTMLAndPlainText() throws {
        let html = Data("<html><body>Verification code: <b>A7B9C2</b></body></html>".utf8).base64EncodedString()
        let raw = """
        Subject: Login code\r
        Content-Type: multipart/alternative; boundary="otp-boundary"\r
        \r
        --otp-boundary\r
        Content-Type: text/plain; charset=UTF-8\r
        \r
        Your login code is A7B9C2.\r
        --otp-boundary\r
        Content-Type: text/html; charset=UTF-8\r
        Content-Transfer-Encoding: base64\r
        \r
        \(html)\r
        --otp-boundary--\r
        """

        let result = try parser.parse(Data(raw.utf8))
        #expect(result.body.contains("Your login code is A7B9C2"))
        #expect(result.body.contains("Verification code: A7B9C2"))
        #expect(!result.body.contains("<b>"))
    }

    @Test func decodesGB2312GBKAndGB18030Aliases() throws {
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding("GB18030" as CFString)
        let encoding = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding)
        )
        let body = try #require("您的验证码是 482910".data(using: encoding))

        for charset in ["GB2312", "GBK", "GB18030"] {
            var raw = Data("Subject: OTP\r\nContent-Type: text/plain; charset=\(charset)\r\n\r\n".utf8)
            raw.append(body)
            let result = try parser.parse(raw)
            #expect(result.body.contains("验证码是 482910"))
        }
    }

    @Test func ignoresHiddenHTMLScriptStyleAndAttachmentContent() throws {
        let html = """
        <html><head><style>.x{display:none}</style><script>var code='111111'</script></head>
        <body>
        <div hidden>验证码 222222</div>
        <p style="display:none">验证码 333333</p>
        <p aria-hidden="true">验证码 444444</p>
        <p>Use 555555 to sign in</p>
        </body></html>
        """
        let attachment = Data("附件里的验证码 999999 不应参与识别".utf8).base64EncodedString()
        let raw = """
        Subject: Login\r
        Content-Type: multipart/mixed; boundary="mixed-boundary"\r
        \r
        --mixed-boundary\r
        Content-Type: text/html; charset=UTF-8\r
        \r
        \(html)\r
        --mixed-boundary\r
        Content-Type: application/pdf; name="otp.pdf"\r
        Content-Transfer-Encoding: base64\r
        \r
        \(attachment)\r
        --mixed-boundary--\r
        """

        let result = try parser.parse(Data(raw.utf8))
        #expect(result.body.contains("Use 555555 to sign in"))
        #expect(!result.body.contains("111111"))
        #expect(!result.body.contains("222222"))
        #expect(!result.body.contains("333333"))
        #expect(!result.body.contains("444444"))
        #expect(!result.body.contains("999999"))
    }

    @Test func limitsHugeDecodedBodyBeforeRecognition() throws {
        let huge = String(repeating: "普通内容", count: 20_000) + "验证码 888888"
        let raw = """
        Subject: Login\r
        Content-Type: text/plain; charset=UTF-8\r
        \r
        \(huge)
        """

        let result = try parser.parse(Data(raw.utf8))
        #expect(result.body.count == 24_000)
        #expect(!result.body.contains("888888"))
    }
}
