import XCTest

final class ScreenshotTests: XCTestCase {
    private struct ScreenshotConfiguration: Decodable {
        let locale: String
        let device: String
        let output_dir: String
        let currency: String
        let target_screen: String
    }

    private struct Screen {
        let name: String
        let title: String
        let launchArguments: [String]
    }

    private let screens = [
        Screen(name: "01_dashboard", title: "EscapeMint", launchArguments: []),
        Screen(name: "02_backtest", title: "Backtest", launchArguments: ["-startTab", "1"]),
        Screen(name: "03_fund_detail", title: "BTC (coinbasetest)", launchArguments: ["-selectFund", "coinbasetest-btc"]),
        Screen(name: "04_audit", title: "Audit Trail", launchArguments: ["-startTab", "2"]),
        Screen(name: "05_platforms", title: "Platforms", launchArguments: ["-startTab", "3"]),
        Screen(name: "06_settings", title: "Settings", launchArguments: ["-startTab", "4"])
    ]

    @MainActor
    func testCaptureIPhoneScreenshots() throws {
        try captureScreenshots(expectedDevicePrefix: "iphone_")
    }

    @MainActor
    func testCaptureIPadScreenshots() throws {
        try captureScreenshots(expectedDevicePrefix: "ipad_")
    }

    @MainActor
    private func captureScreenshots(expectedDevicePrefix: String) throws {
        guard let rawConfiguration = ProcessInfo.processInfo.environment["SCREENSHOT_CONFIG"] else {
            throw XCTSkip("Run take_screenshots.sh to provide a screenshot configuration.")
        }

        let configuration: ScreenshotConfiguration
        do {
            configuration = try JSONDecoder().decode(
                ScreenshotConfiguration.self,
                from: Data(rawConfiguration.utf8)
            )
        } catch {
            XCTFail("The screenshot configuration is invalid: \(error.localizedDescription)")
            return
        }

        guard configuration.device.hasPrefix(expectedDevicePrefix) else {
            XCTFail("Expected a \(expectedDevicePrefix) device, received \(configuration.device).")
            return
        }
        guard !configuration.locale.isEmpty,
              !configuration.currency.isEmpty,
              !configuration.output_dir.isEmpty else {
            XCTFail("The screenshot configuration must include locale, currency, and output_dir.")
            return
        }

        let requestedScreens: [Screen]
        if configuration.target_screen.isEmpty {
            requestedScreens = screens
        } else if let screen = screens.first(where: { $0.name == configuration.target_screen }) {
            requestedScreens = [screen]
        } else {
            XCTFail("Unknown screenshot screen: \(configuration.target_screen)")
            return
        }

        for screen in requestedScreens {
            let app = XCUIApplication()
            app.launchArguments = [
                "-loadTestData",
                "-skipICloud",
                "-AppleLanguages",
                "(\(configuration.locale))",
                "-AppleLocale",
                configuration.locale
            ] + screen.launchArguments
            app.launch()

            guard app.navigationBars[screen.title].waitForExistence(timeout: 45) else {
                app.terminate()
                XCTFail("The app did not reach the \(screen.name) screen.")
                return
            }

            // Let charts and SwiftUI transitions settle before retaining the image.
            Thread.sleep(forTimeInterval: 1)
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = screen.name
            attachment.lifetime = .keepAlways
            add(attachment)
            app.terminate()
        }
    }
}
