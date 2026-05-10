import AppKit
import SwiftUI

/// Renders progress on the macOS Dock tile during backups.
@MainActor
final class DockProgress {

    static let shared = DockProgress()

    private let tile = NSApp.dockTile
    private var contentView: NSView?

    /// Set progress from 0.0 (none) to 1.0 (complete). Pass nil to clear.
    func update(progress: Double?, badge: String? = nil) {
        if let progress {
            installContentView()
            (contentView as? DockProgressView)?.progress = max(0, min(1, progress))
            tile.badgeLabel = badge ?? "\(Int(progress * 100))%"
        } else {
            removeContentView()
            tile.badgeLabel = nil
        }
        tile.display()
    }

    /// Show only a badge label without a progress ring.
    func setBadge(_ label: String?) {
        tile.badgeLabel = label
        tile.display()
    }

    /// Bounce the dock icon once (e.g., on completion).
    func bounce() {
        NSApp.requestUserAttention(.informationalRequest)
    }

    // MARK: - Internal

    private func installContentView() {
        if contentView == nil {
            let v = DockProgressView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
            tile.contentView = v
            contentView = v
        }
    }

    private func removeContentView() {
        tile.contentView = nil
        contentView = nil
    }
}

// MARK: - Custom NSView for Dock Tile

private final class DockProgressView: NSView {
    var progress: Double = 0 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        // Draw the original app icon as the base
        if let icon = NSApp.applicationIconImage {
            icon.draw(in: bounds)
        }

        // Overlay progress arc near the bottom of the icon
        let inset: CGFloat = 8
        let barHeight: CGFloat = 14
        let barRect = NSRect(
            x: bounds.minX + inset,
            y: bounds.minY + inset,
            width: bounds.width - 2 * inset,
            height: barHeight
        )

        // Background pill
        let bgPath = NSBezierPath(roundedRect: barRect,
                                   xRadius: barHeight / 2,
                                   yRadius: barHeight / 2)
        NSColor(white: 0, alpha: 0.55).setFill()
        bgPath.fill()

        // Foreground fill
        let fillWidth = max(barHeight, barRect.width * CGFloat(progress))
        let fgRect = NSRect(x: barRect.minX,
                            y: barRect.minY,
                            width: fillWidth,
                            height: barHeight)
        let fgPath = NSBezierPath(roundedRect: fgRect,
                                   xRadius: barHeight / 2,
                                   yRadius: barHeight / 2)
        // Vibrant blue gradient
        let gradient = NSGradient(colors: [
            NSColor(red: 0.31, green: 0.56, blue: 0.97, alpha: 1.0),
            NSColor(red: 0.24, green: 0.48, blue: 0.91, alpha: 1.0)
        ])
        gradient?.draw(in: fgPath, angle: 90)

        // Stroke for crispness
        NSColor.white.withAlphaComponent(0.25).setStroke()
        bgPath.lineWidth = 1
        bgPath.stroke()
    }
}
