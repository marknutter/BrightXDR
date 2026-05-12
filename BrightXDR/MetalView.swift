//
//  MetalView.swift
//  BrightXDR
//
//  Created by Dmitry Starkov on 28/03/2023.
//

import Cocoa
import MetalKit

// Metal view displaying static HDR content to enable EDR display mode
class MetalView: MTKView, MTKViewDelegate {
    private let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
    private var contrast: Float // values from 1.0 to 3.0, where 1.0 is optimal
    private var brightness: Float // values from 0.0 to 3.0, where 1.0 is optimal

    private var commandQueue: MTLCommandQueue?
    private var renderContext: CIContext?

    private var image: CIImage?
    private var colorControlsFilter: CIFilter?

    // Manual override: when true, the capturing auto-suppress is bypassed.
    // Set by AppDelegate when the user explicitly toggles Boost ON. Cleared
    // automatically the next draw cycle that observes capturing == false, so
    // the next genuine capture is suppressed normally. Recovery path for #8
    // (screencaptureui leaves a large drag-image window resident after the
    // user drags the screenshot thumbnail onto another app).
    private var captureOverrideActive = false

    // Tracks the last capturing-state observation so we only NSLog on
    // transitions, not every draw frame at 30fps. Used by the diagnostic
    // log path in isScreencaptureuiShowingInteractiveUI().
    private var lastLoggedCapturing: Bool?

    /// Public initializer
    /// - frameRate: lower the frame rate for better perfomance, otherwise the screen frame rate is used (probably 120)
    /// - contrast: value use by `CIColorControls` `CIFilter`
    /// - brightness: value use by `CIColorControls` `CIFilter`
    init(frame: CGRect, frameRate: Int? = nil, contrast: Float = 1.0, brightness: Float = 1.0) {
        self.contrast = contrast
        self.brightness = brightness
        super.init(frame: frame, device: MTLCreateSystemDefaultDevice())

        if let device = self.device {
            self.commandQueue = device.makeCommandQueue()

            // Create a CIContext for rendering a CIImage to a destination using Metal
            if let commandQueue = self.commandQueue {
                self.renderContext = CIContext(mtlCommandQueue: commandQueue, options: [
                    .name: "BrightXDRContext",
                    .workingColorSpace: colorSpace ?? CGColorSpace.extendedLinearSRGB,
                    .workingFormat: CIFormat.RGBAf,
                    .cacheIntermediates: true,
                    .allowLowPower: false,
                ])
            }
        }
        self.delegate = self

        // Allow the view to display its contents outside of the framebuffer and bind the delegate to the coordinator
        self.framebufferOnly = false
        // Update FPS (matter only on space switching or on/off HDR brightness mode)
        if let frameRate = frameRate {
            self.preferredFramesPerSecond = frameRate
        } else {
            if #available(macOS 12.0, *) {
                self.preferredFramesPerSecond = NSScreen.main?.maximumFramesPerSecond ?? 120
            } else {
                self.preferredFramesPerSecond = 120
            }
        }
        // Enable EDR
        self.colorPixelFormat = .rgba16Float
        self.colorspace = colorSpace
        if let layer = self.layer as? CAMetalLayer {
            layer.wantsExtendedDynamicRangeContent = true
            layer.isOpaque = false

            // Blend EDR layer with background
            layer.compositingFilter = "multiplyBlendMode"
        }
        // Initialize color filter for brightness adjustment. Retain it on
        // the instance so setBrightness(_:) can re-tune it at runtime.
        guard let filter = CIFilter(name: "CIColorControls") else { return }
        filter.setValue(contrast, forKey: kCIInputContrastKey) // default to 1.0
        filter.setValue(brightness, forKey: kCIInputBrightnessKey) // default to 0.0
        self.colorControlsFilter = filter
        let colorControlsFilter = filter

        // Transparent color in EDR color space
        guard let colorSpace = colorSpace, let color = CIColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0, colorSpace: colorSpace),
              let cgColor = CGColor(colorSpace: colorSpace, components: [1.0, 1.0, 1.0, 1.0]) else {
            return
        }

        // Text overlay
        var preview: CIImage?

        // Preview data
        let textLayer = CATextLayer()
        textLayer.string = "Bright XDR"
        textLayer.font = NSFont.boldSystemFont(ofSize: 16) // fontSize ignored
        textLayer.fontSize = 136
        textLayer.foregroundColor = cgColor
        //textLayer.contentsScale = screenScale

        // Calculate text size and position
        let textLayerSize = textLayer.preferredFrameSize()
        textLayer.frame = CGRect(x: 0, y: 0, width: textLayerSize.width, height: textLayerSize.height)
        textLayer.position = CGPoint(x: bounds.width / 2, y: bounds.height / 2)

        // Render text layer on NSImage
        let textImage = NSImage(size: bounds.size)
        textImage.lockFocus()
        if let current = NSGraphicsContext.current {
            let context = current.cgContext
            // Center text
            context.translateBy(x: bounds.width / 2 - textLayerSize.width / 2, y: bounds.height / 2 - textLayerSize.height / 2)
            textLayer.render(in: context)
            textImage.unlockFocus()
            // Convert to CIImage
            if let cgImage = textImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                // Apply color filter
                colorControlsFilter.setValue(CIImage(cgImage: cgImage), forKey: kCIInputImageKey)
                if let image = colorControlsFilter.outputImage {
                    // Save preview image
                    preview = image
                }
            }
        }

        // Solid transparent
        var transparent: CIImage?
        // Apply color filter
        colorControlsFilter.setValue(CIImage(color: color), forKey: kCIInputImageKey)
        if let image = colorControlsFilter.outputImage {
            // Save main image
            transparent = image
        }

        // Set global image
        if (preview != nil) {
            self.image = preview
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                // Hide app preview
                self.image = transparent
            }
        } else {
            self.image = transparent
        }
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func draw(in view: MTKView) {
        // Hide the overlay when:
        //  1. The user has flipped Boost off (menu toggle or ⌃⌥⌘B global
        //     hotkey). Manual escape hatch for HDR-rendering apps (QuickTime
        //     HDR video, browser HDR, Photos with HDR images) and screen-
        //     sharing apps (Teams/Zoom) where the multiply-blend overlay
        //     washes the content out.
        //  2. macOS's screencaptureui is showing interactive capture UI —
        //     the cmd-shift-4 selection rect, the cmd-shift-5 panel, or a
        //     recording session. The multiply-blend overlay otherwise
        //     saturates the live display to white during these.
        //
        //     Note: the lingering screenshot thumbnail preview ALSO keeps
        //     screencaptureui resident (up to ~5s after a screenshot, or
        //     indefinitely if user ignores it). Process-presence alone
        //     over-suppresses for that thumbnail — see #5. We check window
        //     bounds instead to filter the thumbnail out.
        let userEnabled = (UserDefaults.standard.object(forKey: boostEnabledKey) as? Bool) ?? true
        let capturing = isScreencaptureuiShowingInteractiveUI()
        // Auto-clear the manual override once the stuck capturing condition
        // resolves, so the next real capture is suppressed normally.
        if !capturing && captureOverrideActive {
            captureOverrideActive = false
        }
        let suppress = !userEnabled || (capturing && !captureOverrideActive)
        let targetAlpha: CGFloat = suppress ? 0.0 : 1.0
        if window?.alphaValue != targetAlpha {
            window?.alphaValue = targetAlpha
        }
        // Don't short-circuit the render when suppressed: keep presenting
        // drawables so macOS keeps EDR mode engaged on this layer. If we stop
        // presenting, EDR de-engages and takes ~0.5–2s to ramp back up the
        // moment alpha returns to 1 — visible as a "screen takes a beat to
        // brighten after the screenshot thumbnail dismisses" lag.
        // The window's alphaValue=0 makes the rendered output invisible, so
        // there's no user-facing cost to rendering through suppression.

        // Verify transparent image was rendered
        guard let image = image, let colorSpace = colorSpace else { return  }

        // Check Metal device was initialized correctly
        guard let commandQueue = commandQueue, let renderContext = renderContext else { return }

        // Create a new command buffer and get the drawable object to render into
        guard let commandBuffer = commandQueue.makeCommandBuffer(), let drawable = currentDrawable else { return }

        // Render the CIImage
        renderContext.render(image, to: drawable.texture, commandBuffer: commandBuffer, bounds: CGRect(origin: CGPoint.zero, size: drawableSize), colorSpace: colorSpace)

        // Present the drawable to the screen
        commandBuffer.present(drawable)

        // Commit the command buffer for execution on the GPU
        commandBuffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { }

    /// True only when screencaptureui owns at least one on-screen window
    /// larger than the screenshot thumbnail preview (~140×100). The
    /// interactive capture UI (selection rect, cmd-shift-5 panel, recording
    /// session) is always much larger, so a 200px threshold cleanly
    /// separates "actively capturing" from "thumbnail still lingering."
    ///
    /// Uses CGWindowListCopyWindowInfo with bounds + ownerPID only — no
    /// window titles — so it works without Screen Recording / Screen Capture
    /// TCC permission on macOS 13+.
    private func isScreencaptureuiShowingInteractiveUI() -> Bool {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.screencaptureui"
        }) else { return false }
        let capturePID = app.processIdentifier

        guard let entries = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            // If the enumeration fails for any reason, fall back to the old
            // process-presence behavior so the user is never stuck with a
            // whited-out screen during a real capture.
            return true
        }

        let thumbnailMaxDimension: CGFloat = 200
        var matching: [(bounds: CGRect, layer: Int, alpha: Double)] = []
        for entry in entries {
            guard let ownerPID = entry[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == capturePID,
                  let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }
            if bounds.width > thumbnailMaxDimension || bounds.height > thumbnailMaxDimension {
                let layer = (entry[kCGWindowLayer as String] as? Int) ?? 0
                let alpha = (entry[kCGWindowAlpha as String] as? Double) ?? 1.0
                matching.append((bounds, layer, alpha))
            }
        }
        let isCapturing = !matching.isEmpty
        // Log on state transition only (not every 30fps draw). Captures the
        // bounds/layer/alpha of every screencaptureui window large enough to
        // trigger suppression — diagnostic for #8 follow-up to refine the
        // detector. Pipe Console.app filter: "BrightXDR".
        if lastLoggedCapturing != isCapturing {
            if isCapturing {
                let descriptions = matching.map { m in
                    String(format: "{x=%.0f y=%.0f w=%.0f h=%.0f layer=%d alpha=%.2f}",
                           m.bounds.origin.x, m.bounds.origin.y, m.bounds.width, m.bounds.height,
                           m.layer, m.alpha)
                }.joined(separator: ", ")
                NSLog("BrightXDR: screencaptureui detected (suppressing). matching windows: \(descriptions)")
            } else {
                NSLog("BrightXDR: screencaptureui cleared (resuming)")
            }
            lastLoggedCapturing = isCapturing
        }
        return isCapturing
    }

    /// Engage or release the manual capture-detection override.
    /// Engaging makes the next draw cycle treat `capturing` as harmless until
    /// the stuck condition naturally clears. Wired to the Boost toggle so the
    /// user has a single, predictable recovery action: re-toggle Boost.
    func setCaptureOverride(_ active: Bool) {
        captureOverrideActive = active
    }

    /// Re-tune the brightness multiplier without rebuilding the view.
    /// Re-renders the static white CIImage through the same CIColorControls
    /// filter with the new value so the next draw cycle picks it up.
    func setBrightness(_ value: Float) {
        self.brightness = value
        guard let filter = colorControlsFilter,
              let cs = colorSpace,
              let color = CIColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0, colorSpace: cs)
        else { return }
        filter.setValue(value, forKey: kCIInputBrightnessKey)
        filter.setValue(CIImage(color: color), forKey: kCIInputImageKey)
        if let output = filter.outputImage {
            self.image = output
        }
    }
}
