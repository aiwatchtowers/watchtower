import AppKit
import GRDB
import SwiftUI
@testable import WatchtowerCore
@testable import WatchtowerDesktop

/// The workbench FILES section polished to the multi-folder mockup (board
/// #2017): the header, the root row with the branch on its right, and the
/// tree, in five states. Folders are made under a temporary directory with
/// `acme` sample names; git status is passed in, never read.
@MainActor
enum FilesSectionShotFixtures {
    private static var base: URL?

    static var shots: [DesignShot] {
        [
            shot("files-tree-dirty-branch", height: 300) {
                try section(
                    root: mainRoot(tree: richTree),
                    status: WorkbenchGitStatus(branch: "feature/pdf-export", ahead: 2, behind: 1, dirty: true),
                    git: GitStatusSnapshot(files: ["export.go": .modified, "internal/report/pdf.go": .untracked]),
                    expand: ["internal", "internal/report"],
                    active: "internal/report/pdf.go"
                )
            },
            shot("files-tree-no-git", height: 220) {
                try section(root: mainRoot(tree: richTree), status: nil, git: GitStatusSnapshot(), expand: ["cmd"], active: nil)
            },
            shot("files-tree-empty-folder", height: 120) {
                try section(
                    root: mainRoot(tree: []), status: WorkbenchGitStatus(branch: "main"), git: GitStatusSnapshot(),
                    expand: [], active: nil
                )
            },
            shot("files-tree-unreadable-folder", height: 220) {
                try section(
                    root: unreadableRoot(), status: WorkbenchGitStatus(branch: "main", behind: 1),
                    git: GitStatusSnapshot(), expand: ["secrets"], active: nil
                )
            },
            shot("files-tree-worktree", height: 220) {
                try section(
                    root: worktreeRoot(), status: WorkbenchGitStatus(branch: "pdf-button", ahead: 3, dirty: true),
                    git: GitStatusSnapshot(files: ["web/button.tsx": .modified]), expand: ["web"], active: nil
                )
            }
        ]
    }

    /// Removes the sample folders, unlocking the unreadable one first.
    static func cleanUp() {
        guard let base else { return }
        let locked = base.appendingPathComponent("locked/acme/secrets")
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        try? FileManager.default.removeItem(at: base)
        self.base = nil
    }

    private static let richTree = [
        "cmd/", "internal/report/", "export.go", "go.mod", "README.md", "cmd/main.go",
        "internal/report/pdf.go", "internal/report/csv.go", "internal/store.go"
    ]

    private static func shot(_ name: String, height: CGFloat, _ make: @escaping () throws -> AnyView) -> DesignShot {
        DesignShot(name: name, size: NSSize(width: 300, height: height)) {
            do {
                return try make()
            } catch {
                return AnyView(Text("fixture failed: \(error.localizedDescription)"))
            }
        }
    }

    private static func section(
        root: CodeRoot, status: WorkbenchGitStatus?, git: GitStatusSnapshot, expand: [String], active: String?
    ) throws -> AnyView {
        let tree = CodeFileTree(root: root.folder)
        tree.loadIfNeeded()
        expand.forEach(tree.expand)
        let actions = CodeFileTreeList.Actions(
            open: { _, _ in }, newEntry: { _, _ in }, rename: { _ in }, trash: { _ in }, commit: {}, root: root.folder
        )
        return AnyView(
            VStack(spacing: 0) {
                CodeFilesHeader(
                    root: root, isExpanded: true, toggle: {}, newEntry: { _ in }, collapseAll: {}, reload: {}
                )
                CodeFileTreeList(
                    tree: tree, rootLine: CodeFilesRootLine(root: root, status: status), activeFile: active,
                    git: git, edit: .constant(nil), actions: actions
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .panelSurface()
        )
    }

    // MARK: Sample folders

    private static func folder(_ relPath: String, entries: [String]) throws -> URL {
        let root = try baseURL().appendingPathComponent(relPath, isDirectory: true)
        let manager = FileManager.default
        if manager.fileExists(atPath: root.path) { return root }
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        for entry in entries {
            let url = root.appendingPathComponent(entry)
            if entry.hasSuffix("/") {
                try manager.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try "package acme\n".write(to: url, atomically: true, encoding: .utf8)
            }
        }
        return root
    }

    private static func baseURL() throws -> URL {
        if let base { return base }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("files-shots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        base = url
        return url
    }

    private static func mainRoot(tree entries: [String]) throws -> CodeRoot {
        let name = entries.isEmpty ? "empty/acme" : "rich/acme"
        let url = try folder(name, entries: entries)
        return Workbench(row: Row(["id": 1, "name": "acme", "folder_path": url.path])).mainCodeRoot
    }

    private static func unreadableRoot() throws -> CodeRoot {
        let url = try folder("locked/acme", entries: ["secrets/", "docs/", "go.mod", "secrets/key.pem"])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: url.appendingPathComponent("secrets").path
        )
        return Workbench(row: Row(["id": 1, "name": "acme", "folder_path": url.path])).mainCodeRoot
    }

    private static func worktreeRoot() throws -> CodeRoot {
        let url = try folder("acme-wt/pdf-button", entries: ["web/", "web/button.tsx", "web/app.tsx", "package.json"])
        return CodeRoot(workbenchID: 1, worktree: url)
    }
}
