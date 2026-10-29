# Analytics dashboard

**View ▸ Open Analytics Dashboard** shows what BotChu's bots have done over time: how many turns and
runs, how they ended and how long they took, by bot, provider account and project, with each
profile's latest allowance beside them (#233). BotChu reads the records it already keeps, off the main
thread and without changing them, writes one page into its own data folder, and opens it in the
default browser. Nothing serves it. The passive usage ledger supplies captured account/model attribution, tokens and spend for new
executions. Older work still counts, with unavailable usage.

The code is `macOS/Sources/BotChuCore/Analytics.swift` (reading the records into a snapshot, and
`AnalyticsSummary`), `AnalyticsDashboard.swift` (the page and writing it) and the app's
`Sources/BotChu/App/Analytics.swift` (the menu command). The tests are `AnalyticsTests`.

## Data inventory

What exists on disk, for each bot in `index.json` (in its workspace's `.botchu/`), and how long it is
kept. Totals for a period can't be higher than what the sources read by the dashboard still hold.

| Source | File | What the dashboard uses | Kept |
| --- | --- | --- | --- |
| Home conversation | `thread.jsonl` | each message's role, date and tool duration, and BotChu's Stopped note | until the bot is deleted |
| Tasks | `tasks/<id>/task.json` | created, closed, repository, issue / pull request / review / brief, who started it, account, job run | until the bot is deleted; closing keeps it |
| Task conversations | `tasks/<id>/thread.jsonl` | as Home's | with the task; a job run's task goes when its job's history lets the run go (unless the owner wrote in it) |
| Scheduled jobs | `jobs/<id>/job.json` | each run's outcome, times (reserved, for, started, finished) and recorded account | the latest 50 runs a job and always its last success; deleting the job deletes them |
| Sub-agent runs | `subagents/<id>/run.json` and `tasks/<id>/subagents/<id>/run.json` | phase, created, started, finished, the bot it ran as, account, the task it was delegated from | until Clear Run removes it; one a relaunch interrupted becomes stopped |
| Allowance | `usage.json` beside `index.json` | each profile's latest reading: windows, share used, reset, when read, whether its check failed | the latest reading only; one unchecked for a week is dropped |
| Run reviews | `evaluations/<id>.json` | only counted, as excluded | the newest 50 a bot |
| Usage ledger | `usage/<yyyy-MM>.jsonl` | immutable turn/run account, CLI family and backend, model provenance, reported usage and actual-cost amendments | until the bot is deleted; Clear Run, task/job history pruning and account switches do not remove it |

### Usage ledger format

The ledger passively records each Home/task CLI invocation and each job/sub-agent execution. It
does no pricing or network work. Appending, encoding and combining usage reports run on the bot's
serialized `StorageQueue` lane; turn completion only submits captured values. Files are partitioned
by completion month in UTC, with a 0700 folder and 0600 files. A damaged or torn line does not hide
later lines. Repeated entry IDs are read once (the first complete entry wins).
Stopped or failed preparation, including a reserved sub-agent stopped before launch, retains an
explicitly unmeasured outcome. Skipped jobs have no execution and do not add a ledger entry.

Each entry holds `id`, `at`, `startedAt`, `kind`, `botID`, optional `taskID`, `jobRunID` and
`subagentRunID`, captured `accountID`, `provider` (CLI family), `providerID` (backend), `model` and
`modelSource` (`reported`, `requested`, `unreported`), `outcome`, `usage`, `sessionID` and `resumed`.
`remote` and `usesLegacyOpenRouterKey` freeze execution/key ownership at launch without recording
any host, path or key; reconciliation never infers historical ownership from today's settings.
Missing usage is JSON `null`, distinct from reported zero counts or cost. No prompt, reply, error
text, tool input/output, workspace path, credentials or CLI auth file is read or copied into it.
Only UUID session identities are retained, canonically lowercased; paths and arbitrary session IDs
are dropped. A cumulative report without a usable identity cannot safely be differenced. A resumed
session's first ledger reading is a baseline; a genuinely new session can count its initial totals.

`messageID` identifies the owning transcript prompt exactly, and `messageIDs` includes all live
follow-ups the CLI actually acknowledged. Claude can accept a follow-up during tools and emit
multiple results in one process. The ledger aggregates all those result reports once for the
invocation, without guessing which prompt caused which tokens. A reader may apply its captured
account/model to every covered transcript segment, but must charge usage only once to the owning
record; the other segments have no separately measured usage, not measured zero. Existing
transcript turn counts remain unchanged. `startedAt` is execution start, not the queued prompt's date.
Sub-agent entries live in the root/calling bot's ledger beside its sub-agent archive; their `botID`
is the executing target bot and `taskID` is the root task. Join them by `subagentRunID`. Reconciliation
must defer while either the ledger owner or the executing bot is streaming.

Reconciliation appends `{"amends":"<entry UUID>","actualCostUSD":0.12}`. This represents the
actual **whole invocation** cost, only when every generation is supported and resolved. Partial
costs must not replace an estimate. The latest valid, nonnegative finite amendment wins, including
a reported zero; repeated identical amendments are not written again, including after relaunch.

Not read: message text, briefs, tool calls and output beyond their dates and durations, the turn log
(`logs/<date>.log`, whose lines aren't tied to a conversation and hold commands and errors), task
summaries, pets, memory, deliveries, Telegram and the remote queue.

## Time zone and days

Every record is bucketed into a **calendar day of the Mac's time zone when the page is made**
(`AnalyticsSnapshot.timeZone`), as `yyyy-MM-dd`, worked out in Swift (`Analytics.day`), so the browser
never re-buckets it. A turn or run counts on the day it **started**, with all of its time, even when it
ends after midnight. Durations are differences between instants, so a run across a daylight-saving
change has its true length, and a day of 23 or 25 hours is still one day (`Analytics.days` counts
dates, not 24-hour steps). Changing the Mac's zone and making the page again moves records to that
zone's days.

## What is counted

Four kinds of record (`AnalyticsRecord.Kind`), each with a day, an outcome, a duration (or none), a bot,
an account (or none) and a project (or none):

- **Home turns** and **task turns**, from each conversation's transcript (`Analytics.turns`). A turn
  starts at a message to the bot (the owner's, another bot's, Telegram's or an Inbox reply) and runs
  until the next one. Its start is that message's time, or the end of the turn before it when the
  message waited in the queue; its end is the last thing the bot did (a reply, an error, a tool call
  with its duration) or BotChu's Stopped note. Receipts and notes BotChu adds later don't extend it. A
  stretch where the bot did nothing isn't a turn, except the last one of a conversation running now.
  A bot's introduction, asked for without a visible message, is a turn. A follow-up Claude Code took
  mid-turn is written as a message, so it starts a turn of its own: turn counts can be slightly
  higher than the CLI's own.
- **Job runs**, from each job's history, one record per run: from `startedAt` to `finishedAt`, on the
  day of `startedAt` (else the time it was for, else when it was reserved). A job run's task starts
  with the run itself, so its first turn isn't counted again; turns the owner added to that task
  afterwards are task turns. When the job is gone but its run's task is still there, the run is read
  from that first turn instead (`AnalyticsCoverage.jobRunsFromTasks`).
- **Sub-agent runs**, from each run's record: from `startedAt` to `finishedAt`, on the day of
  `startedAt` (else `createdAt`).
- **Tasks** (`AnalyticsTask`): each task that isn't a job run, on the day it was made, with its turns
  and how its latest turn ended.

### Outcomes

As BotChu saw them (`AnalyticsOutcome`). A finished CLI turn is not proof the task succeeded, so the
page says "finished", never "succeeded".

| Outcome | Turns | Job runs | Sub-agent runs |
| --- | --- | --- | --- |
| Finished | the last word is the bot's reply (an error it recovered from earlier doesn't count) | succeeded, quiet or not | completed |
| Failed | the last word is an error | failed, also at its time limit | failed |
| Stopped | ended by BotChu's Stopped note (the owner's Stop, or quitting) | stopped | stopped (also one a relaunch interrupted) |
| Interrupted | — | running when BotChu quit or crashed | — |
| In progress | the last turn of a conversation the app says is running | waiting or running | queued, preparing or running |
| Skipped | — | a time the job didn't run: listed, never counted as a run | — |

A turn that a crash cut short without a Stopped note reads as finished, as run reviews read it.

### Metrics

Each is worked out for the chosen days and kinds, in Swift by `AnalyticsSummary` and in the page by
its script's `summarize`, which a test checks against each other (`thePagesScriptWorksOutTheSameNumbers`,
on macOS).

| Metric | Calculation |
| --- | --- |
| Turns & runs | records in range that aren't skipped |
| Finished, Failed, Stopped, In progress | records by outcome; Stopped includes interrupted job runs |
| Failure rate | failed ÷ (finished + failed + stopped + interrupted); none when nothing ended |
| Median time | the middle of the known durations of records that ended (the mean of the two middle ones for an even count); none without any |
| Time at work | the known durations added up |
| Tasks started | tasks made in range |
| Per day | the same, for each day; the duration chart leaves a gap for a day without a known duration |
| By bot, account, project | the same, for the records attributed to each, busiest first |
| Spend | known actual amendments plus estimated spend; any estimated component makes the total estimated; unpriced and unavailable record counts remain separate |
| Tokens | sums of reported uncached input, cache read, cache write and output; reasoning is a subset of output and one-hour cache writes a subset of cache writes |
| Cache hit rate | cache read ÷ (uncached input + cache read + cache write); unavailable without reported cache reads or positive input |
| Per finished task | selected spend on finished tasks' turns and sub-agent runs ÷ finished tasks represented by those records; a task is finished when its latest retained turn finished |
| Wasted spend | known spend on failed, stopped and interrupted records |

### Missing data, retries, stopped and in-progress work

- A duration is **unknown** when a time is missing, the end is before the start (a clock change, a
  damaged record) or the work is still under way. Unknown durations are never zero: they are left out
  of medians and totals, and the page says how many of those that ended have one.
- **Retries** count every attempt: a failed turn and the turn that retries it are two turns; each job
  run is its own record. A task stands by its latest turn, so a failure and then a successful retry
  leave the task finished while both turns are counted.
- **Stopped** work counts as ended, with its time up to the stop. **In-progress** work counts in the
  volume, with no duration, and not in the failure rate.
- A transcript with lines BotChu can't read is read as far as it can be (and left as it is), and the
  page says so; a task, job or sub-agent record that can't be read is left out and counted; a bot whose
  folder is missing is listed as missing.

### Attribution

- **Bot:** the conversation's bot; the job's agent; the bot a sub-agent run ran as, by the name it
  had when it was delegated if that bot is gone.
- **Provider account and model:** a matched ledger entry supplies the account, CLI family, backend,
  model and its reported/requested provenance captured for that invocation. Transcript prompt UUIDs
  match before timestamps; jobs and sub-agent runs match by run UUID, including root-owned sub-agent
  ledgers whose executing bot differs. Legacy entries without prompt identity can match a unique
  start within the ledger's one-second timestamp precision. Ambiguous matches stay unavailable.
  Before the ledger, Home/task turns retain conversation-current account attribution and have no
  model or usage; job/sub-agent runs retain their recorded account. An account BotChu no longer
  offers keeps its saved name. These historical limitations do not change turn counts or durations.
- **Grouped prompts:** all acknowledged Claude transcript segments get the captured account/model,
  but only the invocation's owning prompt gets its aggregate usage and cost. Other covered segments
  remain unavailable, not measured zero. The transcript still determines their time and outcome.
- **Project:** a task's repository (`owner/name`, matched whatever its case); a sub-agent run's by the
  task that delegated it. Home turns and job runs have none.

### Tokens, cost and allowance

Snapshot version 2 reads the ledger without changing it and prices usage while building the snapshot
off the main thread. Each record has nullable token buckets, per-model usage, nullable cost and
`costProvenance`: `actual`, `estimated`, `unpriced` or `unavailable`. Missing counts never become
measured zero. Token totals sum known buckets; reasoning/output and one-hour/all cache writes are
not double-counted. Aggregates with partial coverage are known subtotals, not a claim that unknown
work was free. `unpriced` counts measured usage for which no price exists; `unavailable` counts work
with no separately measured usage. A selection containing only either has no numeric spend.

Pricing order is whole-invocation actual amendment, bundled model rates, CLI-reported cost estimate,
then unpriced. A valid zero amendment or CLI estimate is retained. A mixed actual/estimated total
is estimated. Pi's captured backend selects its price source: an unknown backend never silently uses
OpenRouter's table. The snapshot includes `priceSnapshotDate`, sorted `unpricedModelIDs` and the
static `prices` catalog (source/model, display name, per-million rates and context tiers), so the
next dashboard can make offline comparisons using exactly those rates. No price fetch occurs.
For one-hour cache writes without a dedicated rate, the price engine uses twice the input rate;
a missing rate for any other used bucket makes that estimate unavailable.

Any usage marked `cumulative` is differenced by account, CLI family, backend and canonical UUID
session identity, across the complete retained ledger before joining transcripts. Equal timestamps
preserve ledger order. The first reading of a new session counts in full; the first resumed reading
only establishes a baseline. A missing/invalid session ID cannot be differenced. Decreasing or
negative counters make the invocation unavailable and establish a new baseline. Anonymous model
buckets are differenced before applying the invocation's requested-model fallback, so changing
models does not charge the full session again. A bucket without a prior reading remains unknown;
known deltas can still be shown, but `canReprice` is false and list-price estimates are prohibited for
that partial delta. Its cost is unavailable, not unpriced: the missing baseline prevents a price
even when the model rates are known. Actual amendments or a valid differenced reported cost can
still supply cost.

`AnalyticsSummary` and the page's `summarize` accept the same task list and selected records.
Finished-task averages use the current retained task outcome, include selected task turns and
sub-agent records, and exclude unrelated jobs/Home work. A sub-agent-only filter still represents
its parent task. The denominator counts represented finished tasks even when some spend is missing;
the average, like spend, is only the known subtotal. With no known spend it stays unavailable.
Opaque task UUIDs, start instants and issue/PR numbers support these joins and later task links;
no session or prompt UUID is exported.

Provider allowance remains separate: each profile's latest reading (share used per window, reset,
read time, and current/stale/missing state), as reported. It is not a history or split by bot, so no
spend or tokens are derived from it.

### Left out

- Run reviews (`evaluations/`): reviews of work, not work. The page says how many.
- Remote queue bots: they run on another computer; BotChu only relays their messages.
- Task summaries, pet drawing and the turn log.

## Access and privacy

- **This Mac only, no server.** The page is `analytics/dashboard.html` in BotChu's data folder
  (`~/Library/Application Support/BotChu`, or `BOTCHU_DATA_DIR` for review copies), opened in the
  browser that opens web links. There is no listening socket, so nothing can reach it from elsewhere.
  Each choice of the command writes it again, replacing the last one.
- **Only this user can read it.** Its folder is set to 0700 before the page is written, and the page
  to 0600.
- **It loads nothing.** Style, script and data are inside the page. Its content security policy is
  `default-src 'none'` with only inline style and script allowed, so it can make no request of any
  kind, even from injected markup; the only address in it is the SVG namespace. The data is JSON in a
  `<script type="application/json">` block with every `<`, `>` and `&` escaped, and the script puts names
  into the page with `textContent`, never as markup.
- **Names and numbers only.** The snapshot holds bot, account and repository names, days, outcomes,
  durations, token buckets, cost provenance, model IDs, offline prices and opaque task IDs. It never holds message text, briefs, prompts, replies, tool calls or output,
  error messages, task or job titles, file paths, commands, session IDs or credentials (tested with
  planted values in every such field).

## States

- **No records:** "No activity recorded yet", with allowance and these notes still shown.
- **Nothing in the range or kinds chosen:** each chart and table says so.
- **Partial data:** a callout lists what couldn't be read (above).
- **The page's data can't be read, or is of another version:** it says so and to choose the command
  again.
- **The page can't be written:** BotChu shows an alert saying why.

## Checking it

`swift test --package-path macOS --filter AnalyticsTests` covers the fixtures: turns split by message,
queue waits, the intro turn, receipts after a turn, stops, failures recovered from, in-progress only
for a running conversation, retries, every job and sub-agent outcome, missing and backwards times,
runs across midnight and both daylight-saving changes, empty data, unreadable files, the content
exclusions, the escaped data block, the policy and the file permissions. On macOS it also runs the
page's own script in JavaScriptCore against `AnalyticsSummary`.

`swift test --package-path macOS --filter UsageLedgerTests` covers capture, damaged-line recovery,
amendment retries, privacy and the storage handoff. `BOTCHU_LEDGER_BENCHMARK=/tmp/ledger.csv` with
`--filter usageLedgerEnqueueBenchmark` measures turn-end submission against empty and 100,000-line
histories without asserting load-sensitive timing thresholds. The ledger never reads history on
the main actor and does not change `ResponsivenessTests`.

`BOTCHU_ANALYTICS_SAMPLE=/tmp/analytics.html swift test --package-path macOS --filter theSampleCoversEveryCase`
writes a page of two months of sample data to look at in a browser.
