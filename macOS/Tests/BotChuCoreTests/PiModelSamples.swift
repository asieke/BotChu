import Foundation

/// Selected non-secret metadata from Pi 1.4.0 get_available_models, captured 2026-10-28 through
/// the legacy profile with its existing credential in process memory. No auth payload is saved.
enum PiModelSamples {
    static let openRouter = #"""
    {"id":"catalog","type":"response","command":"get_available_models","success":true,"data":{"models":[
      {"id":"anthropic/claude-sonnet-4.5","name":"Anthropic: Claude Sonnet 4.5","provider":"openrouter","reasoning":true},
      {"id":"moonshotai/kimi-k3","name":"MoonshotAI: Kimi K3","provider":"openrouter","reasoning":true,"thinkingLevelMap":{"off":"none","minimal":null,"low":"low","medium":null,"high":"high","xhigh":null,"max":"max"}}
    ]}}
    """#
}
