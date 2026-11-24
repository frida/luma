import Foundation

@MainActor
enum ObjectChatSystemPrompt {
    struct Subject {
        let className: String
        let printString: String
        let views: [String]
        let slots: [(name: String, value: String)]
    }

    static let subjectPrintLimit = 2 * 1024

    static func build(for chat: ObjectChat, subject: Subject, objects: [ObjectChatObject]) -> String {
        var lines = [
            "You are an interactive assistant helping a reverse engineer understand one object in a live Pharo Smalltalk image that is attached to a Frida-instrumented process. Be specific and concise. Lead with the conclusion.",
            "You work by writing Smalltalk. Each `chat_evaluate` call runs one expression in the user's own image and stores its result as a new object with an id such as `o2.alice` (a number and the id of the member whose Luma made it). `self` is `o1`, the object this chat is about, so its instance variables can be named directly.",
            "Objects are named by id. To use an earlier result, bind it: pass `bindings: [{\"name\": \"graph\", \"object_id\": \"o2.alice\"}]` and write `graph` in the code. `chat_objects` lists what this chat holds; `chat_view` reads one of an object's views (the tabs an inspector shows) without running code.",
            "Write one expression per call, and before each call write one sentence saying why you are running it. The user sees every call you make and may have to press Run before it runs; a call they reject comes back as an error: do not retry it, reconsider.",
            "",
            "# The object",
            "Class: \(subject.className)",
            "Prints as: \(DisplayTruncation.truncated(subject.printString, limit: subjectPrintLimit))",
        ]
        if !subject.views.isEmpty {
            lines.append("Views: " + subject.views.joined(separator: ", "))
        }
        if !subject.slots.isEmpty {
            lines.append("Instance variables:")
            lines += subject.slots.map { "- \($0.name): \($0.value)" }
        }
        lines += origin(of: chat)
        if let sessionID = chat.sessionID {
            lines.append("")
            lines.append(
                "Session: \(sessionID.uuidString) -- pass this as `session_id` to the session tools. They run at the session's host; any that changes the target waits for the host's approval."
            )
        }
        if objects.count > 1 {
            lines.append("")
            lines.append("# Objects so far")
            lines += objects.map {
                "- \($0.objectID)\($0.name.map { " (\($0))" } ?? ""): \($0.className), \(DisplayTruncation.truncated($0.printString, limit: 200))"
            }
        }
        lines.append("")
        lines.append(MissionSystemPrompt.untrustedTargetOutput)
        return lines.joined(separator: "\n")
    }

    private static func origin(of chat: ObjectChat) -> [String] {
        switch chat.subject {
        case .project:
            return [
                "",
                "It is the project itself, `LumaProject`: it answers `sessions`, `notebookEntries`, `events` and `definitions`. Session tools take the `session_id` of one of its sessions and run at that session's host.",
                "This may be a conversation between the lab's members. A message from a person begins with their name; answer only the question put to you, and do not answer for the others.",
            ]
        case .instruction(_, let anchor):
            return ["", "It is the instruction at \(anchor.displayString)."]
        case .object(_, let label, let source, _, _, _):
            var lines = ["", "It came from \(label)."]
            if let source {
                lines += ["Its source:", "```smalltalk", source, "```"]
            }
            return lines
        }
    }
}
