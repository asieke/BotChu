# Remote queue bots

A remote queue bot runs on its own computer. BotChu keeps its Home conversation and a durable
queue; the remote runtime polls for messages and posts one reply or error per message. Nothing
starts a CLI on this Mac. V1 supports one remote bot, text messages, and ten waiting messages.
It has no local workspace, provider/model settings, tasks, scheduled jobs or sub-agent runs.

## Setup

1. Choose **New Bot**, set **Kind** to **Remote queue**, and name it (for example Danny).
2. Open **Settings ▸ Remote queue**. For a public HTTPS Funnel, keep **Listen address** at
   `127.0.0.1` and **Port** at `18765`. For a private connection between Tailscale peers, use
   this Mac's numeric Tailscale IP instead.
3. Enable **Serve the remote queue**. BotChu generates a random 32-byte token and saves it in
   the Keychain. **Show** and **Copy** expose it only on request. Give it to the remote runtime
   through secure credential entry, never through a conversation. **Regenerate** invalidates
   the old token while keeping waiting messages.
4. The status says **Listening** and shows the base URL when the listener is ready. That
   address and port survive relaunches. If using a public tunnel, use its HTTPS URL; the listener
   itself speaks HTTP. Tailscale encrypts traffic between its peers.

### Public HTTPS with Tailscale Funnel

The Muse computer does not need Tailscale or membership in this Mac's tailnet. On the BotChu
Mac, first enable the loopback listener and generate its Keychain token, then inspect existing
routes and add the HTTPS proxy:

```bash
tailscale funnel status --json
tailscale funnel --bg --https=443 http://127.0.0.1:18765
```

Preserve existing routes; choose another allowed public port if 443 already hosts a service.
Tailscale may require the tailnet owner to enable Funnel/HTTPS first. Use the public HTTPS URL
printed by the command as Muse's base URL. `--bg` keeps the route configured across restarts;
BotChu must still be running. Certificates and TLS termination are handled by the local
Tailscale daemon. See the [Funnel CLI reference](https://tailscale.com/docs/reference/tailscale-cli/funnel).
To remove only this route, run `tailscale funnel --https=443 off`.

The URL is publicly reachable. The token grants read access to queued messages and permission
to answer them; it is not a machine shell or access to other bots. Treat it as a password.
Store it in Muse's secret manager, send it only in the Authorization header over HTTPS, disable
request-header/body logging, and never put it in a URL, prompt, repository or command argument.
Regenerate it if exposed. A stolen token could read and acknowledge queued messages or forge
replies; public traffic can also consume bandwidth or temporarily deny service despite the
limits below. Turn off the listener or Funnel to stop access. Local queued text and replies
remain in BotChu's ordinary conversation files; only the token is in Keychain.

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
request and closes. BotChu parses up to 16 KiB of headers, then authenticates before reading
the body. Malformed headers receive 401. Authenticated oversized bodies receive 413, never
silent truncation. Responses include `Cache-Control: no-store`.

The listener allows 32 concurrent connections, two authenticated reply uploads, a burst of
20 requests and a sustained rate of two per second. Rate and upload limits return 429 with
`Retry-After`; excess connections close immediately. Limits are global, including unauthorized
traffic, because the proxy's peer address is shared. Forwarded IP headers are not trusted.
Headers must arrive within five seconds and the entire request within 30 seconds. Reply bodies
can be at most 16 MiB including JSON encoding. Token rotation is checked again after upload,
so an in-progress request using the old token cannot acknowledge a message.

Poll every 15 seconds. The oldest unacknowledged message is returned repeatedly until its reply
is accepted; save and deduplicate its ID before starting work. Persist the result on the remote
side and retry its POST with the same ID if the outcome is uncertain. Repeating an accepted ID
succeeds without changing Home, even after a BotChu relaunch. The first accepted reply wins.
Later messages wait in FIFO order. A remote error acknowledges its message in the same way.

Keep one poller active for this queue. Its durable state should record each message ID, whether
work has started, and the finished reply before delivery. On restart, resume or recover the
existing Muse turn instead of starting the same work again. Serialize processing; do not start
another turn when a repeated poll returns the current ID. A durable outbox retries the saved
result until BotChu acknowledges it. The same reply ID is safe to retry, but arbitrary Muse tool
side effects still need their own idempotency or recovery strategy after a crash.

On 401, pause and request updated credentials through secure entry. On 429, wait at least
`Retry-After`. On network errors or 5xx, use exponential backoff with jitter, capped at 60 seconds,
and retain the saved reply. Diagnose 400, 404 and 413 rather than retrying forever or truncating
the answer. Follow neither HTTP redirects nor a changed host when sending the token. Configure
automatic poller startup and a single-instance lock; do not schedule a fresh agent every 15 seconds.

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
