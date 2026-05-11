import SwiftUI
import AppKit
import Carbon.HIToolbox

@main
struct BarcodeMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

final class AppState: ObservableObject {
    static let clipboardPreviewFontSize: CGFloat = 11
    static let exportedTextBaseFontSize: CGFloat = 22

    enum SizePreset: String, CaseIterable {
        case s
        case m
        case l

        var title: String { rawValue.uppercased() }

        var scaleMultiplier: CGFloat {
            switch self {
            case .s: return 1.0
            case .m: return 1.8
            case .l: return 2.6
            }
        }
    }

    @Published var barcodeString: String = ""
    @Published var barcodeImage: NSImage? = nil
    @Published var showQRCode: Bool = false
    @Published var statusMessage: String = ""
    @Published var shortcutDisplay: String = ""
    @Published var isRecordingShortcut: Bool = false
    @Published var recordingHint: String = ""
    @Published var sizePreset: SizePreset = .m
    var startRecordingShortcut: (() -> Void)?
    var updatePopoverSize: (() -> Void)?
    var quitApp: (() -> Void)?

    func updateFromClipboard() {
        let pasteboard = NSPasteboard.general
        if let value = pasteboard.string(forType: .string), !value.isEmpty {
            barcodeString = value
            barcodeImage = generateImage(for: value)
            statusMessage = "Ready"
        } else {
            barcodeString = ""
            barcodeImage = nil
            statusMessage = "Clipboard has no text"
        }
    }

    func copyBarcodeImage() {
        guard let image = barcodeImage else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        statusMessage = "Copied image"
    }

    func refreshImage() {
        guard !barcodeString.isEmpty else {
            barcodeImage = nil
            return
        }
        barcodeImage = generateImage(for: barcodeString)
    }

    private func generateImage(for value: String) -> NSImage? {
        let rawImage: NSImage?
        if showQRCode {
            rawImage = BarcodeGenerator.generateQRCode(from: value, sizeMultiplier: sizePreset.scaleMultiplier)
        } else {
            rawImage = BarcodeGenerator.generateCode128(from: value, sizeMultiplier: sizePreset.scaleMultiplier)
        }
        guard let rawImage else { return nil }
        return BarcodeGenerator.composeImage(
            rawImage: rawImage,
            text: value,
            fontSize: Self.exportedTextBaseFontSize * sizePreset.scaleMultiplier
        )
    }

    func startRecordingUI() {
        isRecordingShortcut = true
        recordingHint = "Press a key combo, Esc to cancel"
    }

    func stopRecordingUI(status: String) {
        isRecordingShortcut = false
        recordingHint = ""
        statusMessage = status
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let appState = AppState()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem!
    private var hostingController: NSHostingController<AnyView>?
    private var recordingLocalMonitor: Any?
    private var recordingGlobalMonitor: Any?
    private var popoverLocalMonitor: Any?
    private var popoverGlobalMonitor: Any?

    private let defaultHotKey = HotKey(keyCode: UInt32(kVK_ANSI_B), modifiers: UInt32(cmdKey | shiftKey))

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)

        popover.behavior = .applicationDefined
        popover.delegate = self
        let rootView = AnyView(ContentView().environmentObject(appState))
        let hostingController = NSHostingController(rootView: rootView)
        self.hostingController = hostingController
        popover.contentViewController = hostingController
        appState.startRecordingShortcut = { [weak self] in
            self?.startRecordingShortcut()
        }
        appState.updatePopoverSize = { [weak self] in
            self?.requestPopoverResize()
        }
        appState.quitApp = {
            NSApplication.shared.terminate(nil)
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "barcode", accessibilityDescription: "Barcode")
            button.action = #selector(togglePopover)
            button.target = self
        }

        let hotKey = loadHotKey() ?? defaultHotKey
        registerHotKey(hotKey)
        appState.shortcutDisplay = HotKeyFormatter.displayString(for: hotKey)

        HotKeyManager.shared.onHotKey = { [weak self] in
            self?.handleHotKey()
        }

        appState.updateFromClipboard()
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotKeyManager.shared.unregister()
        removeRecordingMonitors()
        removePopoverMonitors()
    }

    @objc private func togglePopover() {
        if popover.isShown {
            closePopover()
        } else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            appState.updateFromClipboard()
            requestPopoverResize()
            installPopoverMonitors()
        }
    }

    private func handleHotKey() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.appState.updateFromClipboard()
            self.ensurePopoverVisible()
        }
    }

    func startRecordingShortcut() {
        ensurePopoverVisible()
        appState.startRecordingUI()
        removeRecordingMonitors()
        recordingLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            return self.handleRecordingEvent(event)
        }
        recordingGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            _ = self?.handleRecordingEvent(event)
        }
    }

    private func removeRecordingMonitors() {
        if let monitor = recordingLocalMonitor {
            NSEvent.removeMonitor(monitor)
            recordingLocalMonitor = nil
        }
        if let monitor = recordingGlobalMonitor {
            NSEvent.removeMonitor(monitor)
            recordingGlobalMonitor = nil
        }
    }

    private func handleRecordingEvent(_ event: NSEvent) -> NSEvent? {
        if event.keyCode == UInt16(kVK_Escape) {
            appState.stopRecordingUI(status: "Shortcut unchanged")
            removeRecordingMonitors()
            return nil
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let carbonModifiers = HotKeyFormatter.carbonModifiers(from: modifiers)
        if carbonModifiers == 0 {
            appState.statusMessage = "Use at least one modifier"
            return nil
        }
        let hotKey = HotKey(keyCode: UInt32(event.keyCode), modifiers: carbonModifiers)
        saveHotKey(hotKey)
        registerHotKey(hotKey)
        appState.shortcutDisplay = HotKeyFormatter.displayString(for: hotKey)
        appState.stopRecordingUI(status: "Shortcut updated")
        removeRecordingMonitors()
        return nil
    }

    private func ensurePopoverVisible() {
        if popover.isShown == false, let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            requestPopoverResize()
            installPopoverMonitors()
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func requestPopoverResize() {
        DispatchQueue.main.async { [weak self] in
            self?.resizePopoverToFit()
        }
    }

    private func resizePopoverToFit() {
        guard popover.isShown else { return }
        guard let hostingController else { return }
        hostingController.view.layoutSubtreeIfNeeded()
        let fittingSize = hostingController.view.fittingSize
        guard fittingSize.width.isFinite,
              fittingSize.height.isFinite,
              fittingSize.width > 0,
              fittingSize.height > 0 else { return }
        popover.contentSize = fittingSize
    }

    private func closePopover() {
        popover.performClose(nil)
        removePopoverMonitors()
    }

    func popoverDidClose(_ notification: Notification) {
        removePopoverMonitors()
    }

    private func installPopoverMonitors() {
        removePopoverMonitors()
        popoverLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self else { return event }
            if self.shouldClosePopover(forLocalEvent: event) {
                self.closePopover()
                return nil
            }
            return event
        }
        popoverGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.closePopoverIfOutsideForGlobalClick()
        }
    }

    private func removePopoverMonitors() {
        if let monitor = popoverLocalMonitor {
            NSEvent.removeMonitor(monitor)
            popoverLocalMonitor = nil
        }
        if let monitor = popoverGlobalMonitor {
            NSEvent.removeMonitor(monitor)
            popoverGlobalMonitor = nil
        }
    }

    private func shouldClosePopover(forLocalEvent event: NSEvent) -> Bool {
        guard popover.isShown else { return false }
        let locationOnScreen: NSPoint
        if let eventWindow = event.window {
            locationOnScreen = eventWindow.convertPoint(toScreen: event.locationInWindow)
        } else {
            locationOnScreen = NSEvent.mouseLocation
        }
        return isOutsidePopoverAndStatusItem(locationOnScreen)
    }

    private func closePopoverIfOutsideForGlobalClick() {
        guard popover.isShown else { return }
        let locationOnScreen = NSEvent.mouseLocation
        if isOutsidePopoverAndStatusItem(locationOnScreen) {
            closePopover()
        }
    }

    private func isOutsidePopoverAndStatusItem(_ locationOnScreen: NSPoint) -> Bool {
        if let popoverWindow = popover.contentViewController?.view.window,
           popoverWindow.frame.contains(locationOnScreen) {
            return false
        }

        if let button = statusItem.button, let buttonWindow = button.window {
            let buttonFrameInWindow = button.convert(button.bounds, to: nil)
            let buttonFrameOnScreen = buttonWindow.convertToScreen(buttonFrameInWindow)
            if buttonFrameOnScreen.contains(locationOnScreen) {
                return false
            }
        }
        return true
    }

    private func registerHotKey(_ hotKey: HotKey) {
        HotKeyManager.shared.register(keyCode: hotKey.keyCode, modifiers: hotKey.modifiers)
    }

    private func saveHotKey(_ hotKey: HotKey) {
        UserDefaults.standard.set(Int(hotKey.keyCode), forKey: "HotKeyKeyCode")
        UserDefaults.standard.set(Int(hotKey.modifiers), forKey: "HotKeyModifiers")
    }

    private func loadHotKey() -> HotKey? {
        guard UserDefaults.standard.object(forKey: "HotKeyKeyCode") != nil else { return nil }
        let keyCode = UserDefaults.standard.integer(forKey: "HotKeyKeyCode")
        let modifiers = UserDefaults.standard.integer(forKey: "HotKeyModifiers")
        if modifiers == 0 { return nil }
        return HotKey(keyCode: UInt32(keyCode), modifiers: UInt32(modifiers))
    }
}

struct ContentView: View {
    @EnvironmentObject private var appState: AppState

    private var contentWidth: CGFloat {
        let baseWidth: CGFloat = 320
        let outerPadding: CGFloat = 16 * 2
        let baseImageWidth: CGFloat = 280
        return max(baseWidth, baseImageWidth * appState.sizePreset.scaleMultiplier + outerPadding)
    }

    private var imageFrameWidth: CGFloat {
        let baseImageWidth: CGFloat = 280
        return baseImageWidth * appState.sizePreset.scaleMultiplier
    }

    private var imageFrameHeight: CGFloat {
        let baseHeight: CGFloat = appState.showQRCode ? 220 : 90
        return baseHeight * appState.sizePreset.scaleMultiplier
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(appState.showQRCode ? "QR Code" : "Code 128 Barcode")
                .font(.headline)

            if let image = appState.barcodeImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(width: imageFrameWidth, height: imageFrameHeight)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 4)

                HStack(spacing: 8) {
                    Text("Size")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    ForEach(AppState.SizePreset.allCases, id: \.rawValue) { preset in
                        Button(preset.title) {
                            appState.sizePreset = preset
                            appState.refreshImage()
                            appState.updatePopoverSize?()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(appState.sizePreset == preset ? .accentColor : .gray)
                    }
                }
            } else {
                Text("No barcode")
                    .foregroundStyle(.secondary)
            }

            if !appState.barcodeString.isEmpty {
                Text(appState.barcodeString)
                    .font(.system(size: AppState.clipboardPreviewFontSize, weight: .regular, design: .monospaced))
                    .lineLimit(2)
            }

            VStack(alignment: .leading, spacing: 8) {
                Button(appState.showQRCode ? "Show Code 128" : "Show QR") {
                    appState.showQRCode.toggle()
                    appState.refreshImage()
                    appState.updatePopoverSize?()
                }

                Button("Copy Image") {
                    appState.copyBarcodeImage()
                }
                .disabled(appState.barcodeImage == nil)

                HStack(spacing: 8) {
                    Button(appState.isRecordingShortcut ? "Recording..." : "Change Shortcut") {
                        appState.startRecordingShortcut?()
                    }
                    .disabled(appState.isRecordingShortcut)

                    Text(appState.shortcutDisplay)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            if appState.isRecordingShortcut {
                Text(appState.recordingHint)
                    .font(.system(size: 11))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.yellow.opacity(0.25))
                    .cornerRadius(6)
            }

            HStack(spacing: 8) {
                Button("Quit") {
                    appState.quitApp?()
                }
                .buttonStyle(.bordered)
                .tint(.red)

                Text(appState.statusMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .frame(width: contentWidth)
        .onAppear {
            appState.updatePopoverSize?()
        }
    }
}

struct HotKey {
    let keyCode: UInt32
    let modifiers: UInt32
}

final class HotKeyManager {
    static let shared = HotKeyManager()

    private let hotKeyID = EventHotKeyID(signature: OSType(0x484B4D42), id: 1)
    private var hotKeyRef: EventHotKeyRef? = nil
    private var eventHandlerRef: EventHandlerRef? = nil

    var onHotKey: (() -> Void)?

    func register(keyCode: UInt32, modifiers: UInt32) {
        unregister()
        installHandlerIfNeeded()
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    private func installHandlerIfNeeded() {
        if eventHandlerRef != nil { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), hotKeyHandler, 1, &eventType, nil, &eventHandlerRef)
    }
}

private func hotKeyHandler(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return noErr }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )

    if status == noErr && hotKeyID.signature == OSType(0x484B4D42) && hotKeyID.id == 1 {
        HotKeyManager.shared.onHotKey?()
    }

    return noErr
}

enum HotKeyFormatter {
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        return modifiers
    }

    static func displayString(for hotKey: HotKey) -> String {
        let key = keyString(for: hotKey.keyCode)
        var parts: [String] = []
        if hotKey.modifiers & UInt32(cmdKey) != 0 { parts.append("Cmd") }
        if hotKey.modifiers & UInt32(shiftKey) != 0 { parts.append("Shift") }
        if hotKey.modifiers & UInt32(optionKey) != 0 { parts.append("Opt") }
        if hotKey.modifiers & UInt32(controlKey) != 0 { parts.append("Ctrl") }
        parts.append(key)
        return parts.joined(separator: "+")
    }

    private static func keyString(for keyCode: UInt32) -> String {
        switch keyCode {
        case 0: return "A"
        case 11: return "B"
        case 8: return "C"
        case 2: return "D"
        case 14: return "E"
        case 3: return "F"
        case 5: return "G"
        case 4: return "H"
        case 34: return "I"
        case 38: return "J"
        case 40: return "K"
        case 37: return "L"
        case 46: return "M"
        case 45: return "N"
        case 31: return "O"
        case 35: return "P"
        case 12: return "Q"
        case 15: return "R"
        case 1: return "S"
        case 17: return "T"
        case 32: return "U"
        case 9: return "V"
        case 13: return "W"
        case 7: return "X"
        case 16: return "Y"
        case 6: return "Z"
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 23: return "5"
        case 22: return "6"
        case 26: return "7"
        case 28: return "8"
        case 25: return "9"
        case 29: return "0"
        default: return "Key"
        }
    }
}

enum BarcodeGenerator {
    static func generateCode128(from string: String, sizeMultiplier: CGFloat = 1.0) -> NSImage? {
        guard let data = string.data(using: .ascii, allowLossyConversion: true) else { return nil }
        guard let filter = CIFilter(name: "CICode128BarcodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue(7.0, forKey: "inputQuietSpace")
        guard let outputImage = filter.outputImage else { return nil }

        let baseScale: CGFloat = 3.0
        let finalScale = baseScale * sizeMultiplier
        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: finalScale, y: finalScale))
        let rep = NSCIImageRep(ciImage: scaledImage)
        let nsImage = NSImage(size: rep.size)
        nsImage.addRepresentation(rep)
        return nsImage
    }

    static func generateQRCode(from string: String, sizeMultiplier: CGFloat = 1.0) -> NSImage? {
        guard let data = string.data(using: .utf8) else { return nil }
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let outputImage = filter.outputImage else { return nil }

        let baseScale: CGFloat = 8.0
        let finalScale = baseScale * sizeMultiplier
        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: finalScale, y: finalScale))
        let rep = NSCIImageRep(ciImage: scaledImage)
        let nsImage = NSImage(size: rep.size)
        nsImage.addRepresentation(rep)
        return nsImage
    }

    static func composeImage(rawImage: NSImage, text: String, fontSize: CGFloat) -> NSImage {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraph,
            .foregroundColor: NSColor.labelColor
        ]

        let textPadding: CGFloat = 6
        let textSize = NSString(string: text).size(withAttributes: attributes)
        let textHeight = textSize.height + textPadding * 2

        let width = max(rawImage.size.width, textSize.width + 12)
        let height = rawImage.size.height + textHeight

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()

        let imageX = (width - rawImage.size.width) / 2
        rawImage.draw(at: NSPoint(x: imageX, y: textHeight), from: .zero, operation: .sourceOver, fraction: 1.0)

        let textRect = NSRect(x: 0, y: 0, width: width, height: textHeight)
        NSString(string: text).draw(in: textRect.insetBy(dx: 6, dy: textPadding), withAttributes: attributes)

        image.unlockFocus()
        return image
    }
}

extension EnvironmentValues {
    var nsApplication: NSApplication {
        NSApplication.shared
    }
}
