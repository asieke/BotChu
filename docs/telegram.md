# Telegram gateway

BotChu can take messages from Telegram: your private chat with a Telegram bot of your own reaches
one of your BotChu bots, in its Home, and the bot's replies come back to that chat. BotChu stays
the runtime: the turn runs on this Mac with the bot's own CLI, account, memory and conversation,
and Telegram only carries the messages. It is off until you turn it on.

There is no server or webhook. While BotChu runs, it asks Telegram for new messages itself (long
polling, `getUpdates`), so nothing on this Mac has to be reachable from the internet.

## Setting it up

1. In Telegram, open [@BotFather](https://t.me/BotFather), send `/newbot`, and give the bot a name
   and a username. BotFather answers with a token such as `123456789:AA…`. Treat it as a password:
   anyone with it can read and send the bot's messages. While you're there, `/setjoingroups` →
   **Disable** keeps anyone from adding the bot to a group.
2. In BotChu ▸ Settings ▸ **Telegram**, paste the token, choose **Save**, and turn on **Reach bots
   from Telegram**. The status says **Connected as @yourbot**.
3. In Telegram, open your bot (`t.me/<username>`) and send it anything. Nothing is allowed yet, so
   BotChu ignores it, and Settings lists it as **Refused** with your name and chat ID. Choose
   **Allow**. You can also type the ID under **Chat ID** and choose **Allow Chat**. A private
   chat's ID is your Telegram user ID: the number Settings shows when you message the bot.
4. Choose the bot that chat reaches (it starts as the bot selected in BotChu). Send a message:
   Telegram shows "typing…" while the bot works, and its reply comes back as a reply to your
   message.

## What it does

- **Where messages go:** text from an allowed chat goes into its bot's Home through the Home's
  queue, as a message typed in BotChu does. The exchange is part of the Home conversation, and the
  turn resumes the Home's CLI session on its account, model and effort. Several chats can reach the
  same bot; they share its Home. Tasks can't be reached from Telegram, but Home can still start
  tasks and hear how they went.
- **While a turn works:** a message waits in the queue and the chat is told so. Claude Code on this
  Mac takes it at its next tool call; every other account gets it as the next turn. If the queue
  is paused (after Stop or a failed turn), the chat is told once, and the message waits until you
  choose **Send next** in BotChu. At most **10 accepted messages per chat**, and **100 across the
  gateway**, can be waiting for replies. Further messages aren't queued: send them again once
  replies arrive. The gateway says "Too many messages are waiting" at most once per minute per
  chat while it runs. Pending replies still count toward these limits after a relaunch.
- **Replies:** what the turn wrote after your message, up to your next message. It goes as plain
  text, so Markdown shows as written and nothing in a reply can break its formatting, without link
  previews. A reply longer than 4,096 UTF-16 units is split where a paragraph, line or word
  ends; after eight messages it says the rest is in BotChu. An individual character that exceeds
  that limit (for example, thousands of combining accents) is replaced with `�`; the original stays
  in BotChu. A failed or stopped turn says so, and
  the error itself stays in BotChu. What you type in BotChu in the same conversation, and its
  replies, stay in BotChu.
- **Text only:** a photo, file, voice note, sticker or location gets a reply saying only text
  reaches the bot. Editing a sent message gets a reply saying the bot has it as first sent.
  Forwarded messages, including forwarded channel posts, and messages sent via another bot are
  refused with an explanation, even when they contain text or a command. Write your own message.
  `/start` and `/help` say which bot the chat reaches when sent directly.

## Who can reach it

Nobody, until you allow a chat. A message is ignored, before BotChu reads it or says anything,
unless it comes from a private chat listed in Settings and is sent by that chat's own user, not a
bot. Groups and channels are never accepted, even if you list their ID. Refused senders get no
answer. Settings lists the last five chats refused since BotChu started, kept in memory only, so
you can allow your own. Removing a chat in Settings, changing its chosen bot, or turning the
gateway off prevents further messages from an already-fetched batch from reaching Home. Every
reply, typing indicator and gateway notice rechecks the current authorization and mapping.
Removing or remapping a chat discards its outstanding Telegram replies. Turning the gateway off
keeps valid pending replies for when it is enabled again. Work already accepted into Home stays
there, and an outgoing request already in flight may finish.

## Secrets and what is kept

- **The token** is kept in the Keychain (service `local.BotChu`; a review copy from `ui-review.sh`
  keeps its own). It is never in the repository, a log, a conversation, a prompt or an error
  message: errors never include the request's address, which holds the token. **Remove** in
  Settings deletes it from the Keychain; `/revoke` in BotFather makes it useless everywhere.
- **`telegram.json`**, in `~/Library/Application Support/BotChu/`, keeps the Telegram bot's numeric
  ID, where its updates are up to, and the replies owed: IDs only, no message text. Both the offset
  and pending replies belong to that Telegram identity. Replacing its token with another token for
  the same bot preserves them; a token for a different bot starts clean. A replacement gateway
  waits for the previous run to finish before loading this file.
- **Telegram sees the messages.** A chat with a bot is a Telegram cloud chat, not end-to-end
  encrypted, so what you send and what the bot replies passes through Telegram's servers.

## When BotChu isn't running, or the Mac sleeps or is offline

Nothing answers then: the gateway runs inside BotChu, and Telegram doesn't wake the Mac. Telegram
keeps the bot's unread messages for up to 24 hours. When BotChu runs again, or the Mac wakes or
comes back online, it takes them in the order they were sent; older ones are gone. To answer while
you're away, the Mac has to stay awake with BotChu open.

A reply ready while the Mac is offline is tried again, with waits doubling up to five minutes,
until it goes. Replies owed survive a relaunch and go on from the first part not yet sent. If
BotChu quits during a turn, the reply is what the turn wrote before it stopped.

## Delivery

- **Each message runs once.** An update counts as handled once its message is in the queue, the
  reply it is owed is saved, and the offset past it is saved. Its message ID in the conversation is
  made from the Telegram bot, the chat and the message, so if Telegram sends it again (after a
  crash between those steps) BotChu recognizes it and doesn't start a second turn. If the state
  can't be saved, polling pauses until a checkpoint can be saved; BotChu won't acknowledge the
  update to Telegram without its reply obligation. Settings shows a storage error without paths
  or underlying error details.
- **Replies go at least once.** A send that may have reached Telegram (a timeout, a dropped
  connection, a server error) is tried again up to six times, so on a bad connection part of a
  reply can arrive twice. A send that can't have reached Telegram (offline), or that Telegram asks
  to wait with, is tried until it goes. One Telegram refuses (the bot was blocked, the chat is gone)
  isn't tried again; the Home conversation gets a note: "Couldn't send the reply to Telegram…".
- **Telegram's rate limits apply to the whole gateway.** A 429 response pauses all outgoing
  replies, notices and typing indicators for at least its `retry_after` interval, across all chats.
  Only one outgoing request is in flight at a time. Short gateway notices (help, busy, unsupported
  input and overflow) are best effort and can be skipped during a send or cooldown; owed replies
  and paused-queue notices wait and retry.
- **The status** in Settings says Connecting, Connected as @yourbot, why it is retrying and when it
  tries again, or why it stopped.

## Troubleshooting

- **"Telegram refused the bot token"**: the token was revoked or mistyped. Paste the current one
  from BotFather and choose **Save**.
- **"Another program is reading this bot's messages, or the bot has a webhook"**: Telegram lets one
  reader at a time take a bot's messages. Stop whatever else uses the token (BotChu on another Mac,
  a script), or delete the bot's webhook, then turn the gateway off and on again.
- **No reply**: check that BotChu is running, the chat is allowed and has a bot chosen, the Home's
  queue isn't paused, and what the Home conversation in BotChu says.
- **"This chat isn't connected to a bot yet"**: choose a bot for the chat in Settings.
- **"The bot this chat was connected to isn't in BotChu any more"**: the bot was deleted; choose
  another.
- **"Couldn't send the reply to Telegram"** in a conversation: Telegram refused the reply, or
  didn't take it after six tries. The reply is in the conversation.
- **"BotChu couldn't save Telegram's progress"**: check free storage space and write permissions
  for BotChu's data folder. Polling resumes after a successful save. An already accepted message
  can keep running in Home while the gateway waits.
- **"Too many messages are waiting"**: let pending replies finish, or resume a paused Home queue,
  then send the rejected message again.

## Checking it end to end

The automated tests use a stand-in for Telegram, so check a real exchange once with your own bot:

1. Set it up as above.
2. Send `/start`: the answer names the bot.
3. Send "Reply with the word pineapple.": Telegram shows "typing…", the reply says pineapple, as a
   reply to your message, and the bot's Home conversation in BotChu has both.
4. Send another message while a turn works: the chat says it is queued, and it is answered next.
5. Send a photo: the chat says only text reaches the bot. Forward a user message or channel post,
   and send text via an inline bot: each gets a refusal and starts no Home turn.
6. Message the bot from another Telegram account: nothing answers, and Settings lists it as
   refused.
7. Quit BotChu, send a message, and open BotChu again: it is answered, once.
8. Turn the gateway off: messages aren't answered until it is on again.
9. Remove or remap a chat while a reply is pending: its old reply must not arrive there.
