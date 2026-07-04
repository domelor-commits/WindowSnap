import Cocoa

/// Computes target frames within a screen's visible area.
enum SnapRegion: String, CaseIterable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case leftThird, centerThird, rightThird
    case maximize, center

    func frame(in v: CGRect) -> CGRect {
        let w = v.width, h = v.height, x = v.minX, y = v.minY
        switch self {
        case .leftHalf:     return CGRect(x: x,         y: y,         width: w/2, height: h)
        case .rightHalf:    return CGRect(x: x + w/2,   y: y,         width: w/2, height: h)
        case .topHalf:      return CGRect(x: x,         y: y,         width: w,   height: h/2)
        case .bottomHalf:   return CGRect(x: x,         y: y + h/2,   width: w,   height: h/2)
        case .topLeft:      return CGRect(x: x,         y: y,         width: w/2, height: h/2)
        case .topRight:     return CGRect(x: x + w/2,   y: y,         width: w/2, height: h/2)
        case .bottomLeft:   return CGRect(x: x,         y: y + h/2,   width: w/2, height: h/2)
        case .bottomRight:  return CGRect(x: x + w/2,   y: y + h/2,   width: w/2, height: h/2)
        case .leftThird:    return CGRect(x: x,         y: y,         width: w/3, height: h)
        case .centerThird:  return CGRect(x: x + w/3,   y: y,         width: w/3, height: h)
        case .rightThird:   return CGRect(x: x + 2*w/3, y: y,         width: w/3, height: h)
        case .maximize:     return v
        case .center:       return CGRect(x: x + w/4,   y: y + h/4,   width: w/2, height: h/2)
        }
    }
}
