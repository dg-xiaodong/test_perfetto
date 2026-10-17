# Delivery wrap-up — v2_bord_test (v1.0.2 RC)

Short closing report. No smoke test was re-run, the frozen candidate was not
modified, and the test scope was not expanded.

## 1. RC tag

- During the test `perfetto-memory-debugging-v1.0.2-rc1` was **absent** on the
  remote; the test pinned commit `0fa17e08eb8b93a9944232e380c7ddb39666fcf2`.
- At this wrap-up an **annotated tag** was created at that exact commit and
  pushed:
  - tag object `96dc8099615ad8520a041620d335da7fb7346287`
  - peels to `0fa17e08eb8b93a9944232e380c7ddb39666fcf2` (verified with
    `git ls-remote --tags origin`)
- No existing tag was moved or recreated.

## 2. Public trace data

- Repository visibility: **public** (anonymous GitHub API: `private=false`,
  `forks_count=0`).
- Raw `.pftrace` files currently public: **7**
  - 5 from this smoke test under `v2_bord_test/hostwork/captures/`, added in
    commit `7e72856` on explicit owner instruction at delivery time;
  - 2 pre-existing files under `x5_heapprofd_traces/`, already present in the
    frozen commit `0fa17e08...` (added by the owner in `3dcef36`).
- Authorization record: the 5 test traces have the owner's explicit push
  instruction; the 2 pre-existing traces pre-date this session and their
  separate public-disclosure approval could not be verified here.
- Protective actions **not executed**: this environment has no GitHub admin
  credential (`gh` absent, no `GITHUB_TOKEN`), so repository visibility could
  not be restricted; no history rewrite / force-push was performed.
- `DATA_CLEANUP_PLAN.md` contains the full inventory (paths, Git blob ids,
  SHA-256), the authorization status, the private-master-copy locations, the
  two history-cleanup options (Option A preserves the frozen tag; Option B
  requires a re-freeze), the GitHub-support purge steps and post-cleanup
  verification. Deleting the current directory alone does **not** clean history.
- The earlier report sentence claiming traces were not uploaded has been removed
  and replaced by §10 of `SMOKE_REPORT.md`.

## 3. Report status separation

`SMOKE_REPORT.md` §0 and `README.md` now state explicitly:

| State | Result |
|---|---|
| S1/S2/S3 functional smoke test | **PASS** |
| Native dump timeline / complete symbolization / Perfetto UI | **Not fully verified (UNKNOWN)** |
| Real X5 end-to-end execution | Executed on the live board; evidence in this record |
| Official v1.0.2 release / deployment approval | **Not decided here** — separate formal review |

## 4. Candidate tests: unittest, not pytest

`python3 -m unittest discover -s tests -v` on the frozen candidate:
**Ran 76 tests … OK** (76/76), matching `MANIFEST.json`
(`local_unit_tests_passed: 76`). The suite imports `unittest` only; `pytest` is
not a dependency, so its absence on the host is an environment fact, not a Skill
defect. Log: `logs/candidate_unittest.log`.

## 5. Frozen version

`v2_modify/candidate-v1.0.2/` and commit `0fa17e08...` were not modified; the
only repository additions are the test record (`v2_bord_test/`) and the RC tag.

## Decision needed

1. **Deployment**: this record supports entering formal deployment review; it is
   not itself an approval.
2. **Public traces**: confirm whether the 7 public `.pftrace` files may stay
   public. If not, approve making the repository private and choose Option A or
   B from `DATA_CLEANUP_PLAN.md`.
