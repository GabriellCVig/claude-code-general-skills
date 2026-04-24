---
name: plan-improve
description: Improve a plan before presenting it for approval. Reads the project's CLAUDE.md to pick up conventions, then applies patterns derived from 9 months of observed feedback — embeds conversation context, adds issue/git/PR steps, identifies parallelizable steps, adds verification, scopes large plans into phases. Invoke after drafting a plan, before showing it to the user.
allowed-tools:
  - Read
  - Glob
  - Grep
  - Bash(git *)
  - Bash(gh pr *)
---

# plan-improve

Apply a standard set of improvements to any drafted plan before presenting it to the user for approval.

## Why this exists

The conversation context is usually cleared when approving a plan. Everything discovered during the planning conversation that is not written into the plan text is then permanently lost. This skill ensures the plan is fully self-contained and pre-applies the corrections the user would otherwise have to give manually.

> "i will clear your context when approving the plan so make sure to take what you have garnered from this convo that could be useful in the plan and include it explicitly. if something is not included in the plan it will be forgotten and would have to be rediscovered"

---

## Meta-Principle: Questions vs. Instructions

This skill produces plans that are executed by agents. The single most common execution failure
is treating a user question as implicit permission to act. Embed this distinction clearly in every
plan's executor contract (see Check 11 and Check 13).

**Rule:** A message that contains only questions — no imperative, no directive, no instruction —
requires information only. No phase advancement. No tool use beyond research and answering.
Only an explicit "proceed", "do it", "go ahead", or equivalent directive authorises action.

---

## Step 0: Read Project Context

Before improving the plan, read the project's CLAUDE.md (if it exists) to discover:

```
- Issue/ticket format (e.g. TEAMCIM-XXX, PROJ-XXX, GH-XXX)
- Branch naming convention
- Test command (e.g. `uv run pytest`, `npm test`, `go test ./...`)
- How the local dev stack is started
- Service architecture patterns (if a services-based project)
- Deployment mechanism (Helm, Docker, GitHub Actions, etc.)
```

Use these discovered values when applying the improvements below. If no CLAUDE.md exists, fall back to sensible defaults inferred from the repo structure.

---

## Apply Each Improvement in Order

Work through all 13 checks. For each: if the plan already satisfies it, leave it. If not, add or fix it. Present only the final improved plan — not the checklist.

---

### 1. CONTEXT SELF-CONTAINMENT (Critical)

The plan must be readable and executable in a **fresh context with zero memory of the conversation**.

Embed inline in the plan:
- Any specific values discovered during the conversation (IDs, config values, file paths, query results, API responses)
- Decisions made and *why* — so they don't have to be re-derived
- Approaches that were considered and rejected — so dead ends aren't re-explored
- All file references as **full paths**, never "the config file" or "the handler"
- Any external data (logs, database query results, API output) the implementation depends on
- Standards, spec versions, or documentation sections referenced

Bad: `Step 3: Update the transformer handler`
Good: `Step 3: Update packages/cim_mapper/src/cim_mapper/handlers/power_transformer.py — add r0/x0 fields per CGMES 3.0.0 SSH profile §4.2. Evidence: confirmed missing in SHACL validation output 2026-03-18.`

---

### 2. ISSUE / TICKET INTEGRATION

Every plan must be anchored to a tracked issue. Include issue steps as explicit numbered items, not afterthoughts.

Check:
- [ ] Is there an issue/ticket referenced? If not, flag it as Step 0: "Create issue first — branch name and PR title depend on it"
- [ ] Is the branch name derived from the issue key? Use format from project CLAUDE.md or `issue-XXX/short-description`
- [ ] Does the plan include an explicit step to **comment on the issue** with a summary of what was implemented?
- [ ] Does the plan include a step to **transition the issue status** (e.g., In Progress → In Review)?
- [ ] For multi-part work: are subtasks or child issues mentioned?

Standard issue steps to add at the end of every plan:
```
Step N: Comment on [ISSUE-KEY] with implementation summary
Step N+1: Move [ISSUE-KEY] to In Review (or equivalent)
```

---

### 3. GIT WORKFLOW WITH CORRECT ORDERING

Branch, worktree, commit, and PR steps must appear explicitly with the **correct sequence**. This ordering is commonly wrong in first-draft plans.

Correct sequence:
```
1. Confirm issue key → derive branch name
2. Create branch FROM the main branch (trunk/main), not from current working branch:
   git branch ISSUE-XXX/task-name <main-branch>
3. [implementation work]
4. Commit (with issue-prefixed message)
5. Update main branch: git fetch origin && git merge origin/<main-branch>
   ← This happens AFTER committing, not before
6. Merge updated main into feature branch
7. Create PR
8. Verify CI passes on PR
```

Common mistakes to fix:
- Branch created from current branch instead of main → correct it
- Trunk/main merged *before* committing → reorder
- PR created without CI check step → add it

---

### 4. PARALLELIZATION

**Skip this check if the plan has fewer than 3 independent implementation steps** — parallelization notation on small plans adds noise without benefit.

Otherwise: where steps are independent, group them for parallel execution. This reduces wall-clock time significantly for multi-component changes.

Identify:
- Steps with no dependencies between them → mark as parallel
- Steps that must happen in sequence → keep as numbered steps

Format:
```
[Parallel — run concurrently]:
  - Agent A: [independent task 1]
  - Agent B: [independent task 2]
  - Agent C: [independent task 3]
[After all parallel agents complete]:
  - Run test suite
  - Commit
```

Common parallel patterns across projects:
- Multiple independent handler/module changes (one agent per module)
- Infrastructure changes (Agent A) concurrent with business logic changes (Agents B–N)
- Read-only investigation sub-agents run while main agent continues planning

---

### 5. VERIFICATION STEPS

Plans must include concrete verification — not "test it" but specific commands, inputs, and expected outputs.

**Expand underspecified test steps.** If a step says only "add tests" or "write tests", replace it with:
```
Add tests in [specific test file path]
  Scenarios to cover:
    - [happy path: specific input → specific expected output]
    - [edge case: e.g. zero/null input → expected error or guard behaviour]
  Verification:
    [project test command from CLAUDE.md]
    Expected: all tests pass, no regressions
```

**After service/container changes (if applicable):**
```
Verification: Rebuild and test against [specific input/dataset]
  - Check service is healthy
  - Run [specific test scenario]
  - Confirm [specific expected output]
```

**After PR creation:**
```
Verification: Confirm CI passes
  gh pr checks [branch-name]   (or equivalent CI interface for this project)
  Expected: all checks green before requesting review
```

**For assumption-dependent steps:**
```
PREREQUISITE CHECK: Verify [assumption] by [specific action — Glob/Grep/curl/query].
  Expected: [specific result].
  If fails: [fallback or stop condition].
```

---

### 6. ASSUMPTIONS WITH EVIDENCE

Every non-obvious assumption must cite the source that supports it.

Bad: `Step 3: Map the resistance field from the source data`
Good: `Step 3: Map resistance from field 'CustAtt_resistance' — present in standard_resultTypes.json:47, networkSourceId=9. Verified in live export 2026-03-18.`

If an assumption cannot be verified from available data, add a prerequisite check step **before** it — not after:

```
PREREQUISITE CHECK: Verify [assumption] by [specific action].
  Expected: [specific result].
  If fails: [fallback approach or stop — do not proceed with unverified assumption].
```

---

### 7. DOCUMENT DECISIONS EXPLICITLY

When a choice was made during planning — to do something one way instead of another — that decision must appear in the plan with its rationale. This prevents backtracking to rejected approaches in future sessions.

**Limitation:** This check is only effective when plan-improve is invoked in the same session as planning, before context is cleared. If context was already cleared before invoking this skill, the agent cannot reconstruct decisions retroactively. In that case, note in the "What gets lost" block: *"Decisions made during planning were not captured — approach choices may need re-justification if challenged."*

For each significant decision made during the planning conversation, embed:
```
Decision: [What was chosen]
Rejected alternative: [What was not chosen, and why]
```

Examples:
```
Decision: Use batched SPARQL DELETE (50K triples/batch) for graph clearing.
Rejected alternative: DROP GRAPH — causes TransactionAfterImageLimit on graphs >3GB (confirmed via isql).

Decision: SPARQL-based property profiling over custom Python traversal.
Rejected alternative: Deducing properties from Jira — unreliable and indirect.
```

Applies to: architectural choices, library/tool selections, API approach decisions, data format choices, scope boundaries.

---

### 8. ANSWER "WHERE?" AND "WHAT?" UPFRONT

Plans must not leave data locations, output destinations, or formats unspecified.

Check that the plan answers:
- Where does output go? (exact path, bucket, table, topic)
- Which environment or dataset is used for testing?
- Which version or profile of a standard does this affect?
- If a new file/module: where exactly does it live in the project?
- If writing to external storage: which container/bucket, what path pattern, what format?

---

### 9. ACCOUNT FOR EXISTING INFRASTRUCTURE

Audit what infrastructure already exists in the codebase, then ensure the plan accounts for it. Do not add steps for infrastructure that doesn't exist — but do not ignore infrastructure that does.

**Use Glob and Grep to verify before flagging** — do not assume infrastructure exists. Only flag what you confirm.

Check for the presence of each of the following, and if present, verify the plan addresses it:

- **CI/CD pipeline** — `Glob(".github/workflows/*.yml")` or equivalent. If found: does this change trigger it correctly? Are new workflow files needed?
- **IAM / service accounts** — look for Terraform, Helm values with serviceAccount, or cloud IAM config. If found: does the plan include required additions?
- **Observability** — look for logging, tracing, or metrics packages in the codebase. If found: does the new code integrate with them?
- **Deployment manifests** — `Glob("k8s/**/*.yaml", "docker-compose*.yml")`. If found: does the plan update them where needed?
- **Local dev stack** — `Glob("docker-compose*.yml")`. If found: does the plan account for local testing?
- **Shared contracts/types** — look for a shared types/contracts package. If found: does the plan update it?

Only add steps for what you find. If nothing applies, omit this section entirely.

---

### 10. SCOPE AND PHASING

If the plan feels overly ambitious, say so explicitly and propose a Phase 1 boundary. Always show the big picture even when implementing a small slice — the user values understanding how the immediate work fits into the larger goal.

```
Phase 1 (this PR): [minimal slice — specific, shippable]
Phase 2 (follow-on): [next increment — specific]
Long-term direction: [broader vision this builds toward]
```

Do not apply a rigid step-count or module-count threshold. Use judgment: a 10-step plan that is all tightly coupled is fine; a 4-step plan that spans unrelated systems may need splitting.

Warning signs of overreach:
- Changes across many unrelated modules with no shared abstraction
- Mixes infrastructure provisioning with business logic implementation
- Proposes "comprehensive" or "complete" rewrites rather than incremental change

---

### 11. EXECUTION STRATEGY

Add an `## Execution Strategy` section to the plan. This makes the *how* of execution explicit — not just what to build, but how the work will be carried out.

Three modes to choose from:

- **Solo** — implement directly in this session, no agents spawned
- **Subagent bursts** — parallel `Agent` tool calls for independent tracks, lead agent synthesises results
- **Agent team** — spawn via `/orchestrate` with interactive teammates (implementer + reviewers); user can message teammates directly mid-run

If the right mode is obvious from the plan, state it and briefly explain why. If it isn't obvious, say so and ask the user — do not guess. Surface the question rather than make a call.

Add to the plan:

```
## Execution Strategy
[Recommended mode, or: "Unclear — see question below"]

[1 sentence rationale, or the specific question for the user if strategy is ambiguous]

If agent team: spawn via /orchestrate. Suggested composition: [implementer + relevant reviewers]
If subagent bursts: steps [X, Y, Z] run in parallel; lead synthesises.
If solo: implement directly in this session.
```

**Embed an executor behavioral contract in every plan's Execution Strategy section:**

```
### Executor Contract (read before starting each phase)

1. **Questions ≠ instructions.** If a user message during execution contains only questions
   (no imperative, no directive), respond with information only. Do not advance to the next
   phase. Do not infer implied instructions from questions. Only advance when explicitly told to.

2. **Gate conditions are exhaustive.** The listed gate conditions for each phase are complete.
   Do not add implicit conditions (PR review, stakeholder approval, etc.) unless they appear
   in the gate list.

3. **Proceed immediately when gates pass — but assess before acting.** When all gate conditions
   for a phase are met, do not summarize completion and wait passively. Instead, in the same
   response, assess three things before starting:

   a. **Orchestration:** Does this phase's Execution Strategy call for spawning an implementer
      or team? If so, spawn now — "immediately" means no extra delay, not solo. More broadly,
      default toward handing off to a teammate when the work ahead is well-defined and
      executable. The threshold for spawning a teammate is lower than it feels: doing so
      preserves the lead's context, keeps human-in-the-loop sessions cleaner, and makes
      future handovers easier because teammates already have the task context. Prefer spawning
      over doing it yourself when the next phase involves implementation, testing, or review.

   b. **Planning depth:** Is this phase as fully specified as the one that just completed? If
      the next phase is underspecified (e.g., Phase 1 was detailed but Phase 2 is two bullet
      points), surface that gap. Propose clarifying questions to the user before proceeding
      rather than filling the gap with assumptions.

   c. **Human input:** Are there decisions in the next phase that the user should weigh in on —
      scope choices, risk acceptance, resource constraints — that weren't settled during planning?
      If yes, ask those questions now, in the same response as reporting the gate-pass. Then wait
      for answers before starting the phase.
```

This contract is modeled on OpenClaw's SOUL.md pattern: behavioral boundaries embedded
directly in the executor's instructions rather than left implicit.

**Research-gated phases — structural gate enforcement:**

When the execution strategy involves a research or scouting phase that must complete before implementation begins, prose like "implementers cannot start Phase 2 until scouts are complete" is advisory and will be skipped. Convert it to a structural GATE block at the top of each dependent implementation phase:

```
GATE (before starting this phase):
- [ ] [artifact name, e.g. /tmp/oxigraph_research.md] exists and covers [specific questions]
- [ ] [decision or blocker from Phase N-1] is resolved
If any gate fails: STOP. Do not proceed. Run [Phase N-1] first.
```

The gate block must name specific files or artifacts, not general conditions. "Scout reports are complete" is not a gate. "/tmp/oxigraph_research.md answers Categories A–D" is a gate.

**Per-phase executor assignment:**

When a plan has multiple named phases (Phase 0, Phase 1, Phase 2…), each phase must have an explicit executor label:

- `Executor: Lead` — lead runs this directly (only for lightweight, read-only, or single-command steps)
- `Executor: Implementer teammate` — spawn a teammate with a precise prompt
- `Executor: Verification teammate (Sonnet)` — spawn a Sonnet teammate for rebuild + run + check sequences; escalate to Opus if verification requires debugging or complex interpretation

Flag any phase where the executor is `Lead` AND the phase contains more than 2 shell commands or any Docker/pipeline/DB operation. Add to Common Mistakes table.

---

### 12. MIXED IMPLEMENTATION / PLACEHOLDER HAZARD

When a plan section contains implementation code or configuration alongside placeholder markers (`**from scout report**`, `[TBD]`, `[from Phase 1]`, `<tag-from-scout>`), flag this as an execution hazard.

A mixed state — some values committed, some deferred — causes executors to fill the deferred fields from training knowledge or reasonable assumptions rather than from research. The filled-in values signal "this section is ready to execute," and the placeholders are treated as optional refinements.

**Check:** Scan implementation templates, Dockerfile snippets, code scaffolding, and configuration blocks for this pattern.

**Fix:** Enforce one of two clean states:

- **All committed** — every value is a decision stated in the plan with rationale. Remove placeholders entirely. The implementation can be executed from the plan text alone, and that is intentional.
- **All deferred** — every value that depends on research is a placeholder, and the section is preceded by a GATE block (see Check 11) that must be satisfied before the section can be used. The section cannot be plausibly executed from its own text without the research.

Never leave a section where some values are filled in and others say "from scout report." That combination will always produce an executor who fills the gaps from assumptions.

Add to the Common Mistakes table:

| Implementation code mixed with `[TBD]` / `**from scout report**` placeholders | 12 | Either commit all values as decisions, or gate all with a GATE block; no mixed states |

---

### 13. PHASE GATE TIMING DIRECTIVES

When a plan has multiple phases with gate conditions (GATE blocks, "do not start until" checklists), each gate block must include an explicit timing directive immediately after it.

**Add after every GATE block:**

```
⚡ Execute immediately when all gates above are met. Do not add conditions not listed here.
Do not wait for [PR review / stakeholder sign-off / external approval] unless one of the
gates above explicitly requires it. If the gates are met, proceed now.
```

**Why this matters:** A gate block that lists conditions A and B is silent on whether C, D, or E are also required. Without a timing directive, executors fill the silence with implicit conditions drawn from context (e.g., "it seems natural to wait for review first"). The directive closes that gap.

**Check:** Every gated phase in the plan has a timing directive. If any is missing, add one.

---

## Output Format

Present the improved plan as a clean numbered step list. Do **not** narrate the improvements inline — the plan should read as if it were always this good. All explanatory context belongs only in the trailing block below, not scattered through the plan steps.

End every plan with this block:

```
---
## Context embedded in this plan
- [Bullet: key decision or data point from the conversation that was embedded above]
- [Bullet: ...]

## What gets lost when you approve (context cleared)
- [Bullet: any conversation detail that couldn't be embedded — exploratory dead ends,
   alternative approaches considered, open questions deferred]
- (If nothing: "Nothing significant — all relevant context is embedded above.")
```

---

## Common Mistakes to Catch

| Mistake | Check | Fix |
|---------|-------|-----|
| "add tests" with no file, scenario, or expected output | 5 | Expand to specific file path, scenarios, and test command |
| "test it" with no command or expected output | 5 | Add exact command + expected output |
| Assumption stated with no source | 6 | Cite file, query, or data that supports it |
| Unverifiable assumption with no guard | 6 | Add PREREQUISITE CHECK block before the step |
| "update the issue" at the end | 2 | Add specific comment template + status transition |
| Branch created from current branch | 3 | Change to `git branch ... <main-branch>` |
| Main merged before committing | 3 | Reorder: commit first, then merge main |
| No CI check after PR | 3 | Add CI verification step |
| "the config file" | 1 | Replace with full path |
| Approach chosen without documenting why | 7 | Add Decision/Rejected alternative block |
| Parallelization block on a 2-step plan | 4 | Skip — guard requires 3+ independent steps |
| Infrastructure flagged without verifying it exists | 9 | Run Glob/Grep first; only flag what's confirmed |
| Plan feels overly ambitious | 10 | Flag it, propose explicit Phase 1 boundary |
| Improvements narrated inline | output | Move all explanation to trailing context block |
| Execution strategy missing from plan | 11 | Add ## Execution Strategy section; ask user if unclear |
| Execution strategy chosen when intent is ambiguous | 11 | Surface the question — don't guess |
| Research-gated phase with only prose gate ("wait for scouts") | 11 | Add GATE block naming specific artifacts; prose gates are skipped |
| Implementation code mixed with `[TBD]` / `**from scout report**` placeholders | 12 | Either commit all values as decisions, or gate all with a GATE block; no mixed states |
| Phase assigned to Lead contains Docker/pipeline/DB operations | 11 | Assign to a Sonnet verification teammate; lead presents a written plan before any shell execution |
| Phase gate with no timing directive — executor defers beyond stated conditions | 13 | Add ⚡ Execute immediately directive after every GATE block |
| Executor contract absent from Execution Strategy | 11 | Embed the 3-point behavioral contract in every plan's Execution Strategy section |
| Question from user during execution triggers phase advancement | 11 | Contract point 1: questions ≠ instructions — only advance on explicit directive |
