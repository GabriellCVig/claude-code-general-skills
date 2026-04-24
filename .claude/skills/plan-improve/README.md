# TLDR: plan-improve

A skill that polishes any drafted plan before showing it to the user for approval — so the plan survives context-clearing and executes cleanly in a fresh session.

---

What it does: Reads the project's CLAUDE.md for conventions, then runs the plan through 13 checks:

1. Self-containment — embed all conversation context (paths, IDs, decisions) inline
2. Issue/ticket integration — anchor to a tracked issue with comment + status transition steps
3. Git workflow ordering — branch from main, commit before merging main, verify CI on PR
4. Parallelization — group independent steps (only if 3+)
5. Verification — replace "test it" with concrete commands + expected output
6. Assumptions with evidence — cite source or add a PREREQUISITE CHECK
7. Document decisions — record chosen approach + rejected alternatives
8. Answer where/what — exact paths, environments, formats
9. Existing infrastructure — verify CI/IAM/observability/manifests via Glob/Grep before flagging
10. Scope & phasing — flag overreach, propose Phase 1 boundary
11. Execution strategy — solo / subagent bursts / agent team, plus an embedded executor contract (questions ≠ instructions, gates are exhaustive, proceed immediately when gates pass)
12. Mixed placeholder hazard — no half-filled templates; either commit all values or gate all with a GATE block
13. Phase gate timing — every GATE block needs a ⚡ "execute immediately" directive

Output: A clean numbered plan (no inline narration of improvements) plus a trailing block listing embedded context and what gets lost on approval.

---

Core insight: Context is cleared on plan approval. Anything not written into the plan is permanently lost. This skill pre-applies the corrections users would otherwise have to give manually.
