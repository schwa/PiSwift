import Foundation
import Testing
import PiSwiftAI
import PiSwiftCodingAgent

@Test func modelRegistryParsesCompatRouting() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("pi-models-compat-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    let modelsPath = tempDir.appendingPathComponent("models.json")

    let json = """
    {
      "providers": {
        "openrouter": {
          "baseUrl": "https://openrouter.ai/api/v1",
          "models": [
            {
              "id": "test-model",
              "name": "Test Model",
              "api": "openai-completions",
              "reasoning": false,
              "input": ["text"],
              "cost": {
                "input": 1,
                "output": 2,
                "cacheRead": 0,
                "cacheWrite": 0
              },
              "contextWindow": 8192,
              "maxTokens": 4096,
              "compat": {
                "openRouterRouting": {
                  "only": ["openai", "anthropic"],
                  "order": ["anthropic"]
                },
                "vercelGatewayRouting": {
                  "only": ["openai"]
                }
              }
            }
          ]
        }
      }
    }
    """
    try json.data(using: .utf8)?.write(to: modelsPath)

    let authStorage = AuthStorage(":memory:")
    let registry = ModelRegistry(authStorage, tempDir.path)
    guard let model = registry.find("openrouter", "test-model") else {
        #expect(Bool(false), "Expected test model to be available")
        return
    }

    #expect(model.compat?.openRouterRouting?.only == ["openai", "anthropic"])
    #expect(model.compat?.openRouterRouting?.order == ["anthropic"])
    #expect(model.compat?.vercelGatewayRouting?.only == ["openai"])
}

