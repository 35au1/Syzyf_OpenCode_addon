#!/usr/bin/env bun
// dod-loop.ts — Definition of Done loop. Requires a running `opencode serve`.
//
// One cycle = one work turn, then one independent verify turn. The verdict is binary: every rule is
// met, or the job is not done. There is no partial credit and no score. While the answer is "not
// done", the loop opens a fresh session and continues.
import { createOpencodeClient } from "@opencode-ai/sdk/v2"
import { appendFileSync, existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs"
import { resolve } from "node:path"

export const BASE_URL = process.env.OPENCODE_BASE_URL ?? "http://localhost:4096"

export type Model = { providerID: string; modelID: string }

/**
 * Parse a comma-separated model chain. A bare id is assumed to be a Zen model, so
 * `"big-pickle"` and `"opencode/big-pickle"` mean the same thing.
 */
export function parseModels(spec: string | undefined, fallback: string[]): Model[] {
  const listed = (spec ?? "")
    .split(",")
    .map((entry) => entry.trim())
    .filter((entry) => entry !== "")
  return (listed.length > 0 ? listed : fallback).map((id) => {
    const slash = id.indexOf("/")
    if (slash === -1) return { providerID: "opencode", modelID: id }
    return { providerID: id.slice(0, slash), modelID: id.slice(slash + 1) }
  })
}

/**
 * The model chain, tried in order, moving on when one is out of quota.
 *
 * Zen's free tier is not one shared budget: each free model is a separate upstream integration with
 * its own capacity, so `deepseek-v4-flash-free` reporting "Free usage exceeded" says nothing about
 * the rest. That is what makes this chain worth having rather than just a longer backoff.
 *
 * `nemotron-3.5-lightning-free` is deliberately absent. The verify turn has to enumerate a source set
 * of hundreds of files before it may judge a rule, and a small fast model that gives up on the
 * enumeration and passes anyway is the single worst failure this design can suffer: three of those in
 * a row ends the run on an unfinished job. A stalled loop is recoverable, a false pass is not.
 */
export const WORK_MODELS = parseModels(process.env.DOD_WORK_MODELS, [
  "deepseek-v4-flash-free",
  "big-pickle",
  "mimo-v2.5-free",
])
export const VERIFY_MODELS = parseModels(process.env.DOD_VERIFY_MODELS, [
  "deepseek-v4-flash-free",
  "big-pickle",
  "mimo-v2.5-free",
])

/** The head of the work chain. Kept as a named export because it is the run's headline model. */
export const MODEL = WORK_MODELS[0]

/**
 * How long to wait when every model in a chain is out of quota.
 *
 * Without this the loop spins: session creation still succeeds (the account is fine, the models are
 * rate-limited), so `deadCycles` never trips, and a quota-blocked cycle would restart immediately and
 * burn through cycle budget doing nothing.
 */
export const QUOTA_COOLDOWN_MS = Number(process.env.DOD_QUOTA_COOLDOWN_MS ?? 15 * 60_000)

/**
 * How often to ask the server what a running turn is doing.
 *
 * The server never hands a quota refusal back to the caller. It classifies it as retryable, keeps the
 * request open, and schedules its own retry hours out — seen as "Free usage exceeded, subscribe to Go
 * [retrying in 1h 36m attempt #1]" with `prompt()` still waiting. It is not in the message record
 * either: while the retry is pending, `GET /session/{id}/message` shows the assistant message with no
 * `error` at all, which is why an earlier version of this watchdog sat there for the full deadline.
 *
 * `GET /session/status` is where it actually lives, as a typed `SessionStatus` union. A local HTTP call
 * every few seconds costs nothing, so this is quick.
 */
export const TURN_POLL_MS = Number(process.env.DOD_TURN_POLL_MS ?? 5_000)

/**
 * How far out a scheduled retry may be before the model is abandoned instead of waited for.
 *
 * Not every retry is a refusal: a dropped socket gets retried too, and that one is worth waiting a few
 * seconds for. The distinction that matters is how long the server intends to wait, which `next` states
 * outright. A retry landing inside this window is transient, anything beyond it is a wall.
 */
export const RETRY_TOLERANCE_MS = Number(process.env.DOD_RETRY_TOLERANCE_MS ?? 60_000)

/**
 * How long a single turn may run before it is abandoned and the next model is tried.
 *
 * A backstop, not the main mechanism: a refusal is caught by the status poll within seconds. This only
 * catches a turn wedged for some reason the server does not report, so it is generous — a real work turn
 * chewing through a large repository is allowed to take a long time.
 */
export const TURN_DEADLINE_MS = Number(process.env.DOD_TURN_DEADLINE_MS ?? 45 * 60_000)

/** Master folder. Everything a run generates lives under `projectfiles/<run id>/` and nowhere else. */
export const PROJECT_FILES = resolve(process.cwd(), "projectfiles")

/**
 * The seed definition, copied into a new run folder at launch.
 *
 * This file is an input, not an output, so it stays outside `projectfiles`. Each run gets its own copy
 * that the operator reviews and corrects before work starts, which means editing a run's definition can
 * never retroactively change what an earlier run was judged against.
 */
export const TEMPLATE_RULES_FILE = resolve(process.cwd(), ".opencode/dod.md")

/** A run id is exactly five digits, so `projectfiles` sorts correctly as plain text. */
export const RUN_ID_PATTERN = /^\d{5}$/

export const formatRunId = (n: number): string => String(n).padStart(5, "0")

/** Run folders that already exist, newest last. */
export function listRunIds(): string[] {
  if (!existsSync(PROJECT_FILES)) return []
  return readdirSync(PROJECT_FILES, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && RUN_ID_PATTERN.test(entry.name))
    .map((entry) => entry.name)
    .sort()
}

/**
 * The next id in sequence.
 *
 * Derived from the highest existing folder rather than a stored counter, so deleting the newest run
 * frees its id and a hand-made folder is picked up without ceremony.
 */
export function nextRunId(existing: string[]): string {
  const highest = existing
    .filter((id) => RUN_ID_PATTERN.test(id))
    .reduce((max, id) => Math.max(max, Number(id)), 0)
  return formatRunId(highest + 1)
}

export type RunPaths = { id: string; dir: string; rules: string; original: string; state: string; log: string }

/**
 * Where a run's files live. Names are unprefixed because the folder already carries the id; calling it
 * `projectfiles/00001/00001-state.md` would only say it twice.
 */
export function runPaths(id: string): RunPaths {
  const dir = resolve(PROJECT_FILES, id)
  return {
    id,
    dir,
    rules: resolve(dir, "definition.md"),
    original: resolve(dir, "definition.original.md"),
    state: resolve(dir, "state.md"),
    log: resolve(dir, "run.log"),
  }
}

/** Allocate the next run, create its folder, and seed the definition from the template. */
export function prepareRun(): RunPaths {
  if (!existsSync(TEMPLATE_RULES_FILE)) die(`no template Definition of Done at ${TEMPLATE_RULES_FILE}`)
  const template = readFileSync(TEMPLATE_RULES_FILE, "utf8")
  if (!template.trim()) die(`template Definition of Done has no rules: ${TEMPLATE_RULES_FILE}`)
  const paths = runPaths(nextRunId(listRunIds()))
  mkdirSync(paths.dir, { recursive: true })
  // Never overwrite: re-preparing an id must not discard corrections already made to it.
  if (!existsSync(paths.rules)) writeFileSync(paths.rules, template, "utf8")
  return paths
}

/**
 * The run this process belongs to.
 *
 * Set by `start_syzyf.bat` once it has allocated the folder and the operator has approved the
 * definition. The placeholder keeps the module importable on its own; nothing is written under it,
 * because `loadRules` refuses to start without a real definition file.
 */
export const RUN_ID = process.env.DOD_RUN_ID?.trim() || "00000"
export const RUN_DIR = runPaths(RUN_ID).dir
export const RULES_FILE = runPaths(RUN_ID).rules
/**
 * The handoff file. Each cycle runs in a fresh session, so this is the only place discoveries can
 * survive. The work turn is told to append to it continuously rather than at the end, because a turn
 * that runs out of context never reaches its own cleanup step.
 */
export const STATE_FILE = runPaths(RUN_ID).state
export const LOG_FILE = runPaths(RUN_ID).log
/**
 * What this run was launched with, written once and never again.
 *
 * The definition is editable while the run is going — that is the point of leaving the review window
 * open — so after a few corrections there is nothing left to say what the run originally set out to
 * do. This snapshot is that record, and it is what the review window shows for each run.
 */
export const ORIGINAL_RULES_FILE = runPaths(RUN_ID).original
export const VERIFIER_AGENT = "dod-verifier"

/**
 * Unbounded by default. Each cycle is one bounded context window of work, so a large job needs far
 * more cycles than anyone would guess. Set DOD_CYCLE_BUDGET to a number to cap a run.
 */
export const CYCLE_BUDGET = Number(process.env.DOD_CYCLE_BUDGET ?? Infinity)

/**
 * How many consecutive passing verdicts end the run.
 *
 * A single `pass` is one judgement from a weak model, and the failure mode of this whole design is a
 * model that decides it is finished. Each verdict comes from a brand-new verifier session that has
 * never seen the previous one, so three in a row are three independent looks rather than one look
 * repeated. Any `fail` resets the count to zero.
 */
export const PASS_STREAK = Number(process.env.DOD_PASS_STREAK ?? 3)

export const FALLBACK_DIRECTIVE =
  "Re-check the repository against the Definition of Done rules, find the first rule that is not met, " +
  "and do the work needed to meet it."

export type Verdict = { outcome: "pass" | "fail"; gaps: string[]; directive: string }

/** Total: every input yields a verdict, and only a real `pass` with no gaps passes. */
export function parseVerdict(raw: unknown): Verdict {
  const unusable: Verdict = {
    outcome: "fail",
    gaps: ["verifier produced no usable verdict"],
    directive: FALLBACK_DIRECTIVE,
  }
  const value = typeof raw === "string" ? parseJson(raw) : raw
  if (typeof value !== "object" || value === null || Array.isArray(value)) return unusable
  const fields = value as { outcome?: unknown; gaps?: unknown; directive?: unknown }
  const gaps = Array.isArray(fields.gaps)
    ? fields.gaps.filter((gap): gap is string => typeof gap === "string" && gap.trim() !== "").map((gap) => gap.trim())
    : []
  // A pass needs an actual empty gaps list, not a missing one: an omitted field means the response
  // failed the shape it was asked for, and an ambiguous pass is the one mistake this loop must never
  // make.
  if (fields.outcome === "pass" && Array.isArray(fields.gaps) && gaps.length === 0)
    return { outcome: "pass", gaps: [], directive: "" }
  const stated = typeof fields.directive === "string" ? fields.directive.trim() : ""
  return { outcome: "fail", gaps, directive: stated || gaps[0] || FALLBACK_DIRECTIVE }
}

function parseJson(text: string): unknown {
  try {
    return JSON.parse(text)
  } catch {
    return undefined
  }
}

/**
 * Pull the verdict object out of a model reply.
 *
 * The verify turn asks for raw JSON but a reasoning model wraps it in prose, code fences, or both.
 * Structured output is not an option here: `deepseek-v4-flash-free` runs in thinking mode and the
 * provider rejects the forced `tool_choice` that opencode's json_schema format needs with a 400. So
 * we read text and dig the object out ourselves.
 */
export function extractJsonText(text: string): string {
  const fenced = text.match(/```(?:json)?\s*([\s\S]*?)```/i)
  const body = fenced?.[1] ?? text
  const start = body.indexOf("{")
  const end = body.lastIndexOf("}")
  if (start === -1 || end === -1 || end < start) return body.trim()
  return body.slice(start, end + 1)
}

/** Everything printed also lands in the run's run.log, so a scrolled-away failure is still recoverable. */
export function log(line: string): void {
  console.log(line)
  try {
    appendFileSync(LOG_FILE, line + "\n")
  } catch {
    // logging must never take the run down
  }
}

/**
 * Exit 2, not 1. The runner uses 1 for "budget reached without meeting the DoD", which is a normal
 * outcome, and 2 for "something broke". Collapsing them into one code is what made an earlier
 * failure unreadable.
 */
export function die(message: string, detail?: unknown): never {
  const detailText = detail === undefined ? "" : "\n" + (detail instanceof Error ? detail.stack : JSON.stringify(detail))
  console.error(message + detailText)
  try {
    appendFileSync(LOG_FILE, "ERROR " + message + detailText + "\n")
  } catch {}
  process.exit(2)
}

/**
 * The current definition, or undefined if there is not a usable one on disk right now.
 *
 * Non-fatal on purpose. The review window stays open for the whole run so the definition can be
 * corrected mid-flight, which means the loop can read this file at the exact moment it is being
 * rewritten. Killing a long run over a half-written file would be absurd, so the caller decides:
 * startup treats it as fatal, and a running loop keeps the last good copy.
 */
export function readRules(): string | undefined {
  try {
    if (!existsSync(RULES_FILE)) return undefined
    const text = readFileSync(RULES_FILE, "utf8")
    return text.trim() ? text : undefined
  } catch {
    return undefined
  }
}

export function loadRules(): string {
  const text = readRules()
  if (text === undefined) die(`no usable Definition of Done at ${RULES_FILE}`)
  return text
}

/**
 * Record what this run started with, once. Never overwrites: after the first cycle this file is the
 * only remaining evidence of the original job, and every later edit is deliberately not reflected here.
 */
export function snapshotOriginalRules(text: string): void {
  try {
    if (!existsSync(ORIGINAL_RULES_FILE)) writeFileSync(ORIGINAL_RULES_FILE, text, "utf8")
  } catch {
    // A missing snapshot costs a tooltip, not a run.
  }
}

const sleep = (ms: number) => new Promise((done) => setTimeout(done, ms))

function describe(error: unknown): string {
  if (error instanceof Error) return error.message
  if (typeof error === "string") return error
  return JSON.stringify(error)?.slice(0, 300) ?? "unknown error"
}

/**
 * Retry a turn, then give up without killing the run.
 *
 * An unattended loop must not die because one call failed. Returning undefined lets the caller
 * degrade: a failed work turn means no progress this cycle, and a failed verify turn means an
 * unusable verdict, which `parseVerdict` already turns into a fail.
 */
async function attempt<T>(label: string, tries: number, run: () => Promise<T>): Promise<T | undefined> {
  for (let i = 1; i <= tries; i++) {
    try {
      return await run()
    } catch (error) {
      log(`  ${label} attempt ${i}/${tries} failed: ${describe(error)}`)
      if (i < tries) await sleep(Math.min(5000 * 2 ** (i - 1), 60_000))
    }
  }
  log(`  ${label} gave up after ${tries} attempts`)
  return undefined
}

export const modelName = (model: Model): string => `${model.providerID}/${model.modelID}`

/**
 * Phrases Zen and its upstream providers use for "this model has nothing left for you".
 *
 * Matched as substrings against the whole error text because the wording varies by upstream: Zen's own
 * gateway says "Free usage exceeded, subscribe to Go", while the providers behind the free models
 * surface "Insufficient balance", plain 429s, and their own rate-limit phrasing.
 */
const QUOTA_PHRASES = [
  "free usage exceeded",
  "usage limit",
  "usage exceeded",
  "quota",
  "insufficient balance",
  "insufficient_quota",
  "rate limit",
  "rate_limit",
  "ratelimit",
  "too many requests",
  "subscribe to go",
  "add credits",
  "429",
]

/**
 * Is this error "wrong model" rather than "wrong request"?
 *
 * The distinction decides what the caller does: a quota error means switch model, anything else means
 * retry the same one. Getting it wrong in the lenient direction is cheap (one wasted model switch),
 * so this errs toward matching.
 */
export function isQuotaError(error: unknown): boolean {
  const text = describe(error).toLowerCase()
  return QUOTA_PHRASES.some((phrase) => text.includes(phrase))
}

export type TurnResponse = {
  data?: { info: { error?: unknown }; parts?: Array<{ type: string; text?: string }> }
  error?: unknown
}

export type TurnOutcome = {
  /** Undefined when every model in the chain failed. */
  response?: TurnResponse
  /** Which model actually produced the response. */
  model?: Model
  /** True only when the chain failed and every single failure was a quota error. */
  starved: boolean
}

/** How a single model's attempt at a turn ended. */
type Attempt =
  | { kind: "done"; response: TurnResponse }
  | { kind: "quota"; detail: string }
  | { kind: "failed"; detail: string }
  | { kind: "timeout" }

/**
 * Reasons the server gives for a retry that mean "this model has nothing left for you".
 *
 * Zen's own is `free_tier_limit`. The substring match covers the neighbouring cases from other upstreams
 * without needing to enumerate them, since anything with limit, quota, balance or credit in the reason is
 * not going to resolve itself in the next few seconds.
 */
const LIMIT_REASONS = ["limit", "quota", "balance", "credit", "exceeded"]

/** A pending retry on this session, if the server has one scheduled. */
type Retry = { message: string; reason: string; attempt: number; next: number }

async function sessionRetry(client: LoopClient, sessionID: string): Promise<Retry | undefined> {
  try {
    const res = await client.session.status({})
    const status = res.data?.[sessionID]
    if (status === undefined || status.type !== "retry") return undefined
    return {
      message: status.message ?? "",
      reason: status.action?.reason ?? "",
      attempt: status.attempt ?? 0,
      next: status.next ?? 0,
    }
  } catch {
    // The watchdog must never be the thing that breaks a turn.
    return undefined
  }
}

/** Is this retry a quota wall rather than a transient hiccup? */
function isLimitRetry(retry: Retry): boolean {
  const reason = retry.reason.toLowerCase()
  return LIMIT_REASONS.some((word) => reason.includes(word)) || isQuotaError(retry.message)
}

/**
 * Run one model's attempt, watching the session while it is in flight.
 *
 * `prompt()` cannot be trusted to come back. The server treats a quota refusal as retryable and holds the
 * request open across its own retries, so waiting on the promise alone means waiting hours. This races the
 * promise against a poll of `/session/status` and abandons the attempt the moment a refusal shows up
 * there, which happens within a poll interval of the model being asked.
 */
async function attemptTurn(input: {
  client: LoopClient
  sessionID: string
  model: Model
  agent?: string
  text: string
  pollMs: number
  deadlineMs: number
  retryToleranceMs: number
}): Promise<Attempt> {
  let finished = false

  // Converted to a value rather than left as a rejectable promise: once the watchdog wins the race
  // nobody is left to catch this, and an unhandled rejection would take the run down.
  const pending: Promise<Attempt> = input.client.session
    .prompt({
      sessionID: input.sessionID,
      model: input.model,
      ...(input.agent === undefined ? {} : { agent: input.agent }),
      parts: [{ type: "text", text: input.text }],
    })
    .then((response: TurnResponse): Attempt => {
      const failure = response.error ?? response.data?.info.error
      if (failure === undefined || failure === null) return { kind: "done", response }
      const detail = describe(failure)
      return isQuotaError(detail) ? { kind: "quota", detail } : { kind: "failed", detail }
    })
    .catch((error: unknown): Attempt => {
      const detail = describe(error)
      return isQuotaError(detail) ? { kind: "quota", detail } : { kind: "failed", detail }
    })
    .finally(() => {
      finished = true
    })

  const watchdog = (async (): Promise<Attempt> => {
    const started = Date.now()
    while (!finished) {
      await sleep(input.pollMs)
      if (finished) break

      const retry = await sessionRetry(input.client, input.sessionID)
      if (retry !== undefined) {
        const waitMs = retry.next - Date.now()
        if (isLimitRetry(retry))
          return { kind: "quota", detail: `${retry.message} (reason ${retry.reason || "unstated"}, retry #${retry.attempt} due in ${Math.round(waitMs / 60_000)}m)` }
        // A retry the server means to make soon is worth waiting for; anything further out is a wall
        // wearing a different label.
        if (waitMs > input.retryToleranceMs)
          return { kind: "failed", detail: `retry #${retry.attempt} deferred ${Math.round(waitMs / 1000)}s: ${retry.message}` }
      }

      if (Date.now() - started >= input.deadlineMs) return { kind: "timeout" }
    }
    // The prompt settled first; its own result wins the race.
    return pending
  })()

  const outcome = await Promise.race([pending, watchdog])
  if (!finished) {
    // Stop the server retrying a turn nobody is waiting for any more. Without this it keeps the
    // request alive for hours and the next model would be racing a ghost.
    await input.client.session.abort({ sessionID: input.sessionID }).catch(() => {})
  }
  return outcome
}

/**
 * Run one turn, walking the model chain.
 *
 * A quota refusal abandons that model immediately: retrying it cannot help, since the window it is
 * waiting on is measured in hours. Any other failure gets `tries` attempts with backoff before moving
 * on, because a model-specific 400 is also a reason to try a different model rather than to give up on
 * the cycle.
 *
 * Each model reuses the same session, so a model that takes over after a refusal sees the directive
 * already sitting there. That is intentional: the alternative is a fresh session per model, which would
 * throw away the cycle's session identity that `status.ps1` and the TUI both key off.
 */
async function runTurn(input: {
  client: LoopClient
  label: string
  sessionID: string
  models: Model[]
  agent?: string
  text: string
  tries?: number
  pollMs?: number
  deadlineMs?: number
  retryToleranceMs?: number
}): Promise<TurnOutcome> {
  const tries = input.tries ?? 2
  let sawQuota = false
  let sawOther = false

  for (const model of input.models) {
    for (let i = 1; i <= tries; i++) {
      const attempt = await attemptTurn({
        client: input.client,
        sessionID: input.sessionID,
        model,
        agent: input.agent,
        text: input.text,
        pollMs: input.pollMs ?? TURN_POLL_MS,
        deadlineMs: input.deadlineMs ?? TURN_DEADLINE_MS,
        retryToleranceMs: input.retryToleranceMs ?? RETRY_TOLERANCE_MS,
      })

      if (attempt.kind === "done") return { response: attempt.response, model, starved: false }

      if (attempt.kind === "quota") {
        sawQuota = true
        log(`  ${input.label}: ${modelName(model)} is out of quota (${attempt.detail})`)
        break
      }

      sawOther = true
      const why = attempt.kind === "timeout" ? `no reply within ${Math.round((input.deadlineMs ?? TURN_DEADLINE_MS) / 60_000)}m` : attempt.detail
      log(`  ${input.label}: ${modelName(model)} attempt ${i}/${tries} failed: ${why}`)
      // A wedged turn is not going to unwedge on a second identical request, so stop retrying this
      // model and let the chain move on.
      if (attempt.kind === "timeout") break
      if (i < tries) await sleep(Math.min(5000 * 2 ** (i - 1), 60_000))
    }
  }

  log(`  ${input.label}: every model in the chain failed (${input.models.map(modelName).join(", ")})`)
  return { starved: sawQuota && !sawOther }
}

/**
 * What the work turn may and may not write into the handoff file, stated in every directive.
 *
 * A run once ended one cycle in because the work agent wrote "Status: work complete, pending final
 * verification" plus a rule-by-rule evidence section into the handoff file, and the verifier read the
 * claim as evidence. The work turn does not grade itself.
 */
const HANDOFF_RULES = [
  `## What that file is for`,
  `- FACTS ONLY: what you finished, what is part-way through, what you have not touched, and what you`,
  `  tried that failed.`,
  `- Do NOT write a verdict, a status such as "work complete", a claim that the Definition of Done is`,
  `  met, or a rule-by-rule evidence section. Verification is a separate step and it does not trust`,
  `  these notes. Writing "done" there achieves nothing except misleading the next cycle.`,
  `- PARTIAL COMPLETION IS NOT DONE. Finishing some items out of a set finishes nothing: the verdict`,
  `  is all-or-nothing and it is decided against the repository, not against your notes.`,
  `- Record counts and specifics ("covered 56 of the 1000 files in <folder>, listed below"), never`,
  `  conclusions.`,
  `- Never claim an item is done unless the artifact on disk shows it.`,
]

const CONTEXT_WARNING = [
  `## Your context will run out before the whole job is done`,
  `That is expected. The loop starts a new session and continues. For that to work you must keep the`,
  `handoff file current AS YOU GO, not at the end:`,
  ``,
  `- After each discovery, append it to ${STATE_FILE} immediately.`,
  `- Record what you finished, what you are part-way through, and what you have not touched.`,
  `- Record dead ends too, so the next cycle does not repeat them.`,
  `- Assume you will be cut off mid-thought. Anything not written down is lost.`,
]

/**
 * The cycle 0 directive when the caller supplies none.
 *
 * The Definition of Done is the whole specification of the job, so there is nothing for a user to
 * type. Point the first session at the rules and the handoff notes and let it start on whichever rule
 * is unmet.
 */
export function startingDirective(): string {
  return [
    `# Definition of Done loop — cycle 0`,
    ``,
    `Do the work needed to satisfy the Definition of Done in this repository.`,
    ``,
    `## Read first`,
    `1. ${RULES_FILE} — the full Definition of Done. This is the specification of the job.`,
    `2. ${STATE_FILE} — handoff notes. Work from earlier runs is recorded here.`,
    `3. The artifacts those rules refer to, to see what already exists.`,
    ``,
    `Then start on the first rule that is not met. Do not redo finished work.`,
    ``,
    ...CONTEXT_WARNING,
    ``,
    ...HANDOFF_RULES,
    ``,
    `Do not verify your own work; an independent check runs automatically when you finish.`,
  ].join("\n")
}

/** The next work directive after a failing verdict. Built from the new verdict alone. */
export function workDirective(verdict: Verdict): string {
  return [
    `You are continuing work already in progress. This is a fresh session with no memory of previous`,
    `cycles. Everything done so far is saved in this repository.`,
    ``,
    `## Read first`,
    `1. ${STATE_FILE} — the handoff notes from previous cycles. Start here.`,
    `2. ${RULES_FILE} — the full Definition of Done.`,
    `3. The artifacts those rules refer to, to see what is already done.`,
    ``,
    `Do not redo finished work.`,
    ``,
    ...CONTEXT_WARNING,
    ``,
    ...HANDOFF_RULES,
    ``,
    `## Do this now`,
    verdict.directive,
    ``,
    `## What the independent check found missing`,
    ...verdict.gaps.map((gap) => `- ${gap}`),
  ].join("\n")
}

/**
 * The work directive after a passing verdict that has not yet reached the streak.
 *
 * A pass is not the end of the run, so the work turn still needs a job. Asking it to hunt for what
 * the check missed is the useful job: it is the only turn with edit access, and if it finds nothing
 * the next independent verdict extends the streak anyway.
 */
export function reauditDirective(streak: number, needed: number): string {
  return [
    `An independent check reported that the Definition of Done is met. That is ${streak} of the`,
    `${needed} consecutive independent confirmations this run requires, so the job is NOT finished`,
    `and that verdict is not to be trusted.`,
    ``,
    `This is a fresh session with no memory of previous cycles.`,
    ``,
    `## Read first`,
    `1. ${RULES_FILE} — the full Definition of Done.`,
    `2. ${STATE_FILE} — the handoff notes from previous cycles.`,
    `3. The SOURCE DATA the rules name, and the ARTIFACTS the work produced.`,
    ``,
    `## Do this now`,
    `Try to prove that verdict wrong, then fix whatever you find.`,
    ``,
    `- Take each rule that covers a SET and enumerate that set from the SOURCE, not from the`,
    `  artifact's own headings. Compare the counts. Report both numbers in ${STATE_FILE}.`,
    `- Take a random handful of already-finished entries and check them against the source in detail.`,
    `  Look for filled-in-but-wrong content, not just missing content.`,
    `- Look for placeholder bodies, empty cells, stub sections, and copied text that was never`,
    `  checked against the source.`,
    `- Fix everything you find. If you genuinely find nothing, say so in ${STATE_FILE} as a fact`,
    `  ("enumerated X of Y, checked N entries in detail, found nothing wrong") without declaring the`,
    `  job complete.`,
    ``,
    ...HANDOFF_RULES,
  ].join("\n")
}

/**
 * The verify turn's prompt.
 *
 * Independence is the whole point. An earlier version pointed the verifier at the handoff file and
 * asked it to cross-check the claims there, which is how a work agent's own "work complete" note
 * became the evidence that ended a run 56 items into a job of about a thousand. So the prompt names
 * its two sources of truth, bans every completion claim, and requires the verifier to enumerate a
 * quantified set from the SOURCE before judging it.
 */
export function verifyPrompt(rules: string, cycle: number): string {
  return [
    "Judge this repository against EVERY rule in the Definition of Done below.",
    "",
    "The verdict is BINARY. Either every rule is met, or the job is not done. There is no partial",
    "credit, no score, and no percentage. One unmet rule means the whole job is not done.",
    "",
    "You are an INDEPENDENT check. Judge ONLY from two sources of truth:",
    "  (a) the SOURCE DATA the rules refer to, and",
    "  (b) the ARTIFACTS the work produced.",
    "Open both with read, glob, grep, and list before judging any rule. Never judge from the rule text",
    "alone.",
    "",
    `${STATE_FILE} is a pile of UNVERIFIED CLAIMS written by the worker you are judging. It is NOT`,
    "evidence. Never accept any claim from it:",
    "  - Only file contents count as evidence. Confirm every claim against the actual source",
    "    artifacts yourself.",
    "  - A claim you cannot independently confirm is itself a GAP, and your directive must be to",
    "    correct that file so it states what is actually there.",
    '  - If that file contains a verdict, a status such as "complete", or a rule-by-rule',
    "    self-assessment, that is a GAP on its own: the worker does not decide whether the job is",
    "    done. You do.",
    "The same goes for every other status file, progress note, changelog, and comment in the",
    "repository. A claim of completion is never evidence of completion.",
    "",
    "Before judging any rule that covers a SET of things, enumerate the set in the SOURCE first, using",
    "glob, grep, list, and read. Then count how many of those members are actually done, and put BOTH",
    "numbers in `gaps`.",
    "",
    "Inability to enumerate the full set is NOT DONE, never done. If the set is too large to enumerate",
    "within the steps you have, that is itself a gap: say so, report how far the enumeration got, and",
    "make the directive continue the enumeration from there.",
    "",
    'Never infer coverage from the artifact alone. A rule about "every X" is judged by walking the',
    "source, not by reading the artifact's own table of contents: an artifact that documents one item",
    'already satisfies "every documented item has a table", which proves nothing.',
    "",
    "Judge the WHOLE job, not just the most recent change. Do not return pass because the work looks",
    "thorough or because a lot was clearly done.",
    "",
    `This is cycle ${cycle}.`,
    "",
    "=== Definition of Done ===",
    rules,
    "",
    "=== Required reply ===",
    "Reply with ONE JSON object and nothing after it. No explanation following the JSON.",
    "",
    '{"outcome":"pass"|"fail","gaps":["one line per unmet rule"],"directive":"the next unit of work"}',
    "",
    'Set outcome to "pass" only when you have confirmed every rule from the source and the artifacts,',
    "and then use an empty gaps array and an empty directive. Otherwise set outcome to \"fail\", list",
    "the unmet rules in gaps, and put the single next concrete unit of work in directive. The directive",
    "must describe NEW work that closes a gap, not a restatement of what was already attempted.",
  ].join("\n")
}

/**
 * The slice of the SDK client the loop uses. Structural so a test can drive the loop with a stub; the
 * real `createOpencodeClient(...)` satisfies it.
 */
export type LoopClient = {
  session: {
    create(input: { title?: string }): Promise<{ data?: { id: string }; error?: unknown }>
    prompt(input: {
      sessionID: string
      model: { providerID: string; modelID: string }
      agent?: string
      parts: Array<{ type: "text"; text: string }>
    }): Promise<{
      data?: { info: { error?: unknown }; parts?: Array<{ type: string; text?: string }> }
      error?: unknown
    }>
    /**
     * What every live session is currently doing, keyed by session id.
     *
     * The one place a pending retry is visible from outside. Values are `SessionStatus`: idle, busy, or
     * retry with the refusal message, the operator action behind it, and when the next attempt is due.
     */
    status(input: Record<string, never>): Promise<{
      data?: Record<string, { type: string; message?: string; attempt?: number; next?: number; action?: { reason?: string } }>
      error?: unknown
    }>
    /** Stop the server retrying a turn we have given up on, so it does not hold the model for hours. */
    abort(input: { sessionID: string }): Promise<unknown>
  }
}

export type LoopResult = { reason: "pass" | "budget"; cycles: number; verdict: Verdict }

export async function runLoop(input: {
  client: LoopClient
  initialDirective: string
  budget: number
  /** Consecutive passing verdicts needed to end the run. Clamped to at least 1. */
  passStreak?: number
  /** Model chain for the work turn. Defaults to WORK_MODELS. */
  workModels?: Model[]
  /** Model chain for the verify turn. Defaults to VERIFY_MODELS. */
  verifyModels?: Model[]
  /** How long to wait when a whole chain is out of quota. Defaults to QUOTA_COOLDOWN_MS. */
  quotaCooldownMs?: number
  /** How often to check a running turn for a recorded refusal. Defaults to TURN_POLL_MS. */
  turnPollMs?: number
  /** How long a turn may run before it is abandoned. Defaults to TURN_DEADLINE_MS. */
  turnDeadlineMs?: number
  /** How far out a scheduled retry may be before the model is abandoned. Defaults to RETRY_TOLERANCE_MS. */
  retryToleranceMs?: number
  /** Prefixes every session title, so the TUI's picker shows which run a session belongs to. Defaults to RUN_ID. */
  runId?: string
  /**
   * Called once at the start of every cycle, so a definition corrected while the run is going takes
   * effect from the next cycle. Must always return usable text; see the wrapper in main.
   */
  rules: () => string
}): Promise<LoopResult> {
  const needed = Math.max(1, Math.trunc(input.passStreak ?? PASS_STREAK) || 1)
  const cooldown = Math.max(0, input.quotaCooldownMs ?? QUOTA_COOLDOWN_MS)
  // RUN_ID, not input.runId: the files are keyed off the environment, and logging a title override
  // here would point at a folder nothing is being written to.
  log(`run ${RUN_ID}  files ${RUN_DIR}`)
  log(`rules ${RULES_FILE}`)
  log(`budget ${Number.isFinite(input.budget) ? input.budget : "unbounded"}  pass streak ${needed}`)
  log(`work models   ${(input.workModels ?? WORK_MODELS).map(modelName).join(" -> ")}`)
  log(`verify models ${(input.verifyModels ?? VERIFY_MODELS).map(modelName).join(" -> ")}`)
  log(
    `turn watchdog poll ${Math.round((input.turnPollMs ?? TURN_POLL_MS) / 1000)}s  retry tolerance ${Math.round((input.retryToleranceMs ?? RETRY_TOLERANCE_MS) / 1000)}s  deadline ${Math.round((input.turnDeadlineMs ?? TURN_DEADLINE_MS) / 60_000)}m`,
  )

  let directive = input.initialDirective
  let last: Verdict = { outcome: "fail", gaps: [], directive }
  /** Consecutive passing verdicts so far. Any fail resets it. */
  let streak = 0
  /** Consecutive cycles that could not reach the server at all. Three in a row ends the run. */
  let deadCycles = 0
  /** The definition the previous cycle ran against, so an edit made mid-run is visible in the log. */
  let previousRules: string | undefined

  for (let cycle = 0; cycle < input.budget; cycle++) {
    // Read once per cycle, not once per turn: the work turn and the verify turn of the same cycle must
    // be held to the same text, or a rule edited between them would be worked to one version and judged
    // against another. A cycle boundary is also the only safe place to change the job, since a turn
    // already in flight cannot be re-aimed.
    const rules = input.rules()
    if (previousRules !== undefined && rules !== previousRules)
      log(
        `cycle ${cycle}: definition changed since the last cycle (${previousRules.length} -> ${rules.length} chars), this cycle uses the new text`,
      )
    previousRules = rules

    // A fresh session per cycle is the whole point: context never accumulates across cycles, so work
    // can continue indefinitely through a bounded context window. Everything carried forward travels
    // through the repository on disk plus the directive, never through conversation memory.
    const work = await attempt(`cycle ${cycle} create work session`, 3, async () => {
      const made = await input.client.session.create({ title: `${input.runId ?? RUN_ID} work ${cycle}` })
      if (!made.data) throw new Error(describe(made.error))
      return made.data
    })
    // A fresh verifier session too, so a verdict is never influenced by the verdict before it. That
    // is what makes the pass streak worth anything.
    //
    // Deliberately a ROOT session rather than a child of the work session. A session with a parentID
    // is hidden from the TUI's session picker, which made every verify turn impossible to watch — the
    // list showed "dod work N" and nothing else, so the run looked like it had no verification step at
    // all. The parent link bought nothing: independence comes from being a separate session with its
    // own prompt, not from the absence of a parent. Prompting a subagent-mode agent on a root session
    // is accepted by the server; checked against 1.18.18.
    const verifier = work
      ? await attempt(`cycle ${cycle} create verify session`, 3, async () => {
          const made = await input.client.session.create({ title: `${input.runId ?? RUN_ID} verify ${cycle}` })
          if (!made.data) throw new Error(describe(made.error))
          return made.data
        })
      : undefined

    if (!work || !verifier) {
      // The server is unreachable. Count it, wait, and try the next cycle rather than exiting: a
      // restarting server should not end an unattended run.
      if (++deadCycles >= 3) die("three consecutive cycles could not reach the server; stopping")
      log(`cycle ${cycle}: could not reach the server, retrying next cycle`)
      await sleep(15_000)
      continue
    }
    deadCycles = 0
    log(`cycle ${cycle}: work ${work.id}  verifier ${verifier.id}`)

    const worked = await runTurn({
      client: input.client,
      label: `cycle ${cycle} work turn`,
      sessionID: work.id,
      models: input.workModels ?? WORK_MODELS,
      text: directive,
      pollMs: input.turnPollMs,
      deadlineMs: input.turnDeadlineMs,
      retryToleranceMs: input.retryToleranceMs,
    })
    if (worked.response) log(`cycle ${cycle}: work turn ran on ${modelName(worked.model as Model)}`)
    // No progress this cycle, but the repository is unchanged and the handoff file still holds the
    // state, so the next cycle picks up where this one stopped.
    else log(`cycle ${cycle}: work turn produced nothing`)

    // Verification runs after every work turn, unconditionally. It never sees the work transcript:
    // its session is new and its prompt carries only the rules and the cycle number.
    const verified = await runTurn({
      client: input.client,
      label: `cycle ${cycle} verify turn`,
      sessionID: verifier.id,
      models: input.verifyModels ?? VERIFY_MODELS,
      agent: VERIFIER_AGENT,
      text: verifyPrompt(rules, cycle),
      pollMs: input.turnPollMs,
      deadlineMs: input.turnDeadlineMs,
      retryToleranceMs: input.retryToleranceMs,
    })
    if (verified.response) log(`cycle ${cycle}: verify turn ran on ${modelName(verified.model as Model)}`)

    // Reasoning arrives as its own part type, so only text parts are considered. A missing or errored
    // verify turn routes down the same path as an unusable reply: a fail, which keeps the loop moving
    // instead of ending the run.
    const reply = (verified.response?.data?.parts ?? [])
      .filter((part) => part.type === "text" && typeof part.text === "string")
      .map((part) => part.text as string)
      .join("\n")
    last = verified.response ? parseVerdict(extractJsonText(reply)) : parseVerdict(undefined)

    // Every model in a chain is rate-limited and nothing else went wrong. Sitting still is the only
    // useful move: the next cycle would fail identically and immediately.
    if (worked.starved || verified.starved) {
      log(`cycle ${cycle}: all free models are out of quota, waiting ${Math.round(cooldown / 60_000)}m`)
      await sleep(cooldown)
    }

    if (last.outcome === "pass") {
      streak++
      log(`cycle ${cycle}: pass ${streak}/${needed}`)
      if (streak >= needed) {
        log(`DoD met: ${streak} consecutive independent verdicts, after ${cycle + 1} cycle(s)`)
        return { reason: "pass", cycles: cycle + 1, verdict: last }
      }
      directive = reauditDirective(streak, needed)
      continue
    }

    // One fail throws the streak away. Confirmations have to be consecutive or they mean nothing.
    if (streak > 0) log(`cycle ${cycle}: fail resets the pass streak from ${streak} to 0`)
    streak = 0
    log(`cycle ${cycle}: not done  gaps ${last.gaps.length}  next: ${last.directive.slice(0, 100)}`)
    // Built from the new verdict alone, so the previous directive never reaches the next work turn.
    directive = workDirective(last)
  }

  log(`cycle budget ${input.budget} reached without meeting the DoD`)
  log(`outstanding gaps:\n${last.gaps.map((gap) => `- ${gap}`).join("\n")}`)
  return { reason: "budget", cycles: input.budget, verdict: last }
}

if (import.meta.main) {
  // `--prepare` allocates the next run and seeds its definition, then exits. The runner calls this
  // first so the operator can read and correct the definition before any work starts. One
  // pipe-delimited line, because the caller is a batch file.
  if (process.argv[2] === "--prepare") {
    const run = prepareRun()
    console.log([run.id, run.dir, run.rules].join("|"))
    process.exit(0)
  }

  if (!process.env.DOD_RUN_ID?.trim())
    die("DOD_RUN_ID is not set. Launch with start_syzyf.bat, which allocates the run folder and lets you review the definition first.")
  mkdirSync(RUN_DIR, { recursive: true })

  const initial = process.argv[2]?.trim() || startingDirective()
  // Fail before creating anything if the rules are missing or empty.
  let lastGoodRules = loadRules()
  // Record what this run set out to do, but only on its very first launch: no log means no cycle has
  // ever run, so the definition on disk is still the original one. Resuming a run that already has a
  // log must not claim a definition edited three cycles ago was what it started with.
  if (!existsSync(LOG_FILE)) snapshotOriginalRules(lastGoodRules)

  const result = await runLoop({
    client: createOpencodeClient({ baseUrl: BASE_URL }),
    initialDirective: initial,
    budget: CYCLE_BUDGET,
    passStreak: PASS_STREAK,
    // The review window stays open for the whole run, so this file can be mid-write when a cycle
    // starts. Falling back to the last good copy keeps the run alive through a save; the next cycle
    // picks up the finished edit a few minutes later.
    rules: () => {
      const text = readRules()
      if (text !== undefined) {
        lastGoodRules = text
        return text
      }
      log(`WARNING no usable definition at ${RULES_FILE} right now, reusing the copy from the last cycle`)
      return lastGoodRules
    },
  })
  process.exit(result.reason === "pass" ? 0 : 1)
}
