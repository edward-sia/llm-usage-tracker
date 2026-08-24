import AppKit

/// The Anthropic and OpenRouter logomarks for the menu bar title.
///
/// The vector data is embedded as SVG strings because the .app wrapper copies only the bare
/// executable (see scripts/bundle-app.sh), so there is no resource bundle to load from.
/// Path data comes from Simple Icons (https://simpleicons.org, released under CC0); the
/// marks themselves belong to Anthropic and OpenRouter.
enum ProviderIcons {
    static let pointSize: CGFloat = 13

    /// Fresh instances per call: the images resolve `labelColor` when first drawn, and the
    /// caller re-requests them on every render (and on appearance changes) so a cached
    /// rasterization from the other appearance never lingers.
    static func anthropic() -> NSImage { image(svg: anthropicSVG) }
    static func openRouter() -> NSImage { image(svg: openRouterSVG) }

    /// A neutral gauge glyph for when every provider is hidden, so the status item keeps a
    /// clickable footprint.
    static func hiddenPlaceholder() -> NSImage? {
        NSImage(systemSymbolName: "gauge", accessibilityDescription: "Usage hidden").map(tinted)
    }

    private static let anthropicSVG = """
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="M17.3041 3.541h-3.6718l6.696 16.918H24Zm-10.6082 0L0 20.459h3.7442l1.3693-3.5527h7.0052l1.3693 3.5528h3.7442L10.5363 3.5409Zm-.3712 10.2232 2.2914-5.9456 2.2914 5.9456Z"/></svg>
        """

    private static let openRouterSVG = """
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="M16.778 1.844v1.919q-.569-.026-1.138-.032-.708-.008-1.415.037c-1.93.126-4.023.728-6.149 2.237-2.911 2.066-2.731 1.95-4.14 2.75-.396.223-1.342.574-2.185.798-.841.225-1.753.333-1.751.333v4.229s.768.108 1.61.333c.842.224 1.789.575 2.185.799 1.41.798 1.228.683 4.14 2.75 2.126 1.509 4.22 2.11 6.148 2.236.88.058 1.716.041 2.555.005v1.918l7.222-4.168-7.222-4.17v2.176c-.86.038-1.611.065-2.278.021-1.364-.09-2.417-.357-3.979-1.465-2.244-1.593-2.866-2.027-3.68-2.508.889-.518 1.449-.906 3.822-2.59 1.56-1.109 2.614-1.377 3.978-1.466.667-.044 1.418-.017 2.278.02v2.176L24 6.014Z"/></svg>
        """

    private static func image(svg: String) -> NSImage {
        guard let base = NSImage(data: Data(svg.utf8)) else {
            return NSImage(size: NSSize(width: pointSize, height: pointSize))
        }
        return tinted(base)
    }

    /// Draws the base image tinted with `labelColor` at draw time, so the icon follows the
    /// menu bar's light/dark appearance the way a template image would. (Template tinting
    /// itself only applies to a button's `image`, not to images inside an attributed title.)
    private static func tinted(_ base: NSImage) -> NSImage {
        let side = pointSize
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            base.draw(in: rect)
            NSColor.labelColor.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}
