import Foundation

/// SwarfPath was called Swarf (bundle id io.github.swarfcam.Swarf). The first time SwarfPath runs on
/// a Mac that ran Swarf, bring its settings (machine, material, quality, SwarfGRBL address) and its
/// tool library across. Projects (.swarf files) open as before.
enum Migration {
    static let oldBundleId = "io.github.swarfcam.Swarf"
    static let doneKey = "migratedFromSwarf"

    static func run() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: doneKey), Bundle.main.bundleIdentifier != oldBundleId else { return }
        if let old = d.persistentDomain(forName: oldBundleId) {
            for (k, v) in old where d.object(forKey: k) == nil { d.set(v, forKey: k) }
        }
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let from = support.appendingPathComponent("Swarf"), to = support.appendingPathComponent("SwarfPath")
        if fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) { try? fm.moveItem(at: from, to: to) }
        d.set(true, forKey: doneKey)
    }
}
