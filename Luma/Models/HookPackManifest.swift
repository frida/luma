struct HookPackManifest: Decodable {
    struct Icon: Decodable {
        var systemName: String?
        var file: String?
    }

    struct Feature: Decodable, Identifiable {
        let id: String
        let name: String
        let defaultEnabled: Bool
    }

    let id: String
    let name: String
    let icon: Icon?
    let entry: String
    var features: [Feature]
}
