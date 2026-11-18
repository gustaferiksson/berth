import BerthCore
import SwiftUI

struct LanguageServerEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var servers: [LanguageServerEntry]
    @State private var server: LanguageServerEntry
    @State private var arguments: String
    @State private var languages: String
    @State private var rootMarkers: String

    init(server: LanguageServerEntry, servers: Binding<[LanguageServerEntry]>) {
        _servers = servers
        _server = State(initialValue: server)
        _arguments = State(initialValue: server.arguments.joined(separator: " "))
        _languages = State(initialValue: server.languages.joined(separator: ", "))
        _rootMarkers = State(initialValue: server.rootMarkers.joined(separator: ", "))
    }

    var body: some View {
        let isNew = !servers.contains { $0.id == server.id }
        let name = server.name.trimmingCharacters(in: .whitespaces)
        let command = server.command.trimmingCharacters(in: .whitespaces)
        let languageList = languages.split { $0 == "," || $0.isWhitespace }.map { String($0.drop { $0 == "." }).lowercased() }
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "New Language Server" : "Edit Language Server")
                .font(.headline)
            Form {
                TextField("Name", text: $server.name, prompt: Text("Biome"))
                TextField("Command", text: $server.command, prompt: Text("biome"))
                TextField("Arguments", text: $arguments, prompt: Text("lsp-proxy"))
                TextField("Languages", text: $languages, prompt: Text("ts, tsx, json"))
                TextField("Root markers", text: $rootMarkers, prompt: Text("biome.json, biome.jsonc"))
                Picker("Provides", selection: $server.isDiagnosticsOnly) {
                    Text("Diagnostics, definition and hover").tag(false)
                    Text("Diagnostics only").tag(true)
                }
            }
            .formStyle(.columns)
            Text("Languages are file extensions or language ids. Without root markers the server starts in the repository root.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                if let builtIn = LanguageServerEntry.defaults.first(where: { $0.id == server.id }) {
                    Button("Restore Default") {
                        servers = servers.map { $0.id == builtIn.id ? builtIn : $0 }
                        dismiss()
                    }
                } else if !isNew {
                    Button("Remove Server", role: .destructive) {
                        servers.removeAll { $0.id == server.id }
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    server.name = name
                    server.command = command
                    server.arguments = arguments.split(whereSeparator: \.isWhitespace).map(String.init)
                    server.languages = languageList
                    server.rootMarkers = rootMarkers.split { $0 == "," || $0.isWhitespace }.map(String.init)
                    servers = isNew ? servers + [server] : servers.map { $0.id == server.id ? server : $0 }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || command.isEmpty || languageList.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
