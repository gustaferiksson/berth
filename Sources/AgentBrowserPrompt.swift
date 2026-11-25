import SwiftUI

struct AgentBrowserPrompt: View {
    let access: BrowserAccess

    var body: some View {
        let request = access.requests.first
        Color.clear
            .id(request?.id)
            .alert("Allow Browser Access?", isPresented: Binding(get: { request != nil }, set: { _ in }), presenting: request) { request in
                Button("Allow for This Session") { access.resolve(request, with: .allowed) }
                Button("Deny", role: .cancel) { access.resolve(request, with: .denied) }
            } message: { request in
                Text("The agent in \(request.title) wants to open and control pages in Berth’s browser. Berth asks once for each session.")
            }
    }
}
