import AppKit

// Loads the bundled SVG icons. They're shipped as Resources via SwiftPM
// (`resources: [.process("Resources")]` in Package.swift), and the SVGs are
// monochrome so we mark them as `isTemplate = true` — AppKit auto-tints them
// to match the menu bar appearance (light/dark mode).

enum Icon: String {
    case heart      = "heart"
    case heartFill  = "heart.fill"
    case battery0   = "battery.0percent"
    case battery25  = "battery.25percent"
    case battery50  = "battery.50percent"
    case battery75  = "battery.75percent"
    case battery100 = "battery.100percent"
    case device     = "beats.powerbeats.pro.2"

    /// Pick the battery icon for a given percent (rounds to nearest bucket).
    static func battery(forLevel pct: Int) -> Icon {
        switch pct {
        case ...12:  return .battery0
        case 13...37: return .battery25
        case 38...62: return .battery50
        case 63...87: return .battery75
        default:      return .battery100
        }
    }
}

extension NSImage {
    /// Loads `<name>.svg` from the bundle, sized for the menu bar, marked as a template.
    static func icon(_ icon: Icon, height: CGFloat = 14) -> NSImage? {
        guard let url = Bundle.module.url(forResource: icon.rawValue, withExtension: "svg"),
              let img = NSImage(contentsOf: url) else { return nil }
        let aspect = img.size.width / max(img.size.height, 1)
        img.size = NSSize(width: height * aspect, height: height)
        img.isTemplate = true
        return img
    }

    /// Returns a copy of the image rotated counter-clockwise by `degrees`.
    /// Preserves template-image status so menu-bar tinting still works.
    func rotated(byDegrees degrees: CGFloat) -> NSImage {
        let radians = degrees * .pi / 180
        let s = self.size
        let rotatedSize = NSSize(
            width: abs(s.width * cos(radians)) + abs(s.height * sin(radians)),
            height: abs(s.width * sin(radians)) + abs(s.height * cos(radians))
        )
        let result = NSImage(size: rotatedSize)
        result.lockFocus()
        let t = NSAffineTransform()
        t.translateX(by: rotatedSize.width / 2, yBy: rotatedSize.height / 2)
        t.rotate(byDegrees: degrees)
        t.translateX(by: -s.width / 2, yBy: -s.height / 2)
        t.concat()
        self.draw(at: .zero, from: NSRect(origin: .zero, size: s),
                  operation: .sourceOver, fraction: 1.0)
        result.unlockFocus()
        result.isTemplate = self.isTemplate
        return result
    }
}
