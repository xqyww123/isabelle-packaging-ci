# Operating the conda channel

For operating https://conda.qiyuan.me: its Cloudflare configuration that no file holds, the key `CLOUDFLARE_GOD_KEY`,
and deleting files from the channel. Only the owner does these, or an agent on the owner's explicit order. Releasing a
package: the SKILL conda-release (`.claude/skills/conda-release/SKILL.md`).

## The Transform Rule

R2, which serves the channel, has no index page for a directory, so a Cloudflare Transform Rule serves one. This is
the only record of that rule: zone `qiyuan.me`, phase `http_request_transform`, expression
`(http.host eq "conda.qiyuan.me" and ends_with(http.request.uri.path, "/"))`, path rewritten to
`concat(http.request.uri.path, "index.html")`. Without it, `https://conda.qiyuan.me/` answers 404.

Known, and left as it is by the owner: the front page links each subdirectory without a trailing slash
(`href="noarch"`), and such a URL answers 404, since the rule rewrites only paths that end in `/`
(`https://conda.qiyuan.me/noarch/` works).

## The address for our own pipelines

https://conda-ci.qiyuan.me is a second R2 custom domain of the bucket `conda`, with no Worker route and no Transform
Rule. Our own pipelines download from it so that the download counter does not count their downloads. Never give the
download counter's Worker a route that covers https://conda-ci.qiyuan.me (such as `*.qiyuan.me/*`).
`scripts/download-counter.py deploy` reads the routes of the zone `qiyuan.me` after wrangler has run, and exits with an
error naming any route that covers https://conda-ci.qiyuan.me: such a route is then already live, so tell the owner at
once. `deploy --dry-run` makes the same check without deploying.

To recreate https://conda-ci.qiyuan.me, do what was done on 2026-11-02, through the API
(`https://api.cloudflare.com/client/v4`), not the dashboard: its minimum TLS version must equal conda.qiyuan.me's, and
Cloudflare documents that setting only for the API. Mint the token as "`CLOUDFLARE_GOD_KEY`" below says, with Workers
R2 Storage Write (permission group `bf7481a1826f439697cb59a20b22293e`) on the account and nothing else;
`scripts/download-counter.py`'s `minted()` mints and revokes it, and its `Token.call` retries code 10000.
1. `GET /accounts/$CLOUDFLARE_ACCOUNT_ID/r2/buckets/conda/domains/custom` lists the bucket's custom domains. Take
   `zoneId` and `minTLS` from conda.qiyuan.me's entry. If conda-ci.qiyuan.me is listed already, skip step 2.
2. A `POST` on the same path attaches conda-ci.qiyuan.me, with this body:
   `{"domain": "conda-ci.qiyuan.me", "zoneId": "<that zoneId>", "enabled": true, "minTLS": "<that minTLS>"}`
3. Repeat the `GET` until `ownership` and `ssl` in conda-ci.qiyuan.me's `status` are both `active` (on 2026-11-02,
   within five minutes; if not after ten, tell the owner). Then `noarch/repodata.json` answers 200 on both hosts with
   the same `etag`.

https://conda-ci.qiyuan.me/ answers 404, because the Transform Rule covers only conda.qiyuan.me.
https://conda-ci.qiyuan.me/index.html is the channel's front page without the Downloads column, which only the
download counter's Worker adds: if that page ever shows the column, a route covers https://conda-ci.qiyuan.me; tell the
owner.

## `CLOUDFLARE_GOD_KEY`

`CLOUDFLARE_GOD_KEY` in `~/Current/MLML/secret.sh` is an account-owned API token, not a user token and not a Global
API Key: on `https://api.cloudflare.com/client/v4`, `GET /user/tokens/verify` answers "Invalid API Token" for it, and
`GET /accounts/$CLOUDFLARE_ACCOUNT_ID/tokens/verify` answers `active`. Use it only to mint a short-lived account token
with the permissions one task needs (`POST /accounts/$CLOUDFLARE_ACCOUNT_ID/tokens`, with `expires_on`), and to
revoke that token when the task is done (`DELETE /accounts/$CLOUDFLARE_ACCOUNT_ID/tokens/<token id>`);
`scripts/download-counter.py` does exactly this. A freshly minted token can be refused for a few seconds with
"Authentication error [code: 10000]", on any call, also after an earlier call with it succeeded: retry each call that
gets it (`scripts/download-counter.py` does). Run anything that needs a secret as
`(source ~/Current/MLML/secret.sh && …)`, and print no token.

## Deleting from the channel

A published file stays on the channel. A file is deleted for one of exactly two reasons: it is defective ("Defect
deletions"), or it is superseded and the owner selects it in a sweep. Both go through `scripts/sweep-old-versions.py`
("Sweeping superseded versions"), and every deleted file gets a row in `ROLLOUT_STATUS.md`, "Deletion log".

### Defect deletions

A file qualifies only when it makes the tool unusable and its error points away from the package that causes it;
misbehaving alone is not enough. For such a file:
1. Publish the fix first, as a higher version, or a higher build number of the same version, in the same subdir. Users
   then always have a working file, and the defective file becomes a sweep candidate.
2. Delete only the affected subdir's file: each subdir's build of a version is a file of its own.
3. Run the sweep ("Sweeping superseded versions") with a one-line plan: `plan`, then keep only that file's line, then
   `execute`, which runs every check it runs in any sweep. In the deletion-log row, "Why" names the defect.

A defective file that is not a sweep candidate: ask the owner.

## Sweeping superseded versions

`scripts/sweep-old-versions.py` lists the files that are candidates for deletion and deletes the ones the owner
selects, without downloading any package. A file is a candidate when the same subdir holds a strictly higher version
of the same package (in conda's version order), or the same version with a strictly higher build number. The build
number is the digits after the last `_` of the build string, or the whole build string when it is digits only
(`isabelle-2026-0.conda` is build 0). Versions that conda orders as equal (`1.0`, `1.0.0`) never supersede each other,
and the newest build of a package's newest version is never a candidate. `execute` refuses any file that is not one.

Prerequisites (the script checks the first, second and fourth when it starts):
1. rclone 1.74 or later (Ubuntu's 1.60 does not work with R2), on PATH or named by `$RCLONE`; conda-forge has it:
   `conda create -y -p /var/tmp/rclone --override-channels -c conda-forge 'rclone>=1.74'`, then
   `export RCLONE=/var/tmp/rclone/bin/rclone`.
2. A Python that can `import conda.models.version`, such as the one of conda's base environment.
3. A logged-in `gh`, for `execute`.
4. `CONDA_R2_ACCESS_KEY_ID` and `CONDA_R2_SECRET_ACCESS_KEY` in the environment, from `~/Current/MLML/secret.sh`.

Run each command from this repository's root, in a subshell, so that the credentials end with it:

```sh
(source ~/Current/MLML/secret.sh && "$(conda info --base)/bin/python" scripts/sweep-old-versions.py plan sweep-plan.txt)
(source ~/Current/MLML/secret.sh && "$(conda info --base)/bin/python" scripts/sweep-old-versions.py execute sweep-plan.txt)
```

`plan` writes nothing to the channel; it lists every candidate in `sweep-plan.txt` as
`<subdir>/<file>    # superseded by …`. Leave in that file only the lines of the files the owner selected (to keep a
file, delete its line or put `#` before it). `execute` checks the selection again, refuses one that would leave a
package on the channel with a dependency the channel no longer satisfies, shows the final list and asks you to type
`DELETE`. Without a terminal, pass `--confirm DELETE`, and only for a plan file the owner approved as it stands.

`execute` stops while a release or publish run is queued or running in any repository that publishes to the channel,
or while a `.conda` on R2 is newer than its subdir's `repodata.json` (a publish in flight, or one that failed half-way):
retry once that publish has finished and pushed its index (the SKILL conda-release, "10. After publishing", says how to
push the index of one that failed). In each subdir it pushes the edited metadata, then deletes the files; at the end
it checks from outside that every deleted file answers 404 and is gone from R2, and that the live `repodata.json` lists
exactly what it listed before, minus the plan. Last, it prints the deleted files as rows for `ROLLOUT_STATUS.md`,
"Deletion log"; add them there in a commit of its own.

If `execute` stopped half-way, start again from `plan`: a file already deleted is no longer a candidate, so the old
plan file is refused.

## Described next to their files

- The download counter, the Cloudflare Worker in front of https://conda.qiyuan.me: `worker/wrangler.toml`. Deploying the
  Worker, querying its database, and checking where workflows download from: `scripts/download-counter.py` (`check`
  needs no secret; `deploy` runs wrangler, measured with 4.151.1, as `$WRANGLER` or else `wrangler` on `PATH`, and
  wrangler needs Node.js 22 or later on `PATH`).
- The banner on the channel's front page: `conda/channel-banner.html`, applied by `scripts/banner-index.py`.
