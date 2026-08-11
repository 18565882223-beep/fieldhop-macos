import Testing
@testable import SmsCodeCore

struct VerificationCodeExtractorTests {
    @Test func extracts20RealisticSamples() {
        let extractor = VerificationCodeExtractor()

        let samples = [
            ("【豆包】验证码430605，5分钟内有效。", "430605"),
            ("【Kimi】您的登录验证码是 1208，请勿泄露。", "1208"),
            ("Your login code is A7B9C2. Do not share it.", "A7B9C2"),
            ("OpenAI verification code: 847291", "847291"),
            ("GitHub two-factor code: 918273", "918273"),
            ("Microsoft account security code: 482910", "482910"),
            ("Apple ID code: 773421. Do not share.", "773421"),
            ("【支付宝】校验码 638204，您正在登录。", "638204"),
            ("【微信】动态码：907531，用于安全验证。", "907531"),
            ("【小红书】982341为验证码，请勿告诉他人。", "982341"),
            ("【淘宝】验证码为 6519，10分钟内有效。", "6519"),
            ("【京东】短信码 726451，5分钟内有效。", "726451"),
            ("【银行】安全码：F7K2Q9，本次操作金额100.00元。", "F7K2Q9"),
            ("Your OTP is 584920, expires in 3 minutes.", "584920"),
            ("Passcode: 9H4K2M. Login attempt from Mac.", "9H4K2M"),
            ("【服务】确认码 A1B2C3，请在页面输入。", "A1B2C3"),
            ("订单123456已创建，本次验证码为654321，10分钟内有效。", "654321"),
            ("登录 code 7391 有效期 5 分钟。", "7391"),
            ("【平台】验证码0007，请勿泄露。", "0007"),
            ("【平台】验证码 888888，有效期2分钟，流水号20260704。", "888888"),
            ("Use code ZX90P1 to continue signing in.", "ZX90P1"),
            ("【服务】本次校验码为 314159，设备尾号 2026。", "314159")
        ]

        #expect(samples.count >= 20)
        for (message, expected) in samples {
            #expect(extractor.extract(from: message) == expected)
        }
    }

    @Test func extractsMixedCode() {
        let extractor = VerificationCodeExtractor()
        #expect(extractor.extract(from: "Your login code is A7B9C2. Do not share it.") == "A7B9C2")
    }

    @Test func prefersCodeClosestToKeyword() {
        let extractor = VerificationCodeExtractor()
        #expect(extractor.extract(from: "订单123456已创建，本次验证码为654321，10分钟内有效。") == "654321")
    }

    @Test func ignoresPureLetters() {
        let extractor = VerificationCodeExtractor()
        #expect(extractor.extract(from: "Your code is ABCDEF.") == nil)
    }
}
