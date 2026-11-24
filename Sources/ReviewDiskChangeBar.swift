import BerthCore
import SwiftUI

struct ReviewDiskChangeBar: View {
    let model: ReviewModel
    let path: String

    var body: some View {
        HStack {
            Text("Changed on disk")
            Spacer()
            Button("Reload") { model.reloadFromDisk(path) }
            Button("Keep Mine") { model.keepMine(path) }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        Divider()
    }
}

extension ReviewModel {
    func hasDiskConflict(_ path: String) -> Bool {
        drafts[path] != nil && buffers[path]?.hasConflict == true
    }

    func reloadFromDisk(_ path: String) {
        buffers[path]?.acceptIncoming()
        drafts[path] = nil
    }

    func keepMine(_ path: String) {
        buffers[path]?.acceptIncoming()
    }

    func syncBuffer(of path: String, with modified: ReviewText?) {
        guard case let .text(disk)? = modified else {
            buffers[path] = nil
            return
        }

        var buffer = buffers[path] ?? ReviewEditBuffer(base: disk)
        if buffer.read(disk: disk, draft: drafts[path]) == .current, drafts[path] == disk { drafts[path] = nil }
        buffers[path] = buffer
    }

    func isSafeToSave(_ text: String, to path: String, in root: String) -> Bool {
        guard case let .text(disk)? = try? ReviewGit.workingTreeText(path, in: root), var buffer = buffers[path] else {
            notice = "\(path) changed on disk; reload before saving"
            return false
        }

        let outcome = buffer.read(disk: disk, draft: text)
        buffers[path] = buffer
        if outcome == .conflict { notice = "\(path) changed on disk. Choose Reload or Keep Mine first." }
        return outcome == .current
    }
}
