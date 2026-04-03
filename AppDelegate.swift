import Cocoa
import ServiceManagement
import IOKit.hid
import os

// ============================================================================
// LogitechVerticalMXMapper
// ============================================================================
// Side back (button 3)   → Cmd+Ctrl+Shift+4 (screenshot region)  [CGEventTap]
// Side front (button 4)  → Ctrl+V                                 [CGEventTap]
// Top/DPI button (HID++) → Ctrl+Up (Mission Control)              [HID++ divert]
// ============================================================================

// MARK: - Logging

private let loggingEnabled = true

private let logger = Logger(subsystem: "com.kaan.LogitechVerticalMXMapper", category: "main")
private let logFileURL: URL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".mxmapper.log")

private func log(_ msg: String) {
    guard loggingEnabled else { return }
    logger.warning("\(msg, privacy: .public)")
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(msg)\n"
    guard let data = line.data(using: .utf8) else { return }
    if let fh = try? FileHandle(forWritingTo: logFileURL) {
        fh.seekToEndOfFile()
        fh.write(data)
        fh.closeFile()
    } else {
        FileManager.default.createFile(atPath: logFileURL.path, contents: data)
    }
}

// MARK: - Global State

private var gEventTap: CFMachPort?

// MARK: - Key Synthesis

private func postKey(code: UInt16, flags: CGEventFlags) {
    let src = CGEventSource(stateID: .hidSystemState)
    guard let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true),
          let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)
    else { return }
    down.flags = flags
    up.flags = flags
    down.post(tap: .cgSessionEventTap)
    up.post(tap: .cgSessionEventTap)
}

private func triggerMissionControl() {
    DispatchQueue.main.async {
        let url = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

// MARK: - CGEventTap Callback (side buttons)

private func eventTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, _: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = gEventTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passRetained(event)
    }
    guard type == .otherMouseDown else { return Unmanaged.passRetained(event) }

    switch event.getIntegerValueField(.mouseEventButtonNumber) {
    case 3:  // Side back → screenshot region
        postKey(code: 0x15, flags: [.maskCommand, .maskControl, .maskShift])
        return nil
    case 4:  // Side front → Ctrl+V
        postKey(code: 0x09, flags: .maskControl)
        return nil
    default:
        return Unmanaged.passRetained(event)
    }
}

// MARK: - HID++ Protocol Constants

private let LOGI_VENDOR_ID  = 0x046D
private let HIDPP_REPORT_LONG: UInt8 = 0x11      // 20-byte report
private let HIDPP_REPORT_LEN  = 20
private let HIDPP_SW_ID: UInt8 = 0x0A             // Arbitrary software identifier
private let CID_DPI_BUTTON: UInt16 = 0x00FD       // MX Vertical DPI/top button
private let FEAT_REPROG_CONTROLS: UInt16 = 0x1B04 // REPROG_CONTROLS_V4

// MARK: - HID++ Types

private enum HIDPPError: Error, CustomStringConvertible {
    case noDevice
    case openFailed
    case writeFailed
    case timeout
    case featureNotFound
    case protocolError(UInt8)

    var description: String {
        switch self {
        case .noDevice:          return "No Logitech HID++ device found"
        case .openFailed:        return "Failed to open HID device"
        case .writeFailed:       return "Failed to send HID++ report"
        case .timeout:           return "HID++ response timeout"
        case .featureNotFound:   return "HID++ feature not supported"
        case .protocolError(let c): return "HID++ error code \(c)"
        }
    }
}

private struct HIDPPResponse {
    let deviceIndex: UInt8
    let featureIndex: UInt8
    let functionId: UInt8
    let softwareId: UInt8
    let params: [UInt8]
}

// MARK: - HID++ Manager

/// Communicates with the MX Vertical over HID++ 2.0 to divert the DPI button.
/// Runs on a dedicated background thread with its own CFRunLoop.
/// When the diverted button is pressed, synthesizes Ctrl+Up via CGEvent.
private class HIDPPManager {
    private var device: IOHIDDevice?
    private var hidManager: IOHIDManager?
    private let reportBuffer: UnsafeMutablePointer<UInt8>
    private var responseQueue: [HIDPPResponse] = []
    private var deviceIndex: UInt8 = 0xFF
    private var reprogFeatureIndex: UInt8 = 0
    private var dpiButtonHeld = false
    private var shouldRun = true
    private var threadRunLoop: CFRunLoop?

    init() {
        reportBuffer = .allocate(capacity: 64)
        reportBuffer.initialize(repeating: 0, count: 64)
    }

    deinit {
        reportBuffer.deinitialize(count: 64)
        reportBuffer.deallocate()
    }

    /// Launch the HID++ background thread.
    func start() {
        shouldRun = true
        let thread = Thread(target: self, selector: #selector(runLoop), object: nil)
        thread.qualityOfService = .userInitiated
        thread.name = "com.kaan.mxmapper.hidpp"
        thread.start()
    }

    /// Force reconnect (call from main thread on wake).
    func forceReconnect() {
        if let rl = threadRunLoop {
            CFRunLoopStop(rl)
        }
    }

    @objc private func runLoop() {
        threadRunLoop = CFRunLoopGetCurrent()
        while shouldRun {
            do {
                try connect()
                log("HID++ DPI button diverted — listening")
                while shouldRun {
                    let result = CFRunLoopRunInMode(.defaultMode, 2.0, false)
                    if result == .finished || result == .stopped { break }
                }
            } catch {
                log("HID++: \(error)")
            }
            cleanup()
            if shouldRun {
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
    }

    // MARK: Connection

    private func connect() throws {
        let candidates = try findCandidateDevices()
        for candidate in candidates {
            do {
                try openDevice(candidate)
                try discoverDeviceIndex()
                reprogFeatureIndex = try discoverFeature(FEAT_REPROG_CONTROLS)
                try divertButton(CID_DPI_BUTTON)
                return
            } catch {
                closeDevice()
            }
        }
        throw HIDPPError.noDevice
    }

    /// Find all Logitech vendor-specific HID interfaces that support long reports.
    private func findCandidateDevices() throws -> [IOHIDDevice] {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matchDict: [String: Any] = [kIOHIDVendorIDKey as String: LOGI_VENDOR_ID]
        IOHIDManagerSetDeviceMatching(mgr, matchDict as CFDictionary)
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetCurrent(),
                                        CFRunLoopMode.defaultMode.rawValue)
        guard IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            throw HIDPPError.openFailed
        }
        hidManager = mgr

        guard let deviceSet = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice> else {
            throw HIDPPError.noDevice
        }

        for dev in deviceSet {
            let name = IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String ?? "?"
            let pid = IOHIDDeviceGetProperty(dev, kIOHIDProductIDKey as CFString) as? Int ?? 0
            let page = IOHIDDeviceGetProperty(dev, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? 0
            let maxIn = IOHIDDeviceGetProperty(dev, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 0
            log("  HID: \(name) pid=0x\(String(format:"%04X",pid)) page=0x\(String(format:"%04X",page)) maxIn=\(maxIn)")
        }

        // Filter: vendor-specific usage page (HID++) and supports long reports
        let filtered = deviceSet.filter { dev in
            let usagePage = IOHIDDeviceGetProperty(dev, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? 0
            let maxInput = IOHIDDeviceGetProperty(dev, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 0
            return usagePage >= 0xFF00 && maxInput >= 19
        }
        return Array(filtered)
    }

    /// Open a HID device non-exclusively and register for input reports.
    private func openDevice(_ dev: IOHIDDevice) throws {
        // kIOHIDOptionsTypeNone = non-exclusive, mouse keeps working
        guard IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            throw HIDPPError.openFailed
        }
        device = dev

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(
            dev, reportBuffer, 64, hidppInputReportCallback, context)
        IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetCurrent(),
                                       CFRunLoopMode.defaultMode.rawValue)
        log("HID++ device opened")
    }

    private func closeDevice() {
        if let dev = device {
            IOHIDDeviceUnscheduleFromRunLoop(dev, CFRunLoopGetCurrent(),
                                             CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceRegisterInputReportCallback(dev, reportBuffer, 64, nil, nil)
            IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        device = nil
    }

    // MARK: HID++ Protocol

    /// Try device indices 0xFF (direct BT/USB), then 1-6 (via Bolt/Unifying receiver).
    private func discoverDeviceIndex() throws {
        // Try long reports first, then short — on each device index
        for useShort in [false, true] {
            for idx: UInt8 in [0xFF, 1, 2, 3, 4, 5, 6] {
                deviceIndex = idx
                do {
                    _ = useShort
                        ? try sendShortRequest(featureIndex: 0x00, functionId: 0,
                                               params: [0x00, 0x01, 0x00])
                        : try sendRequest(featureIndex: 0x00, functionId: 0,
                                          params: [0x00, 0x01, 0x00])
                    log("HID++ device index: 0x\(String(format: "%02X", idx))")
                    return
                } catch {
                    continue
                }
            }
        }
        throw HIDPPError.noDevice
    }

    /// Send an HID++ SHORT report (7 bytes, report ID 0x10).
    private func sendShortRequest(featureIndex: UInt8, functionId: UInt8,
                                  params: [UInt8]) throws -> HIDPPResponse {
        guard let dev = device else { throw HIDPPError.noDevice }
        let HIDPP_SHORT: UInt8 = 0x10
        var buffer = [UInt8](repeating: 0, count: 7)
        buffer[0] = HIDPP_SHORT
        buffer[1] = deviceIndex
        buffer[2] = featureIndex
        buffer[3] = (functionId << 4) | (HIDPP_SW_ID & 0x0F)
        for (i, p) in params.prefix(3).enumerated() {
            buffer[i + 4] = p
        }

        responseQueue.removeAll()
        let result = IOHIDDeviceSetReport(
            dev, kIOHIDReportTypeOutput, CFIndex(HIDPP_SHORT),
            buffer, buffer.count)
        guard result == kIOReturnSuccess else { throw HIDPPError.writeFailed }

        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.05, true)
            if let errIdx = responseQueue.firstIndex(where: {
                $0.deviceIndex == self.deviceIndex && $0.featureIndex == 0xFF
            }) {
                let errResp = responseQueue.remove(at: errIdx)
                throw HIDPPError.protocolError(errResp.params.count > 1 ? errResp.params[1] : 0)
            }
            if let okIdx = responseQueue.firstIndex(where: {
                $0.deviceIndex == self.deviceIndex &&
                $0.featureIndex == featureIndex &&
                $0.softwareId == HIDPP_SW_ID
            }) {
                return responseQueue.remove(at: okIdx)
            }
        }
        throw HIDPPError.timeout
    }

    /// Use IRoot (feature index 0x00, function 0) to find the runtime index of a feature.
    private func discoverFeature(_ featureId: UInt16) throws -> UInt8 {
        let hi = UInt8((featureId >> 8) & 0xFF)
        let lo = UInt8(featureId & 0xFF)
        let resp = try sendRequest(featureIndex: 0x00, functionId: 0, params: [hi, lo, 0x00])
        guard !resp.params.isEmpty, resp.params[0] != 0 else {
            throw HIDPPError.featureNotFound
        }
        log("Feature 0x\(String(format: "%04X", featureId)) → index \(resp.params[0])")
        return resp.params[0]
    }

    /// setCidReporting: divert a button so events come as HID++ notifications.
    /// Flags 0x03 = divert + persist (survives power cycles).
    private func divertButton(_ cid: UInt16) throws {
        let hi = UInt8((cid >> 8) & 0xFF)
        let lo = UInt8(cid & 0xFF)
        _ = try sendRequest(featureIndex: reprogFeatureIndex, functionId: 3,
                            params: [hi, lo, 0x03, 0x00, 0x00])
        log("Diverted CID 0x\(String(format: "%04X", cid))")
    }

    /// Send an HID++ long report and wait for a matching response.
    private func sendRequest(featureIndex: UInt8, functionId: UInt8,
                             params: [UInt8]) throws -> HIDPPResponse {
        guard let dev = device else { throw HIDPPError.noDevice }

        // Build 20-byte long report (report ID as first byte, matching hidapi convention)
        var buffer = [UInt8](repeating: 0, count: HIDPP_REPORT_LEN)
        buffer[0] = HIDPP_REPORT_LONG                        // Report ID
        buffer[1] = deviceIndex                                // Device index
        buffer[2] = featureIndex                               // Feature index
        buffer[3] = (functionId << 4) | (HIDPP_SW_ID & 0x0F)  // Function + SW ID
        for (i, p) in params.prefix(16).enumerated() {
            buffer[i + 4] = p
        }

        responseQueue.removeAll()

        let result = IOHIDDeviceSetReport(
            dev, kIOHIDReportTypeOutput, CFIndex(HIDPP_REPORT_LONG),
            buffer, buffer.count)
        guard result == kIOReturnSuccess else {
            throw HIDPPError.writeFailed
        }

        // Poll for matching response with 2s timeout
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.05, true)

            // Check for HID++ error response (featureIndex == 0xFF)
            if let errIdx = responseQueue.firstIndex(where: {
                $0.deviceIndex == self.deviceIndex && $0.featureIndex == 0xFF
            }) {
                let errResp = responseQueue.remove(at: errIdx)
                let code = errResp.params.count > 1 ? errResp.params[1] : 0
                throw HIDPPError.protocolError(code)
            }

            // Check for matching success response
            if let okIdx = responseQueue.firstIndex(where: {
                $0.deviceIndex == self.deviceIndex &&
                $0.featureIndex == featureIndex &&
                $0.softwareId == HIDPP_SW_ID
            }) {
                return responseQueue.remove(at: okIdx)
            }
        }
        throw HIDPPError.timeout
    }

    // MARK: Input Report Handling

    /// Called from the IOKit input report callback on the HID++ thread.
    fileprivate func handleInputReport(reportID: UInt8, data: UnsafePointer<UInt8>, length: Int) {
        // IOKit on macOS includes the report ID as first byte in the buffer
        var offset = 0
        if length >= 1 && (data[0] == 0x10 || data[0] == 0x11 || data[0] == 0x20) {
            offset = 1
        }

        let payloadLen = length - offset
        guard payloadLen >= 3 else { return }
        let safePayload = min(payloadLen, 60)

        let devIdx  = data[offset]
        let featIdx = data[offset + 1]
        let funcSw  = data[offset + 2]
        let funcId  = funcSw >> 4
        let swId    = funcSw & 0x0F

        var params: [UInt8] = []
        for i in 3..<safePayload {
            params.append(data[offset + i])
        }

        let response = HIDPPResponse(
            deviceIndex: devIdx, featureIndex: featIdx,
            functionId: funcId, softwareId: swId, params: params)

        // HID++ 1.0 error response: featIdx == 0x8F
        // Convert to standard error format for response matching
        if featIdx == 0x8F {
            let errResponse = HIDPPResponse(
                deviceIndex: devIdx, featureIndex: 0xFF,
                functionId: funcId, softwareId: swId, params: params)
            responseQueue.append(errResponse)
            return
        }

        // Is this a diverted button notification?
        // Notifications have function 0 on the REPROG feature and SW ID != ours
        if devIdx == deviceIndex && featIdx == reprogFeatureIndex
            && funcId == 0 && swId != HIDPP_SW_ID {
            handleDivertedButtonEvent(params: params)
            return
        }

        // Otherwise queue for sendRequest to consume
        responseQueue.append(response)
    }

    /// Parse divertedButtonsEvent: sequential CID pairs terminated by 0x0000.
    private func handleDivertedButtonEvent(params: [UInt8]) {
        var dpiPressed = false
        var i = 0
        while i + 1 < params.count {
            let cid = (UInt16(params[i]) << 8) | UInt16(params[i + 1])
            if cid == 0 { break }
            if cid == CID_DPI_BUTTON { dpiPressed = true }
            i += 2
        }

        if dpiPressed && !dpiButtonHeld {
            dpiButtonHeld = true
            log("DPI button → Mission Control")
            triggerMissionControl()
        } else if !dpiPressed {
            dpiButtonHeld = false
        }
    }

    // MARK: Cleanup

    private func cleanup() {
        // Best-effort undivert before closing
        if let dev = device, reprogFeatureIndex != 0 {
            var buffer = [UInt8](repeating: 0, count: HIDPP_REPORT_LEN)
            buffer[0] = HIDPP_REPORT_LONG
            buffer[1] = deviceIndex
            buffer[2] = reprogFeatureIndex
            buffer[3] = (3 << 4) | (HIDPP_SW_ID & 0x0F) // setCidReporting
            buffer[4] = UInt8((CID_DPI_BUTTON >> 8) & 0xFF)
            buffer[5] = UInt8(CID_DPI_BUTTON & 0xFF)
            buffer[6] = 0x00 // flags = 0 → undivert
            IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput,
                                 CFIndex(HIDPP_REPORT_LONG), buffer, buffer.count)
        }
        closeDevice()
        if let mgr = hidManager {
            IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetCurrent(),
                                              CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
            hidManager = nil
        }
        reprogFeatureIndex = 0
        dpiButtonHeld = false
        responseQueue.removeAll()
    }
}

/// C-convention callback for IOKit HID input reports.
private func hidppInputReportCallback(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    type: IOHIDReportType,
    reportID: UInt32,
    report: UnsafeMutablePointer<UInt8>,
    reportLength: CFIndex
) {
    guard let context = context else { return }
    let manager = Unmanaged<HIDPPManager>.fromOpaque(context).takeUnretainedValue()
    manager.handleInputReport(reportID: UInt8(reportID), data: report, length: Int(reportLength))
}

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var accessibilityTimer: Timer?
    private let hidppManager = HIDPPManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Reset log file on each launch
        try? "".write(to: logFileURL, atomically: true, encoding: .utf8)
        log("App launched")
        setupMenuBar()
        enableLoginItemOnFirstLaunch()
        ensureAccessibilityAndStart()

        // Re-divert DPI button on wake from sleep
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(onSystemWake),
            name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc private func onSystemWake() {
        log("System wake — forcing HID++ reconnect")
        hidppManager.forceReconnect()
    }

    @objc private func reconnectHID(_ sender: NSMenuItem) {
        log("Manual HID++ reconnect requested")
        hidppManager.forceReconnect()
    }

    // MARK: Accessibility

    private func ensureAccessibilityAndStart() {
        if AXIsProcessTrusted() {
            log("Accessibility: OK")
            startAll()
        } else {
            log("Accessibility: prompting")
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
            accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) {
                [weak self] timer in
                if AXIsProcessTrusted() {
                    log("Accessibility: granted")
                    timer.invalidate()
                    self?.startAll()
                }
            }
        }
    }

    private func startAll() {
        startEventTap()
        hidppManager.start()
    }

    // MARK: Event Tap

    private func startEventTap() {
        let mask: CGEventMask = 1 << CGEventType.otherMouseDown.rawValue
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask,
            callback: eventTapCallback, userInfo: nil
        ) else {
            log("Event tap FAILED")
            return
        }
        gEventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        log("Event tap ACTIVE")
    }

    // MARK: Menu Bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let btn = statusItem.button {
            btn.image = NSImage(systemSymbolName: "computermouse",
                                accessibilityDescription: "MX Mapper")
        }
        let menu = NSMenu()
        let title = NSMenuItem(title: "LogitechVerticalMXMapper — Running",
                               action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())

        let reconnectItem = NSMenuItem(title: "Reconnect HID++",
                                       action: #selector(reconnectHID(_:)), keyEquivalent: "r")
        reconnectItem.target = self
        menu.addItem(reconnectItem)

        menu.addItem(.separator())

        let loginItem = NSMenuItem(title: "Start at Login",
                                   action: #selector(toggleLogin(_:)), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = UserDefaults.standard.bool(forKey: "startAtLogin") ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        let enabled = sender.state != .on
        sender.state = enabled ? .on : .off
        UserDefaults.standard.set(enabled, forKey: "startAtLogin")
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            log("SMAppService error: \(error)")
        }
    }

    private func enableLoginItemOnFirstLaunch() {
        guard !UserDefaults.standard.bool(forKey: "didFirstLaunch") else { return }
        UserDefaults.standard.set(true, forKey: "didFirstLaunch")
        UserDefaults.standard.set(true, forKey: "startAtLogin")
        try? SMAppService.mainApp.register()
        if let menu = statusItem.menu,
           let item = menu.items.first(where: { $0.action == #selector(toggleLogin(_:)) }) {
            item.state = .on
        }
    }
}

// MARK: - Main

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
