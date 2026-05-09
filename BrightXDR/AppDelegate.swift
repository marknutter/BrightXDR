//
//  AppDelegate.swift
//  BrightXDR
//
//  Created by Dmitry Starkov on 31/03/2023.
//

import Cocoa

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

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        installStatusItem()
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
        metalView = MetalView(frame: view.bounds, frameRate: 3, contrast: 1.0, brightness: currentBrightness())
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

        boostMenuItem = NSMenuItem(title: "Boost", action: #selector(toggleBoost(_:)), keyEquivalent: "")
        boostMenuItem.target = self
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
        let next = !boostEnabled()
        UserDefaults.standard.set(next, forKey: boostEnabledKey)
        sender.state = next ? .on : .off
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
