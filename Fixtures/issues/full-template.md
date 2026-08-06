## User story

As a maintainer, I want every pull request built and tested by something other than my laptop, so that a green tick means the same thing on Monday as it does on Friday.

## Acceptance criteria

The numbered list below is the contract; the prose above is the reason for it.

1. A workflow runs on `pull_request` targeting `main` and on `push` to `main`.
2. It runs the profile's build and test commands, `swift build` then `swift test`, from `ElliotKit`.
3. Its `pull_request` trigger has **no branch filter that excludes main**.
4. A failing test fails the job, and the failure is readable from the run log without a local checkout.
5. The run completes in a bounded time — a job-level `timeout-minutes` makes that visible.

## Problem

There is no `.github/workflows/` directory in this repository and branch protection is off, so nothing runs when a pull request opens: #47 was merged on one machine's word alone.

> [!IMPORTANT]
> #18, #19 and #20 — roughly 6 000 added lines between them — were merged the same way.

## Proposed solution

Add one workflow, on `pull_request` and on `push`, and nothing else. PR 72 carries the shape it should take.

<details>
<summary>🧠 Brainstorm</summary>

Three options were weighed before this one.

- A hosted runner costs nothing until the suite needs a signed build.
- A self-hosted mac mini is free and unlimited, and is one more machine to keep alive.
- No CI at all is what we have today, and #47 is what it produces.

</details>

<details>
<summary>📋 Spec</summary>

```yaml
on:
  pull_request:
    branches: [main]
  push:
    branches: [main]
# closes #47 — inside a fence, so this is not a chip
jobs:
  test:
    runs-on: macos-15
    timeout-minutes: 15
```

| Step | Command | Budget |
| --- | --- | --- |
| Build | `swift build` | ~60 s |
| Test | `swift test` | ~90 s |

</details>

## Area

`ElliotModel` · `ElliotAppKit`

---

## 🛠️ Implementation plan

- [x] Add `.github/workflows/ci.yml` on `pull_request` and on `push`
- [x] Run `swift build` from `ElliotKit`
- [x] Run `swift test`
- [ ] Set `timeout-minutes: 15` on the job
- [ ] Upload `TestResults/*.log` as an artifact on failure
- [ ] Turn on branch protection requiring the job
