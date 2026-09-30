import Foundation

public struct PatternPath: Sendable {
    public let steps: [Step]

    public enum Step: Sendable {
        case field(String)
        case element(Int)
    }

    public init(_ text: String) throws {
        var steps: [Step] = []
        var name = ""
        var index: String?
        func flushName() {
            if !name.isEmpty {
                steps.append(.field(name))
                name = ""
            }
        }
        for character in text {
            switch character {
            case ".":
                flushName()
            case "[":
                flushName()
                index = ""
            case "]":
                guard let digits = index, let element = Int(digits) else { throw PatternPathError.malformed(text) }
                steps.append(.element(element))
                index = nil
            default:
                if index != nil {
                    index!.append(character)
                } else {
                    name.append(character)
                }
            }
        }
        guard index == nil else { throw PatternPathError.malformed(text) }
        flushName()
        self.steps = steps
    }
}

public enum PatternPathError: LocalizedError {
    case malformed(String)
    case noField(String, available: [String])
    case noElement(Int, count: Int)

    public var errorDescription: String? {
        switch self {
        case .malformed(let path):
            return "Malformed path \"\(path)\"; use names and indices, like commands[3].segname."
        case .noField(let name, let available):
            return "No field \"\(name)\"; available: \(available.joined(separator: ", "))."
        case .noElement(let index, let count):
            return "No element [\(index)]; the array has \(count) decoded elements."
        }
    }
}

extension DecodedPattern {
    public func descendant(at path: PatternPath) throws -> DecodedPattern {
        var node = self
        for step in path.steps {
            switch step {
            case .field(let name):
                guard let field = node.fields.first(where: { $0.name == name }) else {
                    throw PatternPathError.noField(name, available: node.fields.map(\.name))
                }
                node = field
            case .element(let index):
                guard node.elements.indices.contains(index) else {
                    throw PatternPathError.noElement(index, count: node.elements.count)
                }
                node = node.elements[index]
            }
        }
        return node
    }

    public func projection(depth: Int, elementLimit: Int) -> [String: Any] {
        var object: [String: Any] = [
            "type": typeName,
            "address": String(format: "0x%llx", address),
        ]
        if !name.isEmpty {
            object["name"] = name
        }
        if let displayName {
            object["display_name"] = displayName
        }
        if let size {
            object["size"] = size
        }
        if let bitOffset {
            object["bit_offset"] = bitOffset
            object["bits"] = bits
        }
        if let shown = formatted ?? label ?? value?.description {
            object["value"] = shown
        }
        if let comment {
            object["comment"] = comment
        }
        if truncated {
            object["truncated"] = true
        }
        if let visualizer {
            object["visualizer"] = visualizer.name
        }
        let visibleFields = fields.filter { !$0.hidden }
        if !visibleFields.isEmpty {
            object["field_count"] = visibleFields.count
            if depth > 0 {
                object["fields"] = visibleFields.map { $0.projection(depth: depth - 1, elementLimit: elementLimit) }
            }
        }
        if !elements.isEmpty {
            object["element_count"] = elements.count
            if depth > 0 {
                object["elements"] = elements.prefix(elementLimit).map { $0.projection(depth: depth - 1, elementLimit: elementLimit) }
            }
        }
        return object
    }
}
