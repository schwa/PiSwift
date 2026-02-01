import Foundation
import OpenAI

func makeOpenAIClient(
    model: Model,
    apiKey: String?,
    headers: [String: String]? = nil,
    middlewares: [OpenAIMiddleware] = []
) throws -> OpenAI {
    let token = apiKey ?? ""
    if token.isEmpty {
        throw StreamError.missingApiKey(model.provider)
    }

    let url = URL(string: model.baseUrl)
    let host = url?.host ?? "api.openai.com"
    let scheme = url?.scheme ?? "https"
    let port = url?.port ?? 443
    let basePath = url?.path.isEmpty == false ? url!.path : "/v1"
    var mergedHeaders = model.headers ?? [:]
    if let headers {
        for (key, value) in headers {
            mergedHeaders[key] = value
        }
    }

    let configuration = OpenAI.Configuration(
        token: token,
        organizationIdentifier: nil,
        host: host,
        port: port,
        scheme: scheme,
        basePath: basePath,
        timeoutInterval: 60,
        customHeaders: mergedHeaders
    )

    return OpenAI(configuration: configuration, middlewares: middlewares)
}
