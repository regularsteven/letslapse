import Foundation
import VideoToolbox
var list: CFArray?
VTCopyVideoEncoderList(nil, &list)
let arr = list as! [[String: Any]]
print("encoders:", arr.count)
for e in arr {
    let ct = e["CodecType"] as? Int32 ?? 0
    let fourcc = String(UnicodeScalar(UInt8((ct >> 24) & 0xff))) + String(UnicodeScalar(UInt8((ct >> 16) & 0xff))) + String(UnicodeScalar(UInt8((ct >> 8) & 0xff))) + String(UnicodeScalar(UInt8(ct & 0xff)))
    let name = e["EncoderName"] as? String ?? "?"
    print(fourcc, "|", name, "| hw:", e["IsHardwareAccelerated"] as? Bool ?? false)
}
