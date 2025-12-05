import Foundation
import Frida

struct SpawnConfig: nonisolated Codable {
    enum Target: Codable {
        case application(identifier: String, name: String)
        case program(path: String)

        private enum CodingKeys: String, CodingKey {
            case kind
            case identifier
            case name
            case path
        }

        private enum Kind: String, Codable {
            case application
            case program
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)

            switch self {
            case .application(let identifier, let name):
                try container.encode(Kind.application, forKey: .kind)
                try container.encode(identifier, forKey: .identifier)
                try container.encode(name, forKey: .name)
            case .program(let path):
                try container.encode(Kind.program, forKey: .kind)
                try container.encode(path, forKey: .path)
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let kind = try container.decode(Kind.self, forKey: .kind)

            switch kind {
            case .application:
                let identifier = try container.decode(String.self, forKey: .identifier)
                let name = try container.decode(String.self, forKey: .name)
                self = .application(identifier: identifier, name: name)
            case .program:
                let path = try container.decode(String.self, forKey: .path)
                self = .program(path: path)
            }
        }
    }

    var target: Target
    var arguments: [String]
    var environment: [String: String]
    var workingDirectory: String?
    var stdio: Stdio
    var autoResume: Bool

    var defaultDisplayName: String {
        switch target {
        case .application(_, let name):
            return name
        case .program(let path):
            // FIXME: This won't work for a Windows path
            let ns = path as NSString
            let last = ns.lastPathComponent
            return last.isEmpty ? path : last
        }
    }

    var programString: String {
        switch target {
        case .application(let identifier, _):
            return identifier
        case .program(let path):
            return path
        }
    }

    var argvParam: [String]? {
        arguments.isEmpty ? nil : arguments
    }

    var envParam: [String: String]? {
        environment.isEmpty ? nil : environment
    }

    var cwdParam: String? {
        guard
            let cwd = workingDirectory?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !cwd.isEmpty
        else {
            return nil
        }
        return cwd
    }
}
