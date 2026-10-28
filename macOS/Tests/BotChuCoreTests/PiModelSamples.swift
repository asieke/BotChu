// Pi 1.4.0 get_available_models on 2026-10-28; only non-secret model metadata, one entry per provider.
enum PiModelSamples     {
        static let available = #"""
    {
      "id": "botchu-catalog",
      "type": "response",
      "command": "get_available_models",
      "success": true,
      "data": {
        "models": [
          {
            "id": "muse-spark-1.1",
            "name": "Muse Spark 1.1",
            "provider": "meta",
            "reasoning": true,
            "api": "openai-responses"
          },
          {
            "id": "kimi-k3",
            "name": "Kimi K3",
            "provider": "radius",
            "reasoning": true,
            "api": "pi-messages"
          },
          {
            "id": "gpt-5.3-codex-spark",
            "name": "GPT-5.3 Codex Spark",
            "provider": "garcon",
            "reasoning": true,
            "api": "openai-responses"
          }
        ]
      }
    }
    """#
}
