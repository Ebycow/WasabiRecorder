import AppKit
import CoreAudio
import Darwin

/// An app that owns one or more Core Audio process objects (helpers such as
/// WebKit's GPU process or Chrome Helper are folded into their parent app).
struct AudioApp: Identifiable {
    let id: pid_t
    let bundleID: String?
    let name: String
    let icon: NSImage
    var processObjectIDs: [AudioObjectID]
    var isPlaying: Bool

    func matches(_ identity: AppIdentity) -> Bool {
        if let bundleID, let other = identity.bundleID { return bundleID == other }
        return id == identity.pid
    }

    var identity: AppIdentity {
        AppIdentity(bundleID: bundleID, pid: id, name: name, icon: icon)
    }
}

/// What the user picked — survives the app's audio processes coming and going.
struct AppIdentity: Equatable {
    let bundleID: String?
    let pid: pid_t
    let name: String
    let icon: NSImage

    init(bundleID: String?, pid: pid_t, name: String, icon: NSImage) {
        self.bundleID = bundleID
        self.pid = pid
        self.name = name
        self.icon = icon
    }

    init?(bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        self.bundleID = bundleID
        self.pid = -1
        self.name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        self.icon = NSWorkspace.shared.icon(forFile: url.path)
    }
}

enum AudioApps {
    /// Snapshot of apps that currently have audio process objects. Cheap; only
    /// called on demand (opening the picker, starting a recording).
    @MainActor
    static func current() -> [AudioApp] {
        let objects = (try? AudioObjectID.system.getObjectList(kAudioHardwarePropertyProcessObjectList)) ?? []
        let me = getpid()
        var apps: [pid_t: AudioApp] = [:]

        for object in objects {
            let pid: pid_t = object.get(kAudioProcessPropertyPID, default: -1)
            guard pid > 0, pid != me, let owner = owningApp(of: pid), owner.processIdentifier != me else { continue }
            let playing: UInt32 = object.get(kAudioProcessPropertyIsRunningOutput, default: 0)
            let key = owner.processIdentifier

            if apps[key] == nil {
                apps[key] = AudioApp(
                    id: key,
                    bundleID: owner.bundleIdentifier,
                    name: owner.localizedName ?? owner.bundleIdentifier ?? "\(key)",
                    icon: owner.icon ?? NSWorkspace.shared.icon(for: .application),
                    processObjectIDs: [],
                    isPlaying: false
                )
            }
            apps[key]!.processObjectIDs.append(object)
            apps[key]!.isPlaying = apps[key]!.isPlaying || playing != 0
        }

        // Background agents (Control Center, Siri, …) only show up while they make sound.
        return apps.values.filter {
            $0.isPlaying || NSRunningApplication(processIdentifier: $0.id)?.activationPolicy == .regular
        }.sorted {
            if $0.isPlaying != $1.isPlaying { return $0.isPlaying }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    @MainActor
    private static func owningApp(of pid: pid_t) -> NSRunningApplication? {
        func userFacing(_ app: NSRunningApplication?) -> NSRunningApplication? {
            guard let app, app.activationPolicy != .prohibited else { return nil }
            return app
        }
        if let responsible = responsiblePID(for: pid), let app = userFacing(NSRunningApplication(processIdentifier: responsible)) {
            return app
        }
        if let app = userFacing(NSRunningApplication(processIdentifier: pid)) {
            return app
        }
        // Fall back to the outermost .app bundle that contains the executable.
        guard let path = executablePath(of: pid), let range = path.range(of: ".app/") else { return nil }
        let bundlePath = String(path[..<range.lowerBound]) + ".app"
        return NSWorkspace.shared.runningApplications.first { $0.bundleURL?.path == bundlePath }
    }

    private typealias ResponsibilityFunction = @convention(c) (pid_t) -> pid_t

    private static let responsibilityFunction: ResponsibilityFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        return unsafeBitCast(symbol, to: ResponsibilityFunction.self)
    }()

    private static func responsiblePID(for pid: pid_t) -> pid_t? {
        guard let function = responsibilityFunction else { return nil }
        let result = function(pid)
        return result > 0 ? result : nil
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}
