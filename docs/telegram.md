# Telegram gateway

BotChu can take messages from Telegram: your private chat with a Telegram bot of your own reaches
one of your BotChu bots, in its Home, and the bot's replies come back to that chat. From the same
chat you can talk to any other BotChu bot with `@`, name a repository with `#`, and start a task
of its own with `/task` ([Choosing a bot, a repository or a task](#choosing-a-bot-a-repository-or-a-task)).
BotChu stays the runtime: the turn runs on this Mac with the bot's own CLI, account, memory and
conversation, and Telegram only carries the messages. It is off until you turn it on.

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
5. Optional, for lists to choose bots and repositories from while you type: in BotFather, send
   `/setinline`, choose your bot, and give the placeholder `@bot or #repository`. BotChu needs no
   other change. Without it, typing `@Name` and `#owner/repo` works the same, without the lists.

## What it does

- **Where messages go:** text from an allowed chat goes into its bot's Home through the Home's
  queue, as a message typed in BotChu does. That's the bot chosen for the chat in Settings, or the
  one the chat chose with `@`. The exchange is part of the Home conversation, and the turn resumes
  the Home's CLI session on its account, model and effort. Several chats can reach the same bot;
  they share its Home. `/task` starts a task of its own, whose conversation stays in BotChu. An
  existing task's conversation can't be reached from Telegram.
- **While a turn works:** a message waits in the queue and the chat is told so. Claude Code on this
  Mac takes it when its current step ends; every other account gets it as the next turn. If the queue
  is paused (after Stop or a failed turn), the chat is told once, and the message waits until you
  choose **Send next** in BotChu. At most **10 accepted messages per chat**, and **100 across the
  gateway**, can be waiting for replies. Further messages aren't queued: send them again once
  replies arrive. The gateway says "Too many messages are waiting" at most once per minute per
  chat while it runs. Pending replies still count toward these limits after a relaunch.
- **Replies:** a short digest of the turn's final written answer, up to your next message. It
  selects complete sentences and bullets directly from that answer, leading with the result and
  reserving room for decisions, blockers, failed checks and uncertainty, even at the end of a long
  answer. Caveats and questions from earlier assistant updates are retained with an explicit
  "Earlier in this turn" label; a short final answer cannot silently erase them. It usually fits
  in one message (about 1,400 UTF-16 units). Progress chatter, tool events,
  raw payloads and long log/code dumps are left out. If important caveats cannot all fit, the
  digest explicitly says it is incomplete and points to `/details`; it never calls a shortened
  answer successful just because its beginning did. Failed and stopped turns lead with that state
  and a safe next action; raw error text stays in BotChu. A turn ending with tools and no final
  answer says so instead of presenting earlier progress as a result.
- **Formatting:** replies use plain text without link previews or a Markdown parse mode. Headings
  and emphasis become ordinary text, bullets stay readable, links retain their label and real
  address, and short code examples are kept. Special characters cannot break Telegram formatting.
  All messages remain within 4,096 UTF-16 units, split at paragraph, line or word boundaries when
  necessary. A character that itself exceeds that limit is replaced with `�`; the original stays
  in BotChu.
- **Full detail:** the complete exchange stays unchanged in the bot's Home in BotChu. `/details`
  retrieves the last reply successfully delivered to this chat, one page at a time; `/details 2`
  retrieves page 2, and so on. Each page says the bot's name and page count and offers the next
  command. It reads the saved assistant text, including its intermediate explanations, without
  starting a CLI turn or adding a message to Home. Tools and raw errors remain in BotChu. The
  pointer survives relaunches and belongs to this allowed chat and its mapping in Settings; another
  chat cannot retrieve it. Changing the chat's bot in Settings or removing the chat discards it.
  Choosing another bot with `@` keeps the last delivered reply until the new bot answers. A
  `/details` request is best effort like `/help`; send it again if the gateway is temporarily busy.
  A multipart reply partly sent by the older gateway finishes in its original format on upgrade.
  What you type in BotChu in the same conversation, and its replies, stay in BotChu.
- **Text only:** a photo, file, voice note, sticker or location gets a reply saying only text
  reaches the bot. Editing a sent message gets a reply saying the bot has it as first sent.
  Forwarded messages, including forwarded channel posts, and messages sent via another bot are
  refused with an explanation, even when they contain text or a command. Write your own message.
  A choice from your own bot's `@`/`#` list is the one exception: it's taken as a choice and
  nothing else. `/start` and `/help` say which bot the chat reaches when sent directly.

## Choosing a bot, a repository or a task

A message can start with these words, in any order, each once. They choose; what follows is the
message:

| Start a message with | What it does | How long it lasts |
|---|---|---|
| `@Danny` (a BotChu bot's whole name) | The message and those after it go to Danny's Home. Danny's replies start with `Danny:`. | Until you choose another bot with `@`, or Settings gives the chat another bot. `@` and the name of the chat's own bot goes back to it. |
| `#owner/repo` (or `#repo` when only one of your Projects has that name) | Names the repository for that message. It reaches the bot as a `#` mention, as it does from BotChu's message box. | That message only. Sent alone, it goes with your next message. |
| `/task` | Starts a task of its own for the bot, in the repository named, with the rest of the message as its brief. | That message. |

- **Examples:** `@Danny what's on today?` · `@QA Duck #asieke/BotChu does the login work?` ·
  `/task @Danny #asieke/BotChu Fix the login bug`. Sent alone, `@Danny` only switches the chat
  to Danny. `#asieke/BotChu`, then `/task Fix the login bug`, starts that task for the bot the
  chat talks to.
- **Bots** are matched by their whole name, ignoring case and accents, never by part of a name.
  When two bots share a name, the gateway lists them with the start of their IDs: write
  `@Danny [1a2b3c4d]`. Repositories come from BotChu's Projects, as `#` completes them on the Mac.
  `#` with a word that names none of them (a hashtag), or with digits alone (an issue), is just
  text.
- **Nothing is guessed.** `@` with a name that matches no bot (deleted, renamed or mistyped), or
  `#owner/repo` that isn't in your Projects, sends nothing, and the chat is told why. A bot you chose
  that is later deleted isn't replaced by the chat's own bot: messages are refused until you
  choose another. Before Projects have been loaded, `#owner/repo` can't be checked, so it's
  refused too.
- **Tasks** are top-level tasks of the chosen bot, made as New Task makes them. Each runs in its own
  worktree on the bot's account, has its own conversation and session, and shows under that bot in
  BotChu's sidebar. It isn't a sub-agent of another bot, and nothing is nested under the chat's own
  bot. A task needs a repository: `/task` without one starts nothing. The chat is told the task
  started; what it does stays in BotChu. Telegram sending the request again finds the same task.
- **Changing who you talk to** moves nothing already sent. Messages queued for a bot stay in its
  queue, and replies owed go to the chat that asked, from the bot that took the message. Each chat
  has its own choice.

### Lists while you type (inline mode)

With inline mode on (step 5 above), type `@` in your chat with the bot. Telegram offers your bot,
once you have used it this way. Choose it, or type `@yourbot ` in full: Telegram then sends what
you type next to BotChu, and BotChu answers with a list above the message box.

- Nothing more, or `@` and part of a name: your BotChu bots, filtered by name or title, each with
  its title. Two bots with the same name show the start of their IDs. The bot you talk to now says
  so.
- `#` and part of a name: your repositories as `owner/repo`, filtered by name or `owner/repo`,
  with the project's name, status and where it works.
- Bots and repositories are never in the same list. `@Danny #bo` lists repositories, and choosing
  one chooses both.

**Telegram sends a list item as soon as you tap it, and empties the message box.** So choosing
sends a short message through your bot (`@Danny`, `#asieke/BotChu`, or both), which BotChu takes
as a choice: it starts no turn and no task, and the chat says what was chosen. Then write your
message. The list only appears while the box holds `@`/`#` choices. Once you've started writing a
message, nothing is offered, so a tap can't lose your draft. If you write your message after
`@yourbot @Danny` and send it without tapping, BotChu leaves out `@yourbot` and takes the rest as
usual.

### What Telegram can't do

The Bot API (version 10.3, checked October 2026) has no way for a bot to show its own list while
you type `@` or `#` in an ordinary message, or to put a choice into a draft without sending it:

- **Inline mode** is the only list that follows what you type, and choosing from it sends.
- **Typing `@`** offers Telegram's recently used inline bots, not entries a bot defines.
- **Typing `#`** offers hashtags you've used before. A hashtag stops at `/`, so `owner/repo` can't
  be one.
- **Typing `/`** offers the bot's commands, from a fixed list of at most 100. Choosing one sends
  it.
- **Buttons** on a bot's message can put text into the box without sending it, but only after the
  bot has sent that message.
- **A Mini App** could offer real completion in a page of its own. It needs a web page on a server,
  and BotChu has none.

So `@`/`#` completion inside a draft, with nothing sent until you send it, isn't possible.
Choose first, then write.

## Who can reach it

Nobody, until you allow a chat. A message is ignored, before BotChu reads it or says anything,
unless it comes from a private chat listed in Settings and is sent by that chat's own user, not a
bot. Groups and channels are never accepted, even if you list their ID. Refused senders get no
answer. Settings lists the last five chats refused since BotChu started, kept in memory only, so
you can allow your own. An allowed chat can choose any of your BotChu bots with `@`. The `@`/`#`
lists answer only that chat's own user, typing in their chat with your bot. Typed in another
chat, or by anyone else, they get no answer, so your bots' and repositories' names stay private.
Removing a chat in Settings, changing its bot there, or turning the gateway off prevents further
messages from an already-fetched batch from reaching a Home or starting a task. Every reply,
typing indicator and gateway notice rechecks the current authorization and mapping.
Removing a chat, or giving it another bot in Settings, discards its outstanding Telegram replies,
including those owed by a bot it chose with `@`, and drops what it chose. Turning the gateway off
keeps valid pending replies and choices for when it is enabled again. Work already accepted into
Home stays there, and an outgoing request already in flight may finish.

## Secrets and what is kept

- **The token** is kept in the Keychain (service `local.BotChu`; a review copy from `ui-review.sh`
  keeps its own). It is never in the repository, a log, a conversation, a prompt or an error
  message: errors never include the request's address, which holds the token. **Remove** in
  Settings deletes it from the Keychain; `/revoke` in BotFather makes it useless everywhere.
- **`telegram.json`**, in `~/Library/Application Support/BotChu/`, keeps the Telegram bot's numeric
  ID, where its updates are up to, the replies owed (IDs only, no message text), and what each chat
  chose with `@` and `#`: a bot's ID and name, and a repository's `owner/repo`. It also keeps the IDs
  of each chat's last delivered reply so `/details` can read it from Home. The offset, pending
  replies and choices belong to that Telegram identity. Replacing its token with another token for
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
- **"No BotChu bot is called …"**: the name after `@` matches no bot as a whole. The answer lists
  your bots' names.
- **"More than one bot is called …"**: start the message with one of the `@Name [id]` forms the
  answer gives.
- **"… isn't in BotChu any more, so this message wasn't sent"**: the bot the chat chose was
  deleted. Choose another with `@`.
- **"… isn't in your Projects in BotChu"** or **"BotChu hasn't loaded your Projects yet"**: check
  the repository in BotChu's Projects, then send the message again.
- **"A task works in a repository"**: `/task` needs `#owner/repo`, in the same message or chosen
  just before it.
- **No list after `@yourbot`**: inline mode is off for your bot (BotFather `/setinline`), or
  BotChu isn't running.

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

Then choosing, with inline mode on (setup step 5), in each Telegram app you use:

10. Type `@`, choose your bot, then type part of a bot's name: the list shows matching BotChu
    bots with their titles, not Telegram users. Type `#` and part of a repository's name: only
    repositories, as `owner/repo`.
11. Tap a bot: the chat sends `@Name` through your bot and says who you're talking to now. No
    turn starts. Send "hello": that bot's Home answers, as `Name:`, in this chat. Send
    `@yourbot @Name #bo`, choose a repository, then send a message: it reaches that bot with the
    repository as a `#` mention.
12. Send `/task #owner/repo Add a test`: the chat says the task started, and BotChu's sidebar
    shows it under the chosen bot, with its own conversation, not under the chat's own bot.
13. Choose a bot, ask it something slow, choose another bot and ask again: each answer comes back
    from the bot that was asked. Delete a chosen bot in BotChu: the next message is refused, not
    sent to another bot.

**Clients checked by hand:** none yet. The steps above need checking in Telegram for iOS,
Android, macOS, Desktop (Windows/Linux) and Web. Write down which ones you checked, and anything
that differs, such as whether typing `@` offers your bot.

### Readability check for concise replies (#164)

Run this only when the owner authorizes a real exchange with their Telegram bot. Implementation
checks use a stand-in; no real Telegram messages were sent for #164.

1. Ask for a result with a long explanation and a decision at its end. Confirm the phone receives
   one useful digest with the result, uncertainty and question visible, rather than multiple raw
   output messages. Compare it with the full Home answer.
2. Ask for a tool-heavy task with a final summary. Confirm no commands, raw payloads or logs arrive
   by default, while the final finding and next action do.
3. Check a partial failure, a blocked decision, and a turn stopped in BotChu. Confirm each says
   what is incomplete and what to do next, without leaking raw error text.
4. Include bullets, an ordinary link, a short code example, emoji, `&`, `<`, underscores and
   punctuation. Confirm they remain readable in the Telegram client used.
5. Send `/details`, then its offered next-page command. Confirm the original answer is available
   in order, one page per request, including after relaunch, with no extra Home turn. Check that
   another chat cannot retrieve it and that remapping the chat clears it.

Record the client/version, the digest and Home comparison, and any readability problem before
claiming a real-device check. This remains an owner-authorized check to perform after deployment.
