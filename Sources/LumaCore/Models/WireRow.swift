import Foundation

func encodeRow<T: Encodable>(_ value: T) -> [String: Any] {
    guard let data = try? wireEncoder.encode(value),
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return obj
}

func decodeRow<T: Decodable>(_ obj: [String: Any]) -> T? {
    guard let data = try? JSONSerialization.data(withJSONObject: obj),
        let value = try? wireDecoder.decode(T.self, from: data)
    else { return nil }
    return value
}

private let wireEncoder: JSONEncoder = {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .iso8601
    return e
}()

private let wireDecoder: JSONDecoder = {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return d
}()
