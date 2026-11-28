import SwiftUI

struct QuestionSheet: View {
    let session: RemoteSession
    let questions: [RemoteQuestion]

    @Environment(RemoteClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    @State private var step: Int
    @State private var choices: [[Int]]
    @State private var isSending = false

    init(session: RemoteSession, questions: [RemoteQuestion]) {
        self.session = session
        self.questions = questions
        #if DEBUG
        let preview = UserDefaults.standard.object(forKey: "snapshotQuestionStep") == nil ? nil : UserDefaults.standard.integer(forKey: "snapshotQuestionStep")
        _step = State(initialValue: preview ?? 0)
        _choices = State(initialValue: questions.map { question in preview == nil ? [] : question.isMultiSelect ? [0, 2].filter { $0 < question.options.count } : [0] })
        #else
        _step = State(initialValue: 0)
        _choices = State(initialValue: questions.map { _ in [] })
        #endif
    }

    var body: some View {
        let isReview = step == questions.count

        NavigationStack {
            Group {
                if isReview {
                    review
                } else {
                    page(questions[step])
                }
            }
            .navigationTitle(isReview ? "Review" : "Question \(step + 1) of \(questions.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSending)
                }
            }
            .safeAreaInset(edge: .bottom) {
                footer(isReview: isReview)
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(isSending)
    }

    private func page(_ question: RemoteQuestion) -> some View {
        List {
            Section {
                if let header = question.header {
                    Text(header)
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                }
                Text(question.text)
                    .font(.title3.weight(.semibold))
            }
            .listRowBackground(Color.clear)
            .listRowInsets(.init(top: 4, leading: 4, bottom: 4, trailing: 4))
            Section {
                ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                    let isPicked = choices[question.id].contains(index)
                    Button {
                        toggle(index, in: question)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: symbol(isPicked: isPicked, isMultiSelect: question.isMultiSelect))
                                .font(.title3)
                                .foregroundStyle(isPicked ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.label)
                                    .foregroundStyle(.primary)
                                if let detail = option.detail {
                                    Text(detail)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.leading)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isPicked ? .isSelected : [])
                }
            } footer: {
                Text(question.isMultiSelect ? "Choose any that apply" : "Choose one")
            }
        }
        .sensoryFeedback(.selection, trigger: choices)
    }

    private var review: some View {
        List {
            ForEach(questions) { question in
                Section(question.header ?? question.text) {
                    ForEach(choices[question.id].sorted(), id: \.self) { index in
                        Label(question.options[index].label, systemImage: "checkmark")
                    }
                }
            }
        }
    }

    private func footer(isReview: Bool) -> some View {
        let canContinue = isReview || !choices[step].isEmpty

        return HStack(spacing: 12) {
            if step > 0 {
                Button("Back") { step -= 1 }
                    .buttonStyle(.bordered)
                    .disabled(isSending)
            }
            Button {
                if isReview {
                    send()
                } else {
                    step += 1
                }
            } label: {
                if isSending {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text(isReview ? "Send Answers" : step == questions.count - 1 ? "Review" : "Next")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canContinue || isSending || client.state != .connected)
        }
        .controlSize(.large)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func symbol(isPicked: Bool, isMultiSelect: Bool) -> String {
        if isMultiSelect { return isPicked ? "checkmark.square.fill" : "square" }

        return isPicked ? "largecircle.fill.circle" : "circle"
    }

    private func toggle(_ index: Int, in question: RemoteQuestion) {
        if !question.isMultiSelect {
            choices[question.id] = [index]
        } else if let existing = choices[question.id].firstIndex(of: index) {
            choices[question.id].remove(at: existing)
        } else {
            choices[question.id].append(index)
        }
    }

    private func send() {
        guard let keys = RemoteQuestion.keys(answering: questions, with: choices) else { return }

        isSending = true
        Task {
            await client.press(keys, in: session)
            dismiss()
        }
    }
}
