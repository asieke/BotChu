// Captured from native usage commands on 2026-10-22; account IDs, credit IDs,
// balances and unrelated session attribution removed. No credentials are captured.
import Foundation

enum UsageSamples {
    static let claude = Data(#"""
{
  "is_error": false,
  "subtype": "success",
  "result": "You are currently using your subscription to power your Claude Code usage\n\nCurrent session: 0% used\nCurrent week (all models): 8% used \u00b7 resets Oct 26 at 9am (America/New_York)\nCurrent week (Fable): 7% used \u00b7 resets Oct 26 at 9am (America/New_York)",
  "type": "result"
}
"""#.utf8)
    static let codex = Data(#"""
{
  "id": 2,
  "result": {
    "ordinaryUsageAllowed": false,
    "rateLimits": {
      "limitId": "codex",
      "limitName": null,
      "normalModelSlug": null,
      "primary": {
        "usedPercent": 100,
        "windowDurationMins": 10080,
        "resetsAt": 1793106332
      },
      "secondary": null,
      "individualLimit": null,
      "spendControlReached": false,
      "planType": "prolite",
      "rateLimitReachedType": "rate_limit_reached"
    },
    "rateLimitsByLimitId": {
      "codex": {
        "limitId": "codex",
        "limitName": null,
        "normalModelSlug": null,
        "primary": {
          "usedPercent": 100,
          "windowDurationMins": 10080,
          "resetsAt": 1793106332
        },
        "secondary": null,
        "individualLimit": null,
        "spendControlReached": false,
        "planType": "prolite",
        "rateLimitReachedType": "rate_limit_reached"
      }
    },
    "rateLimitUpsell": null
  }
}
"""#.utf8)
    /// `account/rateLimits/read` from Codex on 2026-10-24, with usage credits and two free resets;
    /// limit, account and credit IDs removed and the balance replaced.
    static let codexCredits = Data(#"""
{
  "id": 2,
  "result": {
    "ordinaryUsageAllowed": true,
    "rateLimits": {
      "limitName": null,
      "normalModelSlug": null,
      "primary": {
        "usedPercent": 0,
        "windowDurationMins": 10080,
        "resetsAt": 1793413951
      },
      "secondary": null,
      "credits": {
        "hasCredits": true,
        "unlimited": false,
        "balance": "1234.5678900000"
      },
      "individualLimit": null,
      "spendControlReached": false,
      "planType": "prolite",
      "rateLimitReachedType": null
    },
    "rateLimitsByLimitId": {
      "codex": {
        "limitName": null,
        "normalModelSlug": null,
        "primary": {
          "usedPercent": 0,
          "windowDurationMins": 10080,
          "resetsAt": 1793413951
        },
        "secondary": null,
        "credits": {
          "hasCredits": true,
          "unlimited": false,
          "balance": "1234.5678900000"
        },
        "individualLimit": null,
        "spendControlReached": false,
        "planType": "prolite",
        "rateLimitReachedType": null
      }
    },
    "rateLimitResetCredits": {
      "availableCount": 2,
      "credits": [
        {
          "resetType": "codexRateLimits",
          "status": "available",
          "grantedAt": 1790707644,
          "expiresAt": 1793299644,
          "title": "Full reset",
          "description": "Thanks for using Codex! You've been granted one free rate limit reset."
        },
        {
          "resetType": "codexRateLimits",
          "status": "available",
          "grantedAt": 1791415201,
          "expiresAt": 1794007201,
          "title": "Full reset",
          "description": "Thanks for using Codex! You've been granted one free rate limit reset."
        }
      ]
    },
    "rateLimitUpsell": null
  }
}
"""#.utf8)
    static let antigravity = Data(#"""
{
  "command": {
    "name": "usage",
    "data": {
      "description": "Within each group, models share a weekly limit and a 5-hour limit. Quota is consumed proportionally to the cost of the tokens. Thus, limits will last longer with shorter tasks or using more cost-effective models. The 5-hour limit smooths out aggregate demand to fairly distribute global capacity across all users, while your weekly limit is tied directly to your individual tier.",
      "groups": [
        {
          "name": "Gemini Models",
          "description": "Models within this group: Gemini Flash, Gemini Pro",
          "buckets": [
            {
              "id": "gemini-weekly",
              "name": "Weekly Limit Remaining",
              "description": "You have used some of your weekly limit, it will fully refresh in 2 days, 5 hours.",
              "window": "weekly",
              "remaining_fraction": 0.9456038475036621,
              "reset_time": "2026-10-24T20:49:24Z"
            },
            {
              "id": "gemini-5h",
              "name": "Five Hour Limit Remaining",
              "description": "You have used some of your 5-hour limit, it will fully refresh in 1 hour, 33 minutes.",
              "window": "5h",
              "remaining_fraction": 0.9580668807029724,
              "reset_time": "2026-10-22T16:31:16Z"
            }
          ]
        },
        {
          "name": "Claude and GPT models",
          "description": "Models within this group: Claude Opus, Claude Sonnet, GPT-OSS",
          "buckets": [
            {
              "id": "3p-weekly",
              "name": "Weekly Limit Remaining",
              "window": "weekly",
              "remaining_fraction": 1,
              "reset_time": "2026-10-29T14:57:22Z"
            },
            {
              "id": "3p-5h",
              "name": "Five Hour Limit Remaining",
              "window": "5h",
              "remaining_fraction": 1,
              "reset_time": "2026-10-22T19:57:22Z"
            }
          ]
        }
      ]
    }
  }
}
"""#.utf8)
    static let muse = Data(#"""
{
  "window": {
    "usedPercent": 3,
    "windowDurationMins": 300,
    "resetsAtMs": 1792687416000
  },
  "weekly": {
    "usedPercent": 20,
    "resetsAtMs": 1792972800000
  },
  "observedAtMs": 1792681252222
}
"""#.utf8)
    /// `usage/read`'s answer from Muse 1.4.12 on 2026-10-24, after the probe's turn; its numeric
    /// tier ID replaced.
    static let museRead = Data(#"""
{
  "usage": {
    "observedAtMs": 1792844187798,
    "tier": "0",
    "weekly": {
      "resetsAtMs": 1792972800000,
      "usedPercent": 34
    },
    "window": {
      "resetsAtMs": 1792854028000,
      "usedPercent": 5,
      "windowDurationMins": 300
    }
  }
}
"""#.utf8)
}
