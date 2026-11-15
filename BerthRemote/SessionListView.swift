import SwiftUI

struct SessionListView: View {
    @Environment(RemoteClient.self) private var client
    @State private var path: [String] = UserDefaults.standard.string(forKey: "remoteSession").map { [$0] } ?? []
    @State private var isStartingSession = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                ForEach(client.groups) { group in
                    Section(group.title) {
                        ForEach(group.sessions) { session in
                            NavigationLink(value: session.id) {
                                SessionRow(session: session)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Sessions")
            .navigationDestination(for: String.self) { SessionView(sessionID: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Disconnect", systemImage: "xmark") { client.disconnect() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New Session", systemImage: "plus") { isStartingSession = true }
                        .disabled(client.folders.isEmpty)
                }
            }
            .sheet(isPresented: $isStartingSession) {
                NewSessionView()
            }
            .onChange(of: client.openedSessionID) {
                guard let id = client.openedSessionID else { return }
                client.openedSessionID = nil
                path = [id]
            }
        }
    }
}

private struct SessionRow: View {
    let session: RemoteSession

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: session.isLocked ? "lock.fill" : session.status == "waiting" ? "exclamationmark.bubble.fill" : session.status == "busy" ? "ellipsis.circle.fill" : session.status == nil ? "circle" : "circle.fill")
                .foregroundStyle(session.status == "waiting" ? .orange : session.status == "busy" ? .green : .secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .lineLimit(1)
                Text([URL(filePath: session.folder).lastPathComponent, session.branch].compactMap(\.self).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(session.lastActivity, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct NewSessionView: View {
    @Environment(RemoteClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    @State private var folder = ""
    @State private var prompt = ""

    var body: some View {
        NavigationStack {
            Form {
                Picker("Folder", selection: $folder) {
                    ForEach(client.folders, id: \.self) { Text(URL(filePath: $0).lastPathComponent).tag($0) }
                }
                TextField("Prompt", text: $prompt, axis: .vertical)
                    .lineLimit(3...8)
            }
            .navigationTitle("New Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        client.send(.newSession(folder: folder, prompt: prompt))
                        dismiss()
                    }
                    .disabled(folder.isEmpty)
                }
            }
            .onAppear { folder = client.folders.first ?? "" }
        }
    }
}
