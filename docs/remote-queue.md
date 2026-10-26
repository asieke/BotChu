# Remote queue bots

A remote queue bot runs on its own computer. BotChu keeps its Home conversation and a durable
queue; the remote runtime polls for messages and posts one reply or error per message. Nothing
starts a CLI on this Mac. V1 supports one remote bot, text messages, and ten waiting messages.
It has no local workspace, provider/model settings, tasks, scheduled jobs or sub-agent runs.

## Setup

1. Choose **New Bot**, set **Kind** to **Remote queue**, and name it (for example Danny).
2. Open **Settings ▸ Remote queue**. Set **Listen address** to this Mac's numeric Tailscale IP
   and leave the port at **18765**, or choose another port. The default `127.0.0.1` is local-only.
3. Enable **Serve the remote queue**. BotChu generates a random 32-byte token and saves it in
   the Keychain. **Show** and **Copy** expose it only on request. Give it to the remote runtime
   through secure credential entry, never through a conversation. **Regenerate** invalidates
   the old token while keeping waiting messages.
4. The status says **Listening** and shows the base URL when the listener is ready. That
   address and port survive relaunches. If using a public tunnel, use its HTTPS URL; the listener
   itself speaks HTTP. Tailscale encrypts traffic between its peers.

The Mac must be awake and BotChu open. A successful queue poll in the last two minutes means
**Online**. Home remains working while messages wait, including while the remote runtime is
offline; turning the listener off keeps the queue. A full queue shows a notice and returns the
unaccepted message to the composer.

## Protocol

Every request includes `Authorization: Bearer <token>`. Missing or incorrect credentials receive
401 without queue information, including on the health and unknown routes. JSON uses UTF-8.

| Request | Response |
| --- | --- |
| `GET /v1/queue/next` | 200 with `{"id":"UUID","text":"message","sent_at":"ISO 8601"}`, or 204 when empty |
| `POST /v1/queue/reply` with `{"id":"UUID","text":"reply"}` | 200 with `{"ok":true}` after the reply is saved |
| `POST /v1/queue/reply` with `{"id":"UUID","error":"reason"}` | Same acknowledgement; Home displays the error and the message stops waiting |
| `GET /v1/health` | 200 with `{"ok":true,"pending":0}` |

Send exactly one of `text` and `error`, nonempty. Malformed JSON or an invalid reply receives
400, an unknown message ID receives 404, and a save failure receives 503 so the client can retry.
Use `Content-Length`; chunked request bodies are not supported. Each connection handles one
request and closes. Requests are limited to 16 KiB of headers, 16 MiB of body, and 30 seconds.
An oversized request is rejected, never silently truncated.

Poll every 15 seconds. The oldest unacknowledged message is returned repeatedly until its reply
is accepted; save and deduplicate its ID before starting work. Persist the result on the remote
side and retry its POST with the same ID if the outcome is uncertain. Repeating an accepted ID
succeeds without changing Home, even after a BotChu relaunch. The first accepted reply wins.
Later messages wait in FIFO order. A remote error acknowledges its message in the same way.

## Checking it end to end

In the remote bot's Home, send **Reply with the word pineapple.** Use a terminal on a machine
that can reach the shown base URL. Read the token privately; passing curl's header configuration
through stdin keeps the token out of its command-line arguments and shell history:

```bash
read -r -s -p 'Remote queue token: ' BOTCHU_REMOTE_TOKEN
BOTCHU_REMOTE_URL=http://127.0.0.1:18765
printf 'header = "Authorization: Bearer %s"\n' "$BOTCHU_REMOTE_TOKEN" |
  curl --silent --show-error --config - "$BOTCHU_REMOTE_URL/v1/queue/next"
```

Replace the base URL with the one shown in Settings. Copy the returned message ID into the reply:

```bash
printf 'header = "Authorization: Bearer %s"\n' "$BOTCHU_REMOTE_TOKEN" |
  curl --silent --show-error --config - --header 'Content-Type: application/json' \
  --data '{"id":"MESSAGE-ID","text":"pineapple"}' "$BOTCHU_REMOTE_URL/v1/queue/reply"
unset BOTCHU_REMOTE_TOKEN
```

Home should show the question and **pineapple** once, in order. Repeating the POST must add
nothing. Automated tests perform this exchange with curl, a disposable token and an isolated
AppModel, plus token rotation, errors, full queues and recovery from a missing transcript.

## Persistence and recovery

The bot's records live under the app data folder in `remote-bots/<bot-id>/.botchu/`, with an empty
workspace field. `remote-queue.json` is an atomic journal of requests, replies and their event
order, keyed to this bot ID. A reply's stable ID and its acknowledgement are committed together
before success is returned. Home reconciles from that journal by ID, so a crash between the
journal and Home saves cannot lose or duplicate the exchange. Replies are stored whole.
Completed receipts remain in the journal to recognize old retries indefinitely.

A queue file that cannot be read is preserved and the connection reports the problem. Deleting
the bot stops its connection and moves its conversation and waiting messages to the Trash with
its other records. The Keychain token is per installation; it is never stored in the journal,
transcript, settings defaults, diagnostic output or repository.
