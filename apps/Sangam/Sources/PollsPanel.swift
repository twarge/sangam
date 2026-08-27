import SwiftUI

/// The meeting's polls: vote by tapping answers (tap again to retract),
/// and create new polls for the room. Votes and results update live.
struct PollsPanel: View {
  @ObservedObject var controller: MeetingController
  @Environment(\.dismiss) private var dismiss

  @State private var creating = false
  @State private var question = ""
  @State private var answers = ["", ""]

  var body: some View {
    NavigationStack {
      Group {
        if creating {
          creationForm
        } else {
          pollList
        }
      }
      .navigationTitle("Polls")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
        }
        if !creating {
          ToolbarItem(placement: .primaryAction) {
            Button("New Poll") { creating = true }
          }
        }
      }
    }
    #if os(macOS)
      .frame(minWidth: 440, minHeight: 480)
    #endif
  }

  @ViewBuilder
  private var pollList: some View {
    if controller.polls.isEmpty {
      ContentUnavailableView(
        "No polls yet",
        systemImage: "chart.bar.xaxis",
        description: Text("Create one to ask the room.")
      )
    } else {
      List {
        ForEach(controller.polls) { poll in
          Section {
            ForEach(poll.answers) { answer in
              Button {
                controller.votePoll(id: poll.id, answerIndex: answer.id)
              } label: {
                HStack(spacing: 10) {
                  Image(systemName: answer.mine ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(answer.mine ? Color.accentColor : .secondary)
                  Text(answer.name)
                  Spacer(minLength: 12)
                  Text("\(answer.votes)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
            }
          } header: {
            VStack(alignment: .leading, spacing: 2) {
              Text(poll.question)
                .font(.headline)
                .textCase(nil)
              Text("by \(poll.senderName)")
                .font(.caption)
                .textCase(nil)
            }
          }
        }
      }
    }
  }

  private var creationForm: some View {
    Form {
      Section("Question") {
        TextField("What do you want to ask?", text: $question)
      }
      Section("Answers") {
        ForEach(answers.indices, id: \.self) { index in
          TextField("Answer \(index + 1)", text: $answers[index])
        }
        if answers.count < 8 {
          Button("Add Answer") { answers.append("") }
        }
      }
      Section {
        Button("Create Poll", action: create)
          .disabled(!creatable)
        Button("Cancel", role: .cancel) { resetCreation() }
      }
    }
    .formStyle(.grouped)
  }

  private var creatable: Bool {
    !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && cleanedAnswers.count >= 2
  }

  private var cleanedAnswers: [String] {
    answers
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  private func create() {
    controller.createPoll(
      question: question.trimmingCharacters(in: .whitespacesAndNewlines),
      answers: cleanedAnswers
    )
    resetCreation()
  }

  private func resetCreation() {
    creating = false
    question = ""
    answers = ["", ""]
  }
}
