import Foundation

enum UninstallError: LocalizedError {
    case applicationNotFound
    case invalidApplication
    case runningFromDiskImage
    case cannotMoveToTrash(String)

    var errorDescription: String? {
        switch self {
        case .applicationNotFound:
            "没有找到可卸载的智连应用，请先将智连安装到“应用程序”文件夹"
        case .invalidApplication:
            "卸载目标不是有效的智连应用"
        case .runningFromDiskImage:
            "当前智连正在安装镜像中运行。请先将智连安装到“应用程序”，推出 DMG，再从“应用程序”打开后卸载"
        case .cannotMoveToTrash(let reason):
            "无法将智连移入废纸篓：\(reason)"
        }
    }
}

/// Performs the parts of uninstall that Finder cannot do when an app bundle is
/// merely dragged to Trash: remove private data, unregister duplicate bundles,
/// and purge only Zhilian's stale Launchpad row without resetting user layout.
enum UninstallService {
    static let bundleIdentifier = "app.zhilian.native"

    struct Result {
        var trashedApplication: URL
        var cleanupFailures: [String]
    }

    static func perform(runningApplicationURL: URL) throws -> Result {
        let applicationURL = try uninstallTarget(runningApplicationURL: runningApplicationURL)
        unregisterApplication(at: applicationURL)

        var resultingURL: NSURL?
        do {
            try FileManager.default.trashItem(at: applicationURL, resultingItemURL: &resultingURL)
        } catch {
            throw UninstallError.cannotMoveToTrash(error.localizedDescription)
        }
        let trashedURL = (resultingURL as URL?) ?? applicationURL
        unregisterApplication(at: trashedURL)

        let failures = removeUserData()
        detachMountedInstallers()
        removeLaunchpadRecord()
        _ = run("/usr/bin/killall", ["Dock"])
        return .init(trashedApplication: trashedURL, cleanupFailures: failures)
    }

    private static func uninstallTarget(runningApplicationURL: URL) throws -> URL {
        let manager = FileManager.default
        if runningApplicationURL.path.hasPrefix("/Volumes/") {
            throw UninstallError.runningFromDiskImage
        }
        let installedURL = URL(fileURLWithPath: "/Applications/智连.app", isDirectory: true)
        // Prefer the installed copy when the user opened Zhilian from a DMG.
        // A read-only mounted image cannot be moved to Trash and remains
        // visible only until the image is ejected.
        let candidates = [installedURL, runningApplicationURL]
        for candidate in candidates where manager.fileExists(atPath: candidate.path) {
            guard candidate.pathExtension.caseInsensitiveCompare("app") == .orderedSame else { continue }
            guard !candidate.path.hasPrefix("/Volumes/") else { continue }
            if Bundle(url: candidate)?.bundleIdentifier == bundleIdentifier { return candidate }
        }
        if manager.fileExists(atPath: installedURL.path) { throw UninstallError.invalidApplication }
        throw UninstallError.applicationNotFound
    }

    private static func removeUserData() -> [String] {
        let manager = FileManager.default
        let library = manager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let targets = [
            library.appendingPathComponent("Application Support/ZhilianNative", isDirectory: true),
            library.appendingPathComponent("Caches/\(bundleIdentifier)", isDirectory: true),
            library.appendingPathComponent("Preferences/\(bundleIdentifier).plist"),
            library.appendingPathComponent("Saved Application State/\(bundleIdentifier).savedState", isDirectory: true),
            library.appendingPathComponent("HTTPStorages/\(bundleIdentifier)", isDirectory: true),
            library.appendingPathComponent("WebKit/\(bundleIdentifier)", isDirectory: true),
            library.appendingPathComponent("Containers/\(bundleIdentifier)", isDirectory: true)
        ]
        UserDefaults.standard.removePersistentDomain(forName: bundleIdentifier)
        var failures: [String] = []
        for target in targets where manager.fileExists(atPath: target.path) {
            do { try manager.removeItem(at: target) }
            catch { failures.append(target.path) }
        }

        let reports = library.appendingPathComponent("Logs/DiagnosticReports", isDirectory: true)
        if let entries = try? manager.contentsOfDirectory(at: reports, includingPropertiesForKeys: nil) {
            for entry in entries {
                let name = entry.lastPathComponent
                guard name.hasPrefix("Zhilian-") || name.hasPrefix("智连-") else { continue }
                do { try manager.removeItem(at: entry) }
                catch { failures.append(entry.path) }
            }
        }
        return failures
    }

    private static func unregisterApplication(at applicationURL: URL) {
        let register = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        _ = run(register, ["-u", applicationURL.path])
    }

    /// A mounted installer is another discoverable app copy. Eject only a
    /// volume that contains a bundle with Zhilian's exact identifier.
    private static func detachMountedInstallers() {
        let manager = FileManager.default
        let volumes = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        guard let mountedVolumes = try? manager.contentsOfDirectory(at: volumes, includingPropertiesForKeys: nil) else { return }
        for volume in mountedVolumes {
            let application = volume.appendingPathComponent("智连.app", isDirectory: true)
            guard Bundle(url: application)?.bundleIdentifier == bundleIdentifier else { continue }
            unregisterApplication(at: application)
            _ = run("/usr/bin/hdiutil", ["detach", volume.path])
        }
    }

    private static func removeLaunchpadRecord() {
        let userDirectory = run("/usr/bin/getconf", ["DARWIN_USER_DIR"])
        guard userDirectory.success else { return }
        let root = userDirectory.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else { return }
        let database = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent("com.apple.dock.launchpad/db/db")
        guard FileManager.default.fileExists(atPath: database.path),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/sqlite3") else { return }
        let statement = """
        PRAGMA busy_timeout=5000;
        BEGIN IMMEDIATE;
        CREATE TEMP TABLE zhilian_uninstall_items (item_id INTEGER PRIMARY KEY);
        INSERT OR IGNORE INTO zhilian_uninstall_items
          SELECT item_id FROM apps WHERE bundleid='app.zhilian.native';
        DELETE FROM image_cache WHERE item_id IN (SELECT item_id FROM zhilian_uninstall_items);
        DELETE FROM downloading_apps WHERE item_id IN (SELECT item_id FROM zhilian_uninstall_items)
          OR bundleid='app.zhilian.native';
        DELETE FROM apps WHERE item_id IN (SELECT item_id FROM zhilian_uninstall_items)
          OR bundleid='app.zhilian.native';
        DELETE FROM items WHERE rowid IN (SELECT item_id FROM zhilian_uninstall_items);
        DROP TABLE zhilian_uninstall_items;
        COMMIT;
        """
        _ = run("/usr/bin/sqlite3", [database.path, statement])
    }

    private static func run(_ executable: String, _ arguments: [String]) -> (success: Bool, output: String) {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error
        do { try process.run() }
        catch { return (false, error.localizedDescription) }
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
            + error.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus == 0, String(data: data, encoding: .utf8) ?? "")
    }
}
