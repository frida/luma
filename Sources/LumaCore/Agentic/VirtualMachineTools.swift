import Foundation

extension MissionTools {
    static func registerVirtualMachines(in catalog: ToolCatalog, engine: Engine) {
        registerListVMTemplates(in: catalog, engine: engine)
        registerListVMs(in: catalog, engine: engine)
        registerCreateVM(in: catalog, engine: engine)
        registerBootVM(in: catalog, engine: engine)
        registerStopVM(in: catalog, engine: engine)
        registerDeleteVM(in: catalog, engine: engine)
        registerMarkVMReady(in: catalog, engine: engine)
        registerDiscardVMReadySnapshot(in: catalog, engine: engine)
        registerScreenshotVM(in: catalog, engine: engine)
        registerSendVMInput(in: catalog, engine: engine)
    }

    private static func registerListVMTemplates(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "list_vm_templates",
            description: """
                List the kinds of virtual machine Luma can create, with the parameters each takes and \
                whether it can run on this host. Pass a template's id and parameters to create_vm.
                """,
            inputSchemaJSON: """
                {"type":"object","properties":{},"additionalProperties":false}
                """,
            isObserve: true,
            requiresSession: false
        )
        catalog.register(spec: spec) { [weak engine] _ in
            guard let engine else { return errorResult("engine unavailable", code: .unavailable) }
            let manager = engine.virtualMachines
            await manager.prewarm()
            let templates = manager.templates.map { template -> [String: Any] in
                var entry: [String: Any] = [
                    "id": template.id,
                    "name": template.name,
                    "summary": template.summary,
                    "operating_system": template.operatingSystem.rawValue,
                    "architectures": template.variants.map(\.architecture.rawValue),
                    "parameters": template.parameters.map(parameterJSON),
                ]
                if case .unavailable(let reason) = manager.availability(for: template) {
                    entry["unavailable"] = reason
                }
                return entry
            }
            return makeResult(jsonObject: templates, summary: "\(templates.count) template\(templates.count == 1 ? "" : "s")")
        }
    }

    private static func registerListVMs(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "list_vms",
            description: """
                List the virtual machines in this project: id, name, template, parameters, whether it has \
                a ready snapshot, and its state. A running machine has a device_id: use it with \
                list_processes and attach_to_process to instrument its kernel or processes.
                """,
            inputSchemaJSON: """
                {"type":"object","properties":{},"additionalProperties":false}
                """,
            isObserve: true,
            requiresSession: false
        )
        catalog.register(spec: spec) { [weak engine] _ in
            guard let engine else { return errorResult("engine unavailable", code: .unavailable) }
            let machines = engine.virtualMachines.records.map { machineJSON($0, engine: engine) }
            return makeResult(jsonObject: machines, summary: "\(machines.count) virtual machine\(machines.count == 1 ? "" : "s")")
        }
    }

    private static func registerCreateVM(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "create_vm",
            description: """
                Create a virtual machine from a template and boot it. 'parameters' maps parameter ids \
                from list_vm_templates to values; omitted ones take their defaults. Requires user approval.
                """,
            inputSchemaJSON: """
                {"type":"object","properties":{"template_id":{"type":"string"},"name":{"type":"string"},\
                "parameters":{"type":"object","additionalProperties":{"type":["string","integer","boolean"]}}},\
                "required":["template_id","name"],"additionalProperties":false}
                """,
            isObserve: false,
            requiresSession: false
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine else { return errorResult("engine unavailable", code: .unavailable) }
            let manager = engine.virtualMachines
            guard let templateID = invocation.args["template_id"] as? String,
                let template = manager.templates.first(where: { $0.id == templateID })
            else {
                return errorResult("no template with that template_id; see list_vm_templates", code: .notFound)
            }
            guard let name = invocation.args["name"] as? String, !name.isEmpty else {
                return errorResult("name is required", code: .invalidInput)
            }
            let given = (invocation.args["parameters"] as? [String: Any] ?? [:]).compactMapValues(parameterValue)
            do {
                let machine = try await manager.create(
                    template: template, name: name, parameters: template.defaultParameterValues.merging(given) { _, new in new },
                    agentPath: nil)
                let record = manager.records.first { $0.id == machine.id }!
                return makeResult(jsonObject: machineJSON(record, engine: engine), summary: "Created \(name)")
            } catch {
                return errorResult("create failed: \(error.localizedDescription)", code: .failed)
            }
        }
    }

    private static func registerBootVM(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "boot_vm",
            description: """
                Boot a stopped virtual machine. It resumes from its ready snapshot when it has one, unless \
                'fresh' is true. Requires user approval.
                """,
            inputSchemaJSON: """
                {"type":"object","properties":{"vm_id":{"type":"string"},"fresh":{"type":"boolean","default":false}},\
                "required":["vm_id"],"additionalProperties":false}
                """,
            isObserve: false,
            requiresSession: false
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine else { return errorResult("engine unavailable", code: .unavailable) }
            guard let record = machineRecord(invocation.args, engine: engine) else {
                return errorResult("no virtual machine with that vm_id; see list_vms", code: .notFound)
            }
            guard engine.virtualMachines.machine(for: record) == nil else {
                return errorResult("\(record.name) is already running", code: .invalidInput)
            }
            do {
                _ = try await engine.virtualMachines.boot(
                    record, resumingFromReadySnapshot: !((invocation.args["fresh"] as? Bool) ?? false))
                return makeResult(jsonObject: machineJSON(record, engine: engine), summary: "Booted \(record.name)")
            } catch {
                return errorResult("boot failed: \(error.localizedDescription)", code: .failed)
            }
        }
    }

    private static func registerStopVM(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "stop_vm",
            description: "Shut a running virtual machine down. Sessions on it end. Requires user approval.",
            inputSchemaJSON: """
                {"type":"object","properties":{"vm_id":{"type":"string"}},"required":["vm_id"],"additionalProperties":false}
                """,
            isObserve: false,
            requiresSession: false
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine else { return errorResult("engine unavailable", code: .unavailable) }
            guard let record = machineRecord(invocation.args, engine: engine) else {
                return errorResult("no virtual machine with that vm_id; see list_vms", code: .notFound)
            }
            await engine.virtualMachines.stop(record)
            return makeResult(jsonObject: machineJSON(record, engine: engine), summary: "Stopped \(record.name)")
        }
    }

    private static func registerDeleteVM(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "delete_vm",
            description: "Stop a virtual machine if it runs, and delete it along with its disk and snapshots. Requires user approval.",
            inputSchemaJSON: """
                {"type":"object","properties":{"vm_id":{"type":"string"}},"required":["vm_id"],"additionalProperties":false}
                """,
            isObserve: false,
            requiresSession: false
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine else { return errorResult("engine unavailable", code: .unavailable) }
            guard let record = machineRecord(invocation.args, engine: engine) else {
                return errorResult("no virtual machine with that vm_id; see list_vms", code: .notFound)
            }
            await engine.virtualMachines.forget(record)
            return makeResult(jsonObject: ["vm_id": record.id.uuidString, "deleted": true], summary: "Deleted \(record.name)")
        }
    }

    private static func registerMarkVMReady(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "mark_vm_ready",
            description: """
                Snapshot a running virtual machine as its ready state, so later boots resume there instead \
                of starting over. Requires user approval.
                """,
            inputSchemaJSON: """
                {"type":"object","properties":{"vm_id":{"type":"string"}},"required":["vm_id"],"additionalProperties":false}
                """,
            isObserve: false,
            requiresSession: false
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine else { return errorResult("engine unavailable", code: .unavailable) }
            guard let record = machineRecord(invocation.args, engine: engine),
                let machine = engine.virtualMachines.machine(for: record)
            else {
                return errorResult("no running virtual machine with that vm_id; see list_vms", code: .notFound)
            }
            guard machine.capabilities.contains(.snapshot) else {
                return errorResult("\(record.name) cannot take snapshots", code: .unavailable)
            }
            do {
                try await engine.virtualMachines.markReady(machine)
                return makeResult(jsonObject: machineJSON(record, engine: engine), summary: "Marked \(record.name) ready")
            } catch {
                return errorResult("snapshot failed: \(error.localizedDescription)", code: .failed)
            }
        }
    }

    private static func registerDiscardVMReadySnapshot(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "discard_vm_ready_snapshot",
            description: "Drop a virtual machine's ready snapshot, so its next boot starts from scratch. Requires user approval.",
            inputSchemaJSON: """
                {"type":"object","properties":{"vm_id":{"type":"string"}},"required":["vm_id"],"additionalProperties":false}
                """,
            isObserve: false,
            requiresSession: false
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine else { return errorResult("engine unavailable", code: .unavailable) }
            guard let record = machineRecord(invocation.args, engine: engine) else {
                return errorResult("no virtual machine with that vm_id; see list_vms", code: .notFound)
            }
            do {
                try await engine.virtualMachines.discardReadySnapshot(record)
                return makeResult(jsonObject: machineJSON(record, engine: engine), summary: "Discarded \(record.name)'s snapshot")
            } catch {
                return errorResult("discard failed: \(error.localizedDescription)", code: .failed)
            }
        }
    }

    private static func registerScreenshotVM(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "screenshot_vm",
            description: """
                Capture a running virtual machine's screen as an image, scaled down to at most 'max_width' \
                pixels wide. Coordinates for send_vm_input's click are in the guest's own pixels, which the \
                result reports.
                """,
            inputSchemaJSON: """
                {"type":"object","properties":{"vm_id":{"type":"string"},"max_width":{"type":"integer","minimum":160,"maximum":2560,"default":1280}},\
                "required":["vm_id"],"additionalProperties":false}
                """,
            isObserve: true,
            requiresSession: false
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine else { return errorResult("engine unavailable", code: .unavailable) }
            let source: any VirtualMachineFrameSource
            do {
                source = try frameSource(invocation.args, engine: engine)
            } catch {
                return errorResult(error.localizedDescription, code: .unavailable)
            }
            guard let frame = source.frame else {
                return errorResult("the machine has not drawn anything yet", code: .unavailable)
            }
            guard let png = frame.pngData(maxWidth: (invocation.args["max_width"] as? Int) ?? 1280) else {
                return errorResult("screenshots are not supported on this platform", code: .unavailable)
            }
            return makeResult(
                jsonObject: ["width": frame.width, "height": frame.height],
                attachments: [LLMAttachment(kind: .image, mediaType: "image/png", base64: png.base64EncodedString())],
                summary: "Captured a \(frame.width)×\(frame.height) screen")
        }
    }

    private static func registerSendVMInput(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "send_vm_input",
            description: """
                Type into a running virtual machine and press keys or click. 'text' is typed as it reads; \
                'keys' presses named keys in order (escape, backspace, tab, return, space, up, down, left, \
                right, delete, home, end, page_up, page_down, f1-f12); 'click' clicks at guest pixel \
                coordinates, which needs a guest with an absolute pointer. They run in that order. \
                Requires user approval.
                """,
            inputSchemaJSON: """
                {"type":"object","properties":{"vm_id":{"type":"string"},"text":{"type":"string"},\
                "keys":{"type":"array","items":{"type":"string"}},\
                "click":{"type":"object","properties":{"x":{"type":"number"},"y":{"type":"number"},\
                "button":{"type":"string","enum":["left","middle","right"],"default":"left"}},"required":["x","y"]}},\
                "required":["vm_id"],"additionalProperties":false}
                """,
            isObserve: false,
            requiresSession: false
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine else { return errorResult("engine unavailable", code: .unavailable) }
            do {
                let source = try frameSource(invocation.args, engine: engine)
                let events = try inputEvents(invocation.args, pointerIsAbsolute: source.pointerIsAbsolute)
                events.forEach(source.send)
                return makeResult(jsonObject: ["events": events.count], summary: "Sent \(events.count) input event(s)")
            } catch {
                return errorResult(error.localizedDescription, code: .invalidInput)
            }
        }
    }

    private static func parameterJSON(_ parameter: VirtualMachineParameter) -> [String: Any] {
        var entry: [String: Any] = ["id": parameter.id, "name": parameter.name]
        switch parameter.kind {
        case .text(let value):
            entry["kind"] = "text"
            entry["default"] = value
        case .number(let value, let min, let max, let unit):
            entry["kind"] = "number"
            entry["default"] = value
            entry["min"] = min
            entry["max"] = max
            if let unit {
                entry["unit"] = unit
            }
        case .filePath(let extensions):
            entry["kind"] = "file_path"
            entry["extensions"] = extensions
        case .choice(let options, let value):
            entry["kind"] = "choice"
            entry["options"] = options.map { ["id": $0.id, "name": $0.name] }
            entry["default"] = value
        case .toggle(let value):
            entry["kind"] = "toggle"
            entry["default"] = value
        }
        return entry
    }

    private static func machineJSON(_ record: VirtualMachineRecord, engine: Engine) -> [String: Any] {
        let manager = engine.virtualMachines
        var entry: [String: Any] = [
            "id": record.id.uuidString,
            "name": record.name,
            "template_id": record.templateID,
            "parameters": record.parameters.mapValues(parameterJSONValue),
            "has_ready_snapshot": manager.records.first { $0.id == record.id }?.hasReadySnapshot ?? record.hasReadySnapshot,
        ]
        if let machine = manager.machine(for: record) {
            entry["state"] = stateText(machine.state)
            if let device = manager.device(for: record) {
                entry["device_id"] = device.id
            }
        } else {
            entry["state"] = "stopped"
        }
        return entry
    }

    private static func parameterValue(_ value: Any) -> VirtualMachineParameterValue? {
        switch value {
        case let flag as Bool:
            return .toggle(flag)
        case let number as Int:
            return .number(number)
        case let text as String:
            return .text(text)
        default:
            return nil
        }
    }

    private static func machineRecord(_ args: [String: Any], engine: Engine) -> VirtualMachineRecord? {
        guard let text = args["vm_id"] as? String, let id = UUID(uuidString: text) else { return nil }
        return engine.virtualMachines.records.first { $0.id == id }
    }

    private static func frameSource(_ args: [String: Any], engine: Engine) throws -> any VirtualMachineFrameSource {
        guard let record = machineRecord(args, engine: engine), let machine = engine.virtualMachines.machine(for: record) else {
            throw VirtualMachineToolError("no running virtual machine with that vm_id; see list_vms")
        }
        guard case .frames(let source) = machine.display else {
            throw VirtualMachineToolError("\(record.name)'s screen is drawn by its own window, which Luma cannot capture or type into")
        }
        return source
    }

    private static func inputEvents(_ args: [String: Any], pointerIsAbsolute: Bool) throws -> [VirtualMachineInputEvent] {
        var events: [VirtualMachineInputEvent] = []
        for character in (args["text"] as? String) ?? "" {
            guard let stroke = VirtualMachineKeyboard.stroke(for: character) else {
                throw VirtualMachineToolError("cannot type \"\(character)\"")
            }
            events += stroke.events
        }
        for name in (args["keys"] as? [String]) ?? [] {
            guard let key = VirtualMachineKey(toolName: name) else { throw VirtualMachineToolError("unknown key \"\(name)\"") }
            let code = VirtualMachineKeyboard.code(for: key)
            events += [.keyDown(code: code), .keyUp(code: code)]
        }
        if let click = args["click"] as? [String: Any] {
            guard pointerIsAbsolute else {
                throw VirtualMachineToolError("this guest's pointer is relative, so it cannot click at a position")
            }
            guard let x = (click["x"] as? NSNumber)?.doubleValue, let y = (click["y"] as? NSNumber)?.doubleValue else {
                throw VirtualMachineToolError("click needs x and y")
            }
            let button = VirtualMachinePointerButton(toolName: (click["button"] as? String) ?? "left")
            events += [.pointerMoved(x: x, y: y), .pointerButtonDown(button: button), .pointerButtonUp(button: button)]
        }
        return events
    }

    private static func parameterJSONValue(_ value: VirtualMachineParameterValue) -> Any {
        switch value {
        case .text(let text):
            return text
        case .number(let number):
            return number
        case .toggle(let flag):
            return flag
        }
    }

    private static func stateText(_ state: VirtualMachineState) -> String {
        switch state {
        case .starting:
            return "starting"
        case .installing(let fraction):
            return "installing (\(Int(fraction * 100))%)"
        case .running:
            return "running"
        case .capturingSnapshot:
            return "capturing snapshot"
        case .restoringSnapshot:
            return "restoring snapshot"
        case .stopped:
            return "stopped"
        case .failed(let reason):
            return "failed: \(reason)"
        }
    }
}

private struct VirtualMachineToolError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

extension VirtualMachineKey {
    fileprivate init?(toolName: String) {
        switch toolName.lowercased() {
        case "escape": self = .escape
        case "backspace": self = .backspace
        case "tab": self = .tab
        case "return", "enter": self = .return
        case "space": self = .space
        case "up": self = .upArrow
        case "down": self = .downArrow
        case "left": self = .leftArrow
        case "right": self = .rightArrow
        case "delete": self = .delete
        case "home": self = .home
        case "end": self = .end
        case "page_up": self = .pageUp
        case "page_down": self = .pageDown
        default:
            guard toolName.lowercased().hasPrefix("f"), let number = UInt8(toolName.dropFirst()), (1...12).contains(number) else {
                return nil
            }
            self = .function(number)
        }
    }
}

extension VirtualMachinePointerButton {
    fileprivate init(toolName: String) {
        switch toolName {
        case "middle": self = .middle
        case "right": self = .right
        default: self = .left
        }
    }
}
