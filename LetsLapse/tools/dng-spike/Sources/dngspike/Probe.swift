import Foundation
import LetsLapseKit

enum ProbeCommand {
    static func run(json: Bool) {
        let report = DNGCapabilityProbe.run(tryJPEGXLSession: true)
        if json {
            print(DNGCapabilityProbe.json(report))
        } else {
            print(DNGCapabilityProbe.text(report))
            print("  third-party   \(JXLEncoder.version) · LibRaw \(LibRawDecoder.version)")
        }
    }
}
