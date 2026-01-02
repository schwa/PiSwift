import Foundation
import OpenAI

func makeOpenAIClient(model: Model, apiKey: String?) throws -> OpenAI {
    let token = apiKey ?? ""
    if token.isEmpty {
        throw StreamError.missingApiKey(model.provider)
    }

    let url = URL(string: model.baseUrl)
    let host = url?.host ?? "api.openai.com"
    let scheme = url?.scheme ?? "https"
    let port = url?.port ?? 443
    let basePath = url?.path.isEmpty == false ? url!.path : "/v1"
    let headers = model.headers ?? [:]

    let configuration = OpenAI.Configuration(
        token: token,
        organizationIdentifier: nil,
        host: host,
        port: port,
        scheme: scheme,
        basePath: basePath,
        timeoutInterval: 60,
        customHeaders: headers
    )

    return OpenAI(configuration: configuration)
}
