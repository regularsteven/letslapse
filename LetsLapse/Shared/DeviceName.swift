// The Watch never names itself to another device.
#if !os(watchOS)
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// What other devices, and PicPlace, call this one (docs/nearby-originals-plan.md
/// N5, Steven 2026-09-28).
///
/// A Mac has the computer name its owner gave it ("Steve's MacBook Pro"). An
/// iPhone or iPad does not, to an app: since iOS 16, `UIDevice.name` answers
/// the bare model word ("iPhone") unless Apple grants the
/// `user-assigned-device-name` entitlement. Two phones both called "iPhone"
/// are useless on *Import originals from …*, so the model stands in: "iPhone
/// 18 Pro", "iPad Air 13-inch (M3)". An identifier the table doesn't know keeps
/// the bare word — never a guess.
enum DeviceName {

    /// The name to show other devices.
    static var current: String {
        #if os(macOS)
        return Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #else
        let given = UIDevice.current.name
        let generic = given == UIDevice.current.model || given == UIDevice.current.localizedModel
        guard generic else { return given }
        return modelName(for: hardwareIdentifier) ?? given
        #endif
    }

    /// "iPhone19,2" — `hw.machine`; in the Simulator, the device it stands
    /// for ("iPhone18,1") rather than "arm64".
    static var hardwareIdentifier: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var info = utsname()
        uname(&info)
        return withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }

    /// The model's marketing name, as `devicectl list devices` reports it,
    /// or nil for an identifier not in the table.
    static func modelName(for identifier: String) -> String? {
        models[identifier]
    }

    /// Identifier → marketing name. The bench's own devices were read off
    /// `devicectl list devices` (2026-09-28): iPhone12 Pro `iPhone13,3`,
    /// 16 Pro `iPhone17,1`, 18 Pro `iPhone19,2`, iPad Air (5th generation)
    /// `iPad13,16`, iPad Air 13-inch (M3) `iPad15,5`. Add a model when one
    /// shows up as its bare word.
    private static let models: [String: String] = [
        // iPhone
        "iPhone12,1": "iPhone 11", "iPhone12,3": "iPhone 11 Pro", "iPhone12,5": "iPhone 11 Pro Max",
        "iPhone12,8": "iPhone SE (2nd generation)",
        "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12", "iPhone13,3": "iPhone 12 Pro",
        "iPhone13,4": "iPhone 12 Pro Max",
        "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13", "iPhone14,2": "iPhone 13 Pro",
        "iPhone14,3": "iPhone 13 Pro Max", "iPhone14,6": "iPhone SE (3rd generation)",
        "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus",
        "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
        "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus",
        "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
        "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max", "iPhone17,3": "iPhone 16",
        "iPhone17,4": "iPhone 16 Plus", "iPhone17,5": "iPhone 16e",
        "iPhone18,1": "iPhone 17 Pro", "iPhone18,2": "iPhone 17 Pro Max", "iPhone18,3": "iPhone 17",
        "iPhone18,4": "iPhone Air",
        "iPhone19,2": "iPhone 18 Pro",
        // iPad
        "iPad12,1": "iPad (9th generation)", "iPad12,2": "iPad (9th generation)",
        "iPad13,18": "iPad (10th generation)", "iPad13,19": "iPad (10th generation)",
        "iPad15,7": "iPad (A16)", "iPad15,8": "iPad (A16)",
        "iPad13,1": "iPad Air (4th generation)", "iPad13,2": "iPad Air (4th generation)",
        "iPad13,16": "iPad Air (5th generation)", "iPad13,17": "iPad Air (5th generation)",
        "iPad14,8": "iPad Air 11-inch (M2)", "iPad14,9": "iPad Air 11-inch (M2)",
        "iPad14,10": "iPad Air 13-inch (M2)", "iPad14,11": "iPad Air 13-inch (M2)",
        "iPad15,3": "iPad Air 11-inch (M3)", "iPad15,4": "iPad Air 11-inch (M3)",
        "iPad15,5": "iPad Air 13-inch (M3)", "iPad15,6": "iPad Air 13-inch (M3)",
        "iPad14,1": "iPad mini (6th generation)", "iPad14,2": "iPad mini (6th generation)",
        "iPad16,1": "iPad mini (A17 Pro)", "iPad16,2": "iPad mini (A17 Pro)",
        "iPad13,4": "iPad Pro 11-inch (3rd generation)", "iPad13,5": "iPad Pro 11-inch (3rd generation)",
        "iPad13,6": "iPad Pro 11-inch (3rd generation)", "iPad13,7": "iPad Pro 11-inch (3rd generation)",
        "iPad13,8": "iPad Pro 12.9-inch (5th generation)", "iPad13,9": "iPad Pro 12.9-inch (5th generation)",
        "iPad13,10": "iPad Pro 12.9-inch (5th generation)", "iPad13,11": "iPad Pro 12.9-inch (5th generation)",
        "iPad14,3": "iPad Pro 11-inch (4th generation)", "iPad14,4": "iPad Pro 11-inch (4th generation)",
        "iPad14,5": "iPad Pro 12.9-inch (6th generation)", "iPad14,6": "iPad Pro 12.9-inch (6th generation)",
        "iPad16,3": "iPad Pro 11-inch (M4)", "iPad16,4": "iPad Pro 11-inch (M4)",
        "iPad16,5": "iPad Pro 13-inch (M4)", "iPad16,6": "iPad Pro 13-inch (M4)",
        "iPad17,1": "iPad Pro 11-inch (M5)", "iPad17,2": "iPad Pro 11-inch (M5)",
        "iPad17,3": "iPad Pro 13-inch (M5)", "iPad17,4": "iPad Pro 13-inch (M5)",
    ]
}
#endif
