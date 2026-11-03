import CoreGraphics
import Foundation

// Prints the CGWindowID of the Molly Settings window. Window titles need Screen
// Recording permission, so fall back to the largest on-screen Molly window.
let title = CommandLine.arguments.dropFirst().first ?? "Molly Settings"
let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let windows = (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]) ?? []
let mine = windows.filter {
    ($0[kCGWindowOwnerName as String] as? String)?.lowercased() == "molly"
        && ($0[kCGWindowLayer as String] as? Int) == 0
}

func area(_ window: [String: Any]) -> Double {
    let bounds = window[kCGWindowBounds as String] as? [String: Double] ?? [:]
    return (bounds["Width"] ?? 0) * (bounds["Height"] ?? 0)
}

let titled = mine.first { ($0[kCGWindowName as String] as? String) == title }
guard let found = titled ?? mine.max(by: { area($0) < area($1) }),
      let id = found[kCGWindowNumber as String] as? Int else {
    exit(1)
}
print(id)
