import Foundation
import Testing
@testable import BotChuCore

/// A delivery's banner while BotChu is in the background, and what a click on it asks for.
struct DeliveryBannerTests {
    let fox = UUID()

    @Test func aQuestionShowsWithAButtonPerChoiceAndReply() {
        let delivery = Delivery(botID: fox, title: "Should sub-agent work block Telegram?", note: "# Report\n\nLong findings",
                                question: Delivery.Question(text: "Which should I file?", choices: ["Answer first", "Hold, but say so"]),
                                credits: [Delivery.Credit(botID: UUID(), name: "Research Assistant")])
        let banner = DeliveryBanner(delivery: delivery, sender: "Product Fox")
        #expect(banner.title == "Product Fox with Research Assistant")
        #expect(banner.subtitle == "Should sub-agent work block Telegram?")
        #expect(banner.body == "Which should I file?")
        #expect(banner.category.identifier == "inbox.choices.\(delivery.id.uuidString.lowercased())")
        #expect(banner.category.choices == ["Answer first", "Hold, but say so"])
        #expect(banner.category.replyPlaceholder == "Reply to Product Fox")
        #expect(banner.category.actions == [.choice(0), .choice(1), .reply])
        #expect(banner.userInfo[DeliveryBanner.deliveryKey] as? String == delivery.id.uuidString)
    }

    @Test func withoutChoicesItSharesItsSendersReplyCategory() {
        let first = DeliveryBanner(delivery: Delivery(botID: fox, title: "A", note: "One"), sender: "Fox")
        let second = DeliveryBanner(delivery: Delivery(botID: fox, title: "B", question: Delivery.Question(text: "Go?")), sender: "Fox")
        let other = DeliveryBanner(delivery: Delivery(botID: UUID(), title: "C"), sender: "Duck")
        #expect(first.category == second.category && first.category.choices.isEmpty)
        #expect(first.category.identifier == "inbox.reply.\(fox.uuidString.lowercased())")
        #expect(other.category.identifier != first.category.identifier && other.category.replyPlaceholder == "Reply to Duck")
        #expect(first.category.actions == [.reply])
        #expect(second.body == "Go?")
    }

    @Test func choicesStopAtTheSystemsLimitWithReplyLast() {
        let choices = (1...12).map { "Option \($0)" }
        let banner = DeliveryBanner(delivery: Delivery(botID: fox, title: "Pick", question: Delivery.Question(text: "Which?", choices: choices)),
                                    sender: "Fox")
        #expect(banner.category.actions.count == DeliveryBanner.maxActions)
        #expect(banner.category.actions.last == .reply && banner.category.choices.last == "Option 9")
    }

    @Test func theSenderNamesEachCreditedBot() {
        let credit = { Delivery.Credit(botID: UUID(), name: $0) }
        #expect(DeliveryBanner.sender("Fox", credits: []) == "Fox")
        #expect(DeliveryBanner.sender("Fox", credits: [credit("Duck"), credit("Racoon")]) == "Fox with Duck and Racoon")
        #expect(DeliveryBanner.sender("Fox", credits: [credit("Duck"), credit("Racoon"), credit("Pixel")]) == "Fox with Duck, Racoon and Pixel")
    }

    @Test func theNoteShowsAsPlainTextFromItsFirstParagraph() {
        #expect(DeliveryBanner.plainText("# Merged 4 pull requests\n\nMore") == "Merged 4 pull requests")
        #expect(DeliveryBanner.plainText("\n\n**#150–#153** in `asieke/BotChu`. Nothing is _deployed_.\nSee [the PR](https://x.y/1).\n\nLater")
                == "#150–#153 in asieke/BotChu. Nothing is deployed. See the PR.")
        #expect(DeliveryBanner.plainText("- [x] first\n- second\n1. third\n> fourth") == "first second third")
        #expect(DeliveryBanner.plainText("> quoted *text* in snake_case_name") == "quoted text in snake_case_name")
        #expect(DeliveryBanner.plainText("```swift\nlet x = 1\n```") == "let x = 1")
        #expect(DeliveryBanner.plainText("") == "")
        let long = DeliveryBanner.plainText(String(repeating: "word ", count: 100))
        #expect(long.count == DeliveryBanner.maxBody && long.hasSuffix("…"))
    }

    @Test func aClickBecomesAReplyOrOpensTheDelivery() {
        let delivery = Delivery(botID: fox, title: "Pick", question: Delivery.Question(text: "Which?", choices: ["Answer first", "Hold"]))
        let info = DeliveryBanner(delivery: delivery, sender: "Fox").userInfo as [AnyHashable: Any]
        #expect(DeliveryBanner.response(action: "choice.1", userInfo: info, text: nil)
                == DeliveryBanner.Response(deliveryID: delivery.id, kind: .reply("Hold")))
        #expect(DeliveryBanner.response(action: "reply", userInfo: info, text: "  Do both ")
                == DeliveryBanner.Response(deliveryID: delivery.id, kind: .reply("  Do both ")))
        #expect(DeliveryBanner.response(action: "open", userInfo: info, text: nil) == DeliveryBanner.Response(deliveryID: delivery.id, kind: .open))
        // Nothing to send, a button it didn't have, or a notification that isn't a delivery's.
        #expect(DeliveryBanner.response(action: "reply", userInfo: info, text: " \n") == nil)
        #expect(DeliveryBanner.response(action: "choice.2", userInfo: info, text: nil) == nil)
        #expect(DeliveryBanner.response(action: "dismiss", userInfo: info, text: nil) == nil)
        #expect(DeliveryBanner.response(action: "open", userInfo: [:], text: nil) == nil)
    }

    @Test func actionIdentifiersReadBack() {
        for action in [DeliveryBanner.Action.choice(0), .choice(5), .reply, .open] {
            #expect(DeliveryBanner.Action(identifier: action.identifier) == action)
        }
        #expect(DeliveryBanner.Action(identifier: "choice.-1") == nil && DeliveryBanner.Action(identifier: "choice.x") == nil)
    }

    @Test func theRegisteredCategoriesKeepTheNewest() {
        var categories = BannerCategories()
        let made = (0..<(DeliveryBanner.keptCategories + 5)).map {
            DeliveryBanner.Category(identifier: "inbox.choices.\($0)", choices: ["Yes"], replyPlaceholder: "Reply to Fox")
        }
        for category in made {
            let changed = categories.add(category)
            #expect(changed)
        }
        #expect(categories.all == Array(made.suffix(DeliveryBanner.keptCategories)))
        // The newest again changes nothing; an older one comes last.
        let again = categories.add(made.last!)
        #expect(!again)
        let older = categories.add(made[10])
        #expect(older && categories.all.last == made[10] && categories.all.count == DeliveryBanner.keptCategories)
    }
}
