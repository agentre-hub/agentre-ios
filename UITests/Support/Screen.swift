import XCTest

/// 驱动真实构建的 Agentre：按屏上可见的标签找元素、等它出现、点它、在它里面打字，每一步留截图。
/// 找不到就当场失败并附上当时的截图与无障碍树——失败时要看得出屏上到底是什么。
@MainActor
struct Screen {
    let app: XCUIApplication
    let test: XCTestCase
    /// 截图附件名的前缀（语言 × 外观）。
    let prefix: String
    static let timeout: TimeInterval = 20

    // MARK: 找元素

    func button(_ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    /// 标签以 `label` 开头的按钮（选项行的标签后面可能跟着别的朗读内容）。系统按语言把同一行内
    /// 多个可朗读片段接成一句时，分隔符本身也随语言变——英文是「, 」，简体中文是「、」，两种都认。
    func button(startingWith label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(
            format: "label == %@ OR label BEGINSWITH %@ OR label BEGINSWITH %@", label, label + ",", label + "、"
        )).firstMatch
    }

    func text(_ label: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    func text(containing label: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
    }

    /// 输入框只在 textField / textView 里找：同名的静态文字（占位的那行字）不算。
    func input(_ label: String) -> XCUIElement {
        let kinds = NSPredicate(
            format: "elementType == %d OR elementType == %d",
            XCUIElement.ElementType.textField.rawValue, XCUIElement.ElementType.textView.rawValue
        )
        return app.descendants(matching: .any).matching(kinds)
            .matching(NSPredicate(format: "label == %@ OR placeholderValue == %@", label, label)).firstMatch
    }

    /// 自绘 tab 栏上的一枚按钮，按无障碍标识找（与文案、语言无关）。
    func tab(_ tab: ShellTab) -> XCUIElement {
        app.buttons.matching(identifier: tab.rawValue).firstMatch
    }

    /// 自绘 tab 栏本身：不在界面上时它整个不在无障碍树里。
    var tabBar: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "shell.tabBar").firstMatch
    }

    /// 二级页紧凑导航栏上的返回箭头。
    var back: XCUIElement {
        app.buttons.matching(identifier: "shell.back").firstMatch
    }

    /// 模态导航栏左上的「取消」。
    var cancel: XCUIElement {
        app.buttons.matching(identifier: "shell.cancel").firstMatch
    }

    // MARK: 等与断言

    @discardableResult
    func expect(_ element: XCUIElement, _ what: String, timeout: TimeInterval = Screen.timeout,
                file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        if !element.waitForExistence(timeout: timeout) {
            attachState("missing \(what)")
            XCTFail("\(prefix): \(what) never appeared", file: file, line: line)
        }
        return element
    }

    /// 等元素不在。判它「还在」要亲眼看见：过了 `timeout`，且最近连着两次查询都看见了它。
    /// 不用挂钟窗口（XCTWaiter）：机器一忙，查一次整棵无障碍树就要好几秒（满载下实测 4.3 秒，而窗口开头还有
    /// 1 秒的首查延迟），5 秒的窗口里一次查询都没做完就判了超时——元素其实早已不在。
    func expectGone(_ element: XCUIElement, _ what: String, timeout: TimeInterval = Screen.timeout,
                    file: StaticString = #filePath, line: UInt = #line) {
        let started = Date()
        var sightings = 0
        while element.exists {
            sightings += 1
            let waited = Date().timeIntervalSince(started)
            if waited >= timeout, sightings >= 2 {
                attachState("still there: \(what)")
                XCTFail("\(prefix): \(what) did not go away (seen \(sightings) times over \(Int(waited)) s)", file: file, line: line)
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
    }

    /// 等一个测试进程里的条件成立（伪服务端记下的请求等）：转着主线程的 run loop 轮询，条件一成立即返回。
    func expect(_ what: String, timeout: TimeInterval = Screen.timeout, file: StaticString = #filePath, line: UInt = #line,
                _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                attachState("unmet: \(what)")
                XCTFail("\(prefix): \(what)", file: file, line: line)
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }

    func expectSelected(_ element: XCUIElement, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        expect(element, what, file: file, line: line)
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: element)
        if XCTWaiter().wait(for: [selected], timeout: Screen.timeout) != .completed {
            attachState("not selected: \(what)")
            XCTFail("\(prefix): \(what) is not marked current", file: file, line: line)
        }
    }

    /// 元素此刻在窗口可见范围里（在无障碍树里但被滚出屏外不算看得见）。
    func expectOnScreen(_ element: XCUIElement, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        expect(element, what, file: file, line: line)
        let window = app.windows.firstMatch.frame
        let frame = element.frame
        if frame.isEmpty || !window.intersection(frame).equalTo(frame) {
            attachState("off screen: \(what)")
            XCTFail("\(prefix): \(what) is not on screen (frame \(frame), window \(window))", file: file, line: line)
        }
    }

    // MARK: 操作

    func tap(_ element: XCUIElement, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        expect(element, what, file: file, line: line)
        if element.isHittable {
            element.tap()
        } else {
            // 键盘或别的浮层盖住时按坐标点（元素本身仍在那里）。
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    /// 列表里还没滚到的元素：先往下翻、再往上翻，直到它出现且点得到（每翻一次即重看，不固定等待）。
    func reveal(_ element: XCUIElement, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        for swipeUp in [true, true, true, true, false, false, false, false, false, false, false, false] {
            if element.exists, element.isHittable { return }
            if swipeUp { app.swipeUp() } else { app.swipeDown() }
        }
        expect(element, what, file: file, line: line)
    }

    /// tab 栏在界面上：栏本身与三枚按钮都在。
    func expectTabBar(_ step: String, file: StaticString = #filePath, line: UInt = #line) {
        expect(tabBar, "tab bar on \(step)", file: file, line: line)
        for item in ShellTab.allCases {
            expect(tab(item), "\(item.rawValue) on \(step)", timeout: 2, file: file, line: line)
        }
    }

    /// 界面上不存在任何 tab 栏元素（不是被盖住，是不在）。
    func expectNoTabBar(_ step: String, file: StaticString = #filePath, line: UInt = #line) {
        expectGone(tabBar, "tab bar on \(step)", timeout: 5, file: file, line: line)
        for item in ShellTab.allCases where tab(item).exists {
            attachState("tab button on \(step)")
            XCTFail("\(prefix): \(item.rawValue) is on \(step)", file: file, line: line)
        }
    }

    /// 系统的边缘右滑返回：从屏幕左缘按下，往右拖过大半屏。
    func swipeBackFromEdge() {
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
    }

    /// 在输入框里打字。
    func type(_ text: String, into field: XCUIElement, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        tap(field, what, file: file, line: line)
        field.typeText(text)
    }

    /// 收起停在半屏档的底部面板：点面板上方变暗的那片（系统的点外收起）。
    /// 不从面板里的行往下拖：拖动起点落在可点的行上要与行的按下手势抢，拖到的终点又出了屏幕，
    /// 收不收得起来取决于触摸事件的时序，机器一忙就会偶发收不起来。
    func dismissSheet() {
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
    }

    /// 屏幕左上角、状态栏下方那一小块底色的亮度（0 黑 … 1 白）：外观是否真的切到了深 / 浅。
    func backgroundLuminance() -> Double {
        let image = XCUIScreen.main.screenshot().image
        guard let cgImage = image.cgImage else { return .nan }
        let width = 100, height = 100
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return .nan }
        // 位图第 0 行是画面顶上那一行；取 x 2–4%、y 6–8% 的一小块（左边距、导航栏高度，那里只有底色）。
        var total = 0.0, count = 0.0
        for row in 6...8 {
            for column in 2...4 {
                let offset = (row * width + column) * 4
                let (r, g, b) = (Double(pixels[offset]), Double(pixels[offset + 1]), Double(pixels[offset + 2]))
                total += (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
                count += 1
            }
        }
        return total / count
    }

    func expectAppearance(dark: Bool, _ step: String, file: StaticString = #filePath, line: UInt = #line) {
        let luminance = backgroundLuminance()
        if dark ? !(luminance < 0.3) : !(luminance > 0.7) {
            attachState("wrong appearance at \(step)")
            XCTFail("\(prefix): \(step) background luminance \(luminance) is not \(dark ? "dark" : "light")", file: file, line: line)
        }
    }

    // MARK: 证据

    /// 这一步的截图，随测试结果一起留下（xcresult 附件）。
    func shot(_ step: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "\(prefix) \(step)"
        attachment.lifetime = .keepAlways
        test.add(attachment)
    }

    func attachState(_ reason: String) {
        shot("FAILED \(reason)")
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "\(prefix) FAILED \(reason) accessibility tree"
        tree.lifetime = .keepAlways
        test.add(tree)
    }
}

/// 三个顶层页的 tab 按钮标识（与 App 的 `ShellTab.identifier` 同值；UI 测试不链接 App 的模块）。
enum ShellTab: String, CaseIterable {
    case messages = "shell.tab.messages"
    case machines = "shell.tab.machines"
    case me = "shell.tab.me"
}
