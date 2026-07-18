import Cocoa

// MARK: - Annotation model

enum AnnoTool: Int, CaseIterable {
    case arrow, box, oval, line, pen, highlight, text, blur

    var symbol: String {
        switch self {
        case .arrow: return "arrow.up.right"
        case .box: return "rectangle"
        case .oval: return "circle"
        case .line: return "line.diagonal"
        case .pen: return "scribble.variable"
        case .highlight: return "highlighter"
        case .text: return "character"
        case .blur: return "square.grid.3x3.fill"
        }
    }
    var tip: String {
        switch self {
        case .arrow: return "Arrow"; case .box: return "Box"; case .oval: return "Oval"
        case .line: return "Line"; case .pen: return "Pen"; case .highlight: return "Highlighter"
        case .text: return "Text"; case .blur: return "Blur / pixelate"
        }
    }
}

struct AnnoShape {
    var tool: AnnoTool
    var a: CGPoint                  // start, in canvas pixels (top-left origin)
    var b: CGPoint                  // end
    var points: [CGPoint] = []      // pen / highlighter path
    var color: NSColor
    var width: CGFloat              // stroke width in canvas pixels
    var text: String = ""
    var fontName: String = ""       // "" = bold system font
    var pixelated: NSImage? = nil   // cached patch for the blur tool
    var image: NSImage? = nil       // payload for .imageOverlay
    var isBase: Bool = false        // the original screenshot (shapes[0])
}

extension AnnoShape {
    // A dropped/base image uses .box geometry for hit/handles but draws an image.
    var isImage: Bool { image != nil }
}
