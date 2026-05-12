//
//  AppDelegate.swift
//  BrightXDR
//
//  Created by Dmitry Starkov on 31/03/2023.
//

import Cocoa
import Carbon.HIToolbox

// UserDefaults key for the user-controlled Boost toggle. MetalView reads this
// each draw cycle and uses it as a multiplier alongside the
// screencaptureui-detected suppress condition.
let boostEnabledKey = "boostEnabled"

// UserDefaults key for the brightness multiplier driven by the menu-bar
// slider. Range 0.5..2.5; default 1.5 (the previous hardcoded value).
let brightnessValueKey = "brightnessValue"
let brightnessDefault: Float = 1.5
let brightnessMin: Float = 0.5
let brightnessMax: Float = 2.5

class AppDelegate: NSObject, NSApplicationDelegate {
    // The overlay window
    private var window: NSWindow!

    // The MTKView instance
    private var metalView: MetalView!

    // Status bar item retained for the lifetime of the app
    private var statusItem: NSStatusItem!
    private var boostMenuItem: NSMenuItem!
    private var brightnessLabelItem: NSMenuItem!

    // Global Boost hotkey (⌃⌥⌘B). Registered via Carbon RegisterEventHotKey so
    // it fires even when the overlay has whited out the screen and the menu
    // bar is unreachable — the primary recovery path documented in #4.
    private var boostHotKeyRef: EventHotKeyRef?
    private var boostHotKeyHandler: EventHandlerRef?

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        installStatusItem()
        registerBoostHotKey()
        guard let mainScreen = NSScreen.main else { return }

        // let splitViewRect = NSRect(x: mainScreen.frame.width/2, y: 0, width: mainScreen.frame.width/2, height: mainScreen.frame.height)
        let fullScreenRect = NSRect(x: 0, y: 0, width: mainScreen.frame.width, height: mainScreen.frame.height)

        // Create a new transparent, borderless window
        window = NSWindow(contentRect: fullScreenRect, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        // Ignore all mouse events
        window.ignoresMouseEvents = true
        // Exclude the overlay from screen capture / screenshots / screen recording.
        // Without this, macOS captures the multiply-blended HDR composite and
        // re-encodes it as SDR, producing washed-out screenshots.
        window.sharingType = .none

        // Set the window's level to mainMenu to make it float above all other windows
        // Requires "Application is agent (UIElement)" set to "YES" in info.plist for system-wide support
        // The maximum possible values is NSWindow.Level(rawValue: Int(CGShieldingWindowLevel() + 19))
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 19)

        // Allow window to overlay in Mission Control and Spaces
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle] // .managed

        // Keep visible all time (required for overlays)
        window.hidesOnDeactivate = false
        // window.allowsConcurrentViewDrawing = true

        // Add metal view with HDR overlay
        guard let view = window.contentView else { return }
        // The contrast and brightness can be adjusted for a brighter effect, at the expense of color correctness
        // 30fps so window.alphaValue updates (suppress on/off) respond within
        // one draw cycle (~33ms) instead of 333ms. The render path is a static
        // CIImage; the cost increase is negligible.
        metalView = MetalView(frame: view.bounds, frameRate: 30, contrast: 1.0, brightness: currentBrightness())
        metalView.autoresizingMask = [.width, .height]
        view.addSubview(metalView)

        // Present the window
        window.makeKeyAndOrderFront(nil)
    }

    private func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: "Brightness")
        }

        let menu = NSMenu(title: "BrightXDR")

        let appNameItem = NSMenuItem(title: "BrightXDR", action: nil, keyEquivalent: "")
        appNameItem.isEnabled = false
        menu.addItem(appNameItem)

        menu.addItem(NSMenuItem.separator())

        boostMenuItem = NSMenuItem(title: "Boost", action: #selector(toggleBoost(_:)), keyEquivalent: "b")
        boostMenuItem.target = self
        // Display the global hotkey (⌃⌥⌘B) on the menu item so users can
        // discover it. Carbon RegisterEventHotKey owns the actual key handling
        // system-wide; the menu's keyEquivalent only fires while the status
        // menu is open. Both paths route through toggleBoost(_:), so a
        // double-fire would be a no-op-pair anyway.
        boostMenuItem.keyEquivalentModifierMask = [.control, .option, .command]
        boostMenuItem.state = boostEnabled() ? .on : .off
        menu.addItem(boostMenuItem)

        let value = currentBrightness()
        brightnessLabelItem = NSMenuItem(title: brightnessLabel(for: value), action: nil, keyEquivalent: "")
        brightnessLabelItem.isEnabled = false
        menu.addItem(brightnessLabelItem)

        let sliderItem = NSMenuItem()
        let sliderWidth: CGFloat = 220
        // Extra height to fit the tick marks rendered below the slider bar.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: sliderWidth, height: 32))
        let slider = NSSlider(frame: NSRect(x: 16, y: 4, width: sliderWidth - 32, height: 24))
        slider.minValue = Double(brightnessMin)
        slider.maxValue = Double(brightnessMax)
        slider.doubleValue = Double(value)
        slider.target = self
        slider.action = #selector(brightnessChanged(_:))
        slider.isContinuous = true
        // Snap to 0.10 increments. Range is 2.0 wide → 21 stops.
        slider.numberOfTickMarks = 21
        slider.allowsTickMarkValuesOnly = true
        slider.tickMarkPosition = .below
        container.addSubview(slider)
        sliderItem.view = container
        menu.addItem(sliderItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    private func boostEnabled() -> Bool {
        // Default to enabled if the user has never set the preference.
        UserDefaults.standard.object(forKey: boostEnabledKey) as? Bool ?? true
    }

    @objc private func toggleBoost(_ sender: NSMenuItem) {
        toggleBoostState()
    }

    /// Shared toggle path for both the menu item and the global hotkey.
    /// Writes to `boostEnabledKey` (MetalView reads it each draw) and updates
    /// the menu item's checkmark so the UI stays in sync after a hotkey press.
    private func toggleBoostState() {
        let next = !boostEnabled()
        UserDefaults.standard.set(next, forKey: boostEnabledKey)
        boostMenuItem?.state = next ? .on : .off
    }

    /// Register ⌃⌥⌘B as a system-wide hotkey via Carbon's RegisterEventHotKey.
    /// Chosen over NSEvent.addGlobalMonitorForEvents because Carbon does NOT
    /// require Accessibility permission, and the registration survives
    /// focus changes — critical when the overlay has whited out the screen
    /// and no app can take focus to surface a permission prompt.
    private func registerBoostHotKey() {
        var handlerSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                        eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData = userData else { return noErr }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
                // Carbon's handler thread isn't guaranteed to be main; hop to
                // main before touching UserDefaults and the NSMenuItem state.
                DispatchQueue.main.async { delegate.toggleBoostState() }
                return noErr
            },
            1,
            &handlerSpec,
            selfPtr,
            &boostHotKeyHandler
        )
        guard installStatus == noErr else {
            NSLog("BrightXDR: InstallEventHandler failed (status=\(installStatus)) — hotkey unavailable")
            return
        }

        let modifiers = UInt32(controlKey | optionKey | cmdKey)
        let hotKeyID = EventHotKeyID(signature: OSType(0x4258_5252) /* 'BXRR' */, id: 1)
        let registerStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_B),
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &boostHotKeyRef
        )
        if registerStatus != noErr {
            NSLog("BrightXDR: RegisterEventHotKey failed (status=\(registerStatus)) — ⌃⌥⌘B may be claimed by another app")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let ref = boostHotKeyRef {
            UnregisterEventHotKey(ref)
            boostHotKeyRef = nil
        }
        if let handler = boostHotKeyHandler {
            RemoveEventHandler(handler)
            boostHotKeyHandler = nil
        }
    }

    private func currentBrightness() -> Float {
        let stored = UserDefaults.standard.float(forKey: brightnessValueKey)
        // UserDefaults.float returns 0 if unset; treat 0 as "never set" and
        // fall back to the default. (0 is a meaningless brightness anyway.)
        return stored == 0 ? brightnessDefault : stored
    }

    private func brightnessLabel(for value: Float) -> String {
        // Tick-snapped values are exact 0.10 multiples; one decimal place is enough.
        String(format: "Brightness: %.1f", value)
    }

    @objc private func brightnessChanged(_ sender: NSSlider) {
        let value = Float(sender.doubleValue)
        UserDefaults.standard.set(value, forKey: brightnessValueKey)
        brightnessLabelItem.title = brightnessLabel(for: value)
        metalView.setBrightness(value)
    }
}
