// Pi 1.4.0 get_available_models on 2026-10-28. Only non-secret model metadata is retained.
// Includes the runtime-reported effort maps; no auth files were read or copied.
enum PiModelSamples {
    // Real `pi auth check --provider <id> --json --no-refresh` replies, 2026-10-28.
    // The credentials-output option is never requested.
    static let authReady = #"{"status":"ready","provider":"radius","authType":"oauth"}"#
    static let authMissing = #"{"status":"not_ready","provider":"kimi-coding","reason":"credentials_not_configured"}"#

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
            "thinkingLevelMap": {
              "off": null,
              "minimal": "minimal",
              "low": "low",
              "medium": "medium",
              "high": "high",
              "xhigh": "xhigh",
              "max": null
            },
            "api": "openai-responses"
          },
          {
            "id": "kimi-k3",
            "name": "Kimi K3",
            "provider": "radius",
            "reasoning": true,
            "thinkingLevelMap": {
              "off": null,
              "minimal": null,
              "low": "low",
              "medium": null,
              "high": "high",
              "xhigh": null,
              "max": "max"
            },
            "api": "pi-messages"
          },
          {
            "id": "claude-opus-5-5",
            "name": "Claude Opus 5.5",
            "provider": "radius",
            "reasoning": true,
            "thinkingLevelMap": {
              "off": null,
              "minimal": null,
              "low": "low",
              "medium": "medium",
              "high": "high",
              "xhigh": "xhigh",
              "max": "max"
            },
            "api": "pi-messages"
          },
          {
            "id": "balanced",
            "name": "Balanced",
            "provider": "radius",
            "reasoning": true,
            "thinkingLevelMap": {
              "off": null,
              "minimal": null,
              "low": "low",
              "medium": null,
              "high": "high",
              "xhigh": null,
              "max": "max"
            },
            "api": "pi-messages"
          },
          {
            "id": "anthropic/claude-opus-4.6",
            "name": "Anthropic: Claude Opus 4.6",
            "provider": "openrouter",
            "reasoning": true,
            "thinkingLevelMap": {
              "off": "none",
              "minimal": null,
              "low": "low",
              "medium": "medium",
              "high": "high",
              "xhigh": null,
              "max": "max"
            },
            "api": "anthropic-messages"
          },
          {
            "id": "anthropic/claude-sonnet-4.5",
            "name": "Anthropic: Claude Sonnet 4.5",
            "provider": "openrouter",
            "reasoning": true,
            "api": "anthropic-messages"
          }
        ]
      }
    }
    """#
}
