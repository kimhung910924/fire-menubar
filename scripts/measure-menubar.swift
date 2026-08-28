import Cocoa
for s in NSScreen.screens {
    print("SCREEN frame=\(s.frame) visible=\(s.visibleFrame) notchTL=\(String(describing: s.auxiliaryTopLeftArea)) notchTR=\(String(describing: s.auxiliaryTopRightArea))")
}
let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
var rows: [(CGFloat, String)] = []
for w in info {
    guard let layer = w[kCGWindowLayer as String] as? Int, layer == 25 else { continue }
    guard let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
    let name = (w[kCGWindowName as String] as? String) ?? "(no-name)"
    let num = (w[kCGWindowNumber as String] as? Int) ?? -1
    rows.append((b["X"]!, "x=\(Int(b["X"]!)) y=\(Int(b["Y"]!)) w=\(Int(b["Width"]!)) win=\(num) name=\(name)"))
}
print("--- layer25 status items: \(rows.count) ---")
for r in rows.sorted(by: { $0.0 < $1.0 }) { print(r.1) }
