import Foundation

/// This install's identity — the `deviceID` every sync-ready record names
/// as its `originDeviceID` / `modifiedBy` / `deletedBy`
/// (docs/data-model-phase1-spec-2026-09-12.md W2; Part 3 §10.6's "device"
/// identity, the first of three).
///
/// Minted once, on first access, into `UserDefaults` under
/// `letslapse.deviceID`, and never changed: the id names the install, not
/// the hardware, and it has to stay put across launches for the records
/// that carry it to mean anything. Known consequence on the Mac: the
/// unsandboxed Debug build and a sandboxed build read different preference
/// domains (Part 1 R7) and so hold different ids — they are different
/// installs, and that is the honest answer.
///
/// In Shared/ so the Watch app, which persists nothing but one default, can
/// name itself the same way if it ever needs to.
enum DeviceIdentity {

    /// The `UserDefaults` key — Part 1 Appendix B row 84.
    static let defaultsKey = "letslapse.deviceID"

    /// The per-install id. Read from the defaults on first use; minted and
    /// written when absent or unparseable.
    static let id: UUID = {
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: defaultsKey), let id = UUID(uuidString: stored) {
            return id
        }
        let minted = UUID()
        defaults.set(minted.uuidString, forKey: defaultsKey)
        return minted
    }()
}
