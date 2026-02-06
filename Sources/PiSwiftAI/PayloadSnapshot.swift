import Foundation

func emitPayload<T: Encodable>(_ handler: PayloadHandler?, payload: T) {
    guard let handler else { return }
    let encoder = JSONEncoder()
    guard let data = try? encoder.encode(payload),
          let json = String(data: data, encoding: .utf8) else {
        return
    }
    handler(PayloadSnapshot(json: json))
}

func emitPayload(_ handler: PayloadHandler?, jsonObject: Any) {
    guard let handler else { return }
    guard JSONSerialization.isValidJSONObject(jsonObject),
          let data = try? JSONSerialization.data(withJSONObject: jsonObject, options: []),
          let json = String(data: data, encoding: .utf8) else {
        return
    }
    handler(PayloadSnapshot(json: json))
}

func emitPayload(_ handler: PayloadHandler?, data: Data) {
    guard let handler,
          let json = String(data: data, encoding: .utf8) else {
        return
    }
    handler(PayloadSnapshot(json: json))
}
