import Foundation

/// `muse serve`'s `model/list` result, captured on 2026-10-28 (#248) from the built-in Muse account
/// (Muse Code 1.4.14), read-only: `initialize`, `initialized`, then `model/list` with no params.
/// Nothing in it names the account.
enum MuseModelSamples {
    /// Run with Muse's own data folder, which keeps the provider's catalog: every model the account offers.
    static let provider = #"""
    {"providerId":"meta","profileId":"tbh","source":"providerCatalog","models":[{"modelId":"muse-wonder-1.0","displayLabel":"muse-wonder-1.0","providerId":"meta","profileId":"tbh","releaseDate":"2026-10-12","description":null,"contextLimit":1007997,"outputLimit":128000,"cost":null,"isActive":false,"isDefault":true,"variants":["minimal","low","medium","high","xhigh","max"],"reasoningEffortVariants":[],"defaultReasoningEffort":"high"},
    {"modelId":"muse-wonder-full-1.0","displayLabel":"muse-wonder-full-1.0","providerId":"meta","profileId":"tbh","releaseDate":"2026-10-12","description":null,"contextLimit":1007997,"outputLimit":128000,"cost":null,"isActive":false,"isDefault":false,"variants":["minimal","low","medium","high","xhigh","max"],"reasoningEffortVariants":[],"defaultReasoningEffort":"high"},
    {"modelId":"muse-spark-1.3","displayLabel":"muse-spark-1.3","providerId":"meta","profileId":"tbh","releaseDate":"2026-09-02","description":null,"contextLimit":1007997,"outputLimit":128000,"cost":null,"isActive":false,"isDefault":false,"variants":["minimal","low","medium","high","xhigh","max"],"reasoningEffortVariants":[],"defaultReasoningEffort":"max"},
    {"modelId":"muse-spark-1.2","displayLabel":"muse-spark-1.2","providerId":"meta","profileId":"tbh","releaseDate":"2026-08-05","description":null,"contextLimit":1007997,"outputLimit":128000,"cost":null,"isActive":false,"isDefault":false,"variants":["minimal","low","medium","high","xhigh"],"reasoningEffortVariants":[{"tier":"xhigh","description":"Use this for deepest analysis and complex fixes."}],"defaultReasoningEffort":"high"}]}
    """#

    /// The same query with an empty data folder (`XDG_DATA_HOME` set to a new one): Muse's bundled
    /// fallback, a single model, which isn't the account's list.
    static let bundled = #"""
    {"providerId":"meta","profileId":"tbh","source":"bundledCatalog","models":[{"modelId":"muse-wonder-full-1.0","displayLabel":"muse-wonder-full-1.0","providerId":"meta","profileId":null,"releaseDate":null,"description":null,"contextLimit":null,"outputLimit":null,"cost":null,"isActive":false,"isDefault":false,"variants":["minimal","low","medium","high","xhigh"],"reasoningEffortVariants":[],"defaultReasoningEffort":"high"}]}
    """#
}
