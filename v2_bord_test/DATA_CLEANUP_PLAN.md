# Public trace-data exposure and history-cleanup plan

Status: **plan only — no history rewrite has been executed.** This document
records the exposure, the authorization evidence found, what could and could not
be done from this environment, and the exact procedure to remove the traces from
the public repository if the owner decides they must not be public.

## 1. Exposure inventory (repository `dg-xiaodong/test_perfetto`, public)

Verified via the anonymous GitHub API: `private=false`, `visibility=public`,
`forks_count=0`, `watchers_count=0`, default branch `main`.

At `main` (= test-record commit `7e72856`) the repository contains **7 raw
`.pftrace` files** (Git blob ids are the identifiers GitHub support needs):

| Path | Size | Git blob | SHA-256 |
|---|---|---|---|
| `v2_bord_test/hostwork/captures/preflight_s1/s1.pftrace` | 74,538 | `bcb64a8a3fd99ad4949d2a29a88a8a8b0da54942` | `d9fe5e40d6d3d99527084f4d3d71dc7165270718bd98fa44732bc8f265ed474b` |
| `v2_bord_test/hostwork/captures/s1/s1.pftrace` | 73,088 | `0605113b3adf3b96e3ff475e7d49fd367bff928d` | `a2982c38da07e4ed2db04397264b16e0b95d170f6905c5460e7ac8c73acec31d` |
| `v2_bord_test/hostwork/captures/s2/heap.pftrace` | 43,576 | `43a3e2bd3e192a7f09a32e3a5dae244674b2a17b` | `619d2df37576e6a9fc60f1eb92adee703763b600ca066389a516902d0848289b` |
| `v2_bord_test/hostwork/captures/s2_attempt1/heap.pftrace` | 35,351 | `544a390d6bf8855aed8d1857c9e0c3b23050c0e4` | `17b6b3cf3b013b5f87918ac563fcab060e1df7aa767db6a119f1f5f3d0be2ee6` |
| `v2_bord_test/hostwork/captures/s3_timeout/s3_timeout.pftrace` | 24,947 | `a27295aa81d5513472fa4a694f6c0f9bd29da334` | `11ade3eb969989e36c798ff4fc5ef3a4931c039aeb550271041b6618362f49c4` |
| `x5_heapprofd_traces/x5_heapprofd_A_no_tick.pftrace` | 21,346 | `e0c1c7f84b75e9dfea740b4585b9f8ba37d0e2ea` | `ec392840ae22bd8e0937b95e229000c1e5f30c488921e0041f2cbaf01a837dbb` |
| `x5_heapprofd_traces/x5_heapprofd_B_tick_200ms.pftrace` | 21,681 | `0f54dbbcaf101f1806c3d289c8b3fd2a0cbcd4ad` | `6bd51270c1c87e09b5971ebef54dfd468d67b6ec6ec980da0f2fc844b2fabc11` |

History (`git log --all -- '*.pftrace'`):

| Commit | What it added | Provenance |
|---|---|---|
| `3dcef36` | the 2 `x5_heapprofd_traces/` files | pre-existing, added before this test by the repository owner; **present in the frozen commit `0fa17e08...`** |
| `7e72856` | the 5 `v2_bord_test/` files | this test, added at delivery on explicit owner instruction |

No commit has removed or redacted any trace, so all 7 blobs are reachable from
`main` and from at least one commit history.

## 2. Authorization status

- **The 5 smoke-test traces:** published on the repository owner's explicit
  instruction in this session ("把…测试结果的文件和pftrace文件一起推到github
  仓库的v2_bord_test目录"). That instruction is the authorization record for
  pushing these 5 files to this repository.
- **The 2 pre-existing traces:** committed by the owner (`3dcef36`) before this
  test. Their publication is the owner's own earlier action; this session has no
  additional approval record for them, and it cannot verify whether a separate
  public-disclosure approval existed.
- Both groups are now publicly readable. Whether that is acceptable is an owner
  decision; if not, use §4/§5 below.

**What this session cannot do:** there is no GitHub admin credential here
(`gh` CLI absent, no `GITHUB_TOKEN`/`GH_TOKEN`), so repository visibility cannot
be changed and GitHub cached objects cannot be purged from this environment.
Those steps are listed for the owner.

## 3. Protect first (does not depend on history rewrite)

Order matters: restrict access **before** rewriting history, so that the rewrite
and its force-push do not happen while the data is still public.

1. **Make the repository private** (owner, GitHub web UI):
   `Settings → General → Danger Zone → Change visibility → Make private`.
   API equivalent with an admin token:
   ```
   curl -X PATCH -H "Authorization: Bearer $TOKEN" \
     -H "Accept: application/vnd.github+json" \
     https://api.github.com/repos/dg-xiaodong/test_perfetto \
     -d '{"visibility":"private"}'
   ```
   Verify anonymously: `curl -s -o /dev/null -w '%{http_code}' \
   https://api.github.com/repos/dg-xiaodong/test_perfetto` must no longer return
   `200` with `private=false` (expect `404` for anonymous access).
2. If the repository must stay public but the traces must not be, replace the
   raw traces with synthetic/minimal samples and keep the real ones private
   (this still requires history cleanup below).
3. Keep the private originals for review: the unredacted master copies remain in
   the test host record (`<TEST_RECORD>/hostwork/captures/`) and in
   `E:\x5_*.pftrace`; their SHA-256 values are in §1 and in `checksums.txt`.
   Do **not** delete these private copies as part of cleanup.

## 4. History cleanup — Option A: remove only this test's traces (keeps the frozen tag valid)

The 5 `v2_bord_test` traces were added in the single commit `7e72856`, which is
*after* the frozen commit `0fa17e08...`. Rewriting only that commit does not
change `0fa17e08...`, so the RC tag stays valid.

```sh
# backup first
git clone --mirror git@github.com:dg-xiaodong/test_perfetto.git test_perfetto.backup.git
cd test_perfetto
git switch main

# rewrites refs (main and any others) dropping this path; install if missing:
#   pip install git-filter-repo   (or use git filter-branch below)
git filter-repo --path 'v2_bord_test/hostwork/captures' --invert-paths --force

# Optionally also drop the traces from the current tree with a normal commit,
# but that alone does NOT remove history; filter-repo above is the actual purge.

git tag -l            # RC tag must still point to 0fa17e08...; verify:
git rev-parse perfetto-memory-debugging-v1.0.2-rc1^{}

git push --force --prune origin main
git push origin refs/tags/perfetto-memory-debugging-v1.0.2-rc1   # unchanged target
```

If `git-filter-repo` is not available, the equivalent index-filter (slower):

```sh
git filter-branch --force --index-filter \
  'git rm -r --cached --ignore-unmatch v2_bord_test/hostwork/captures' \
  --prune-empty --tag-name-filter cat -- --branches --tags
```

Notes:
- Rewriting `main` changes `7e72856` and all later commits; any external links to
  them break. The RC tag and frozen commit are unaffected.
- Do **not** run `filter-repo` twice; it drops the `origin` remote (re-add it).
- Because `7e72856` is already public, after the rewrite GitHub may still serve
  the old blobs by their SHA until GitHub runs GC / support purges caches (see §6).

## 5. History cleanup — Option B: remove *all* traces (breaks the current freeze)

Removing `x5_heapprofd_traces/` as well changes commit `3dcef36` and therefore
**changes the frozen commit `0fa17e08...`**. The current RC tag
`perfetto-memory-debugging-v1.0.2-rc1` (tag object `96dc8099...`, target
`0fa17e08...`) would no longer point at an existing commit, so this option
requires an explicit re-freeze and a new tag (e.g. `-rc2`) — it conflicts with the
freeze rule "do not move an existing tag" and must be approved as a separate
decision.

```sh
git filter-repo --path 'x5_heapprofd_traces' --path 'v2_bord_test/hostwork/captures' \
                --invert-paths --force
# then: re-create the frozen commit/tag from the rewritten tree, publish a NEW tag
#       (do not move the existing RC tag), and re-run the release preflight.
```

## 6. GitHub-side purge (required after either option)

History rewrite in your clone does not delete GitHub's stored objects or caches.

1. Force-push the rewritten refs (done above). Old commits become unreachable
   from branches but may remain retrievable by SHA.
2. Ask GitHub Support to remove the unreachable objects / cached views. Include:
   repository `dg-xiaodong/test_perfetto`, the 7 blob ids and 2 commit ids from
   §1, and request "purge unreachable/cached objects containing the listed
   .pftrace blobs".
3. Until support confirms, assume the files may still be retrievable by direct
   SHA URL (`https://api.github.com/repos/.../git/blobs/<blob>`).
4. Search-engine / third-party caches are outside GitHub's control; if the repo
   had been indexed, request removals separately.
5. `forks_count=0` today, but anyone who cloned while the repo was public keeps a
   copy; revocation cannot recall those.

## 7. Post-cleanup verification (run after the rewrite, before declaring done)

```sh
# 1) no trace paths remain in any reachable commit/tag
git rev-list --objects --all | grep -iE '\.pftrace$'      # expect no output
# 2) old blobs are not in the local object database of the rewritten clone
for b in bcb64a8a3fd99ad4949d2a29a88a8a8b0da54942 0605113b3adf3b96e3ff475e7d49fd367bff928d \
         43a3e2bd3e192a7f09a32e3a5dae244674b2a17b 544a390d6bf8855aed8d1857c9e0c3b23050c0e4 \
         a27295aa81d5513472fa4a694f6c0f9bd29da334 e0c1c7f84b75e9dfea740b4585b9f8ba37d0e2ea \
         0f54dbbcaf101f1806c3d289c8b3fd2a0cbcd4ad; do git cat-file -e "$b" 2>/dev/null && echo "STILL_LOCAL $b"; done
# 3) anonymous API: repository must not be public
curl -s -o /dev/null -w '%{http_code}\n' https://api.github.com/repos/dg-xiaodong/test_perfetto
# 4) after GitHub support purge: blob URLs should stop resolving (404)
curl -s -o /dev/null -w '%{http_code}\n' https://api.github.com/repos/dg-xiaodong/test_perfetto/git/blobs/a27295aa81d5513472fa4a694f6c0f9bd29da334
```

**Deleting `v2_bord_test/` in a new commit and stopping there is not a cleanup**:
the blobs stay in history and in GitHub's object store exactly as listed in §1.

## 8. What was actually performed in this wrap-up

- Inventory of all `.pftrace` files at `main`, in history, and in the frozen
  commit; blob ids and SHA-256 recorded (§1).
- Authorization evidence documented (§2); report corrected to stop claiming that
  traces were not uploaded.
- RC tag created and pushed at the frozen commit (no existing tag moved).
- **No** history rewrite, **no** force-push, **no** visibility change, **no**
  deletion of traces: this environment has no GitHub admin credential, and
  destructive history rewrite needs the owner's explicit decision.
- `python3 -m unittest discover -s tests` → 76/76 OK (candidate uses `unittest`,
  not `pytest`).
