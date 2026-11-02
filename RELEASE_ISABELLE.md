# Releasing `isabelle`

This adds to the SKILL conda-release (`.claude/skills/conda-release/SKILL.md`).

`isabelle` is the official Isabelle release with no patches (`PACKAGING_DESIGN.md`, "11. The unpatched build and
feature packages"). Patches ship as separate feature packages, released from the patch tool repository
`xqyww123/isabelle_patch_control` (its `RELEASE.md`).

Below, `<R>` is the Isabelle release you package, for example `Isabelle2026`, and `<N>` its build number (the SKILL,
"8. The build number"). `isabelle`'s conda version is `2026` for `Isabelle2026` and `2025.2` for `Isabelle2025-2`.

## Register the release (once per Isabelle release)

Skip this if `releases/<R>/` exists. Otherwise create, commit and push (the SKILL, "2. Rules"):

- `releases/<R>/SHA256SUMS`: exactly five lines, `<sha256>  <file>`, for `<R>_linux.tar.gz`,
  `<R>_linux_arm.tar.gz`, `<R>_macos.tar.gz`, `<R>_macos_arm.tar.gz` and `<R>.exe`, copied from
  `https://isabelle.in.tum.de/website-<R>/dist/`.
- `releases/<R>/ISABELLE_ID`: the first 12 hex digits of tag `<R>`'s changeset in
  `https://isabelle.in.tum.de/repos/isabelle/raw-tags`. Never copy it from a bundle: the CI checks the bundles
  against it.

Then check the new release without publishing, started and watched by the SKILL, "7. Start and watch a run":

```sh
gh workflow run ci.yml -R xqyww123/isabelle-packaging-ci -f release=<R> -f build_number=<N>
```

If `scripts/pack.sh` stops at an anchor ("upstream layout changed") or `scripts/check_pristine.py` reports a
difference, the new release's tree differs from what the packaging expects. Adapting the packaging is a fix, not a
release step: report it to the owner (the SKILL, "2. Rules").

## Rehearse the feature packages

Skip this if no feature package exists for `<R>`. `release.yml` has no `dry_run`: every dispatch publishes. The
rehearsal is `ci.yml` with the build number,

```sh
gh workflow run ci.yml -R xqyww123/isabelle-packaging-ci -f release=<R> -f build_number=<N>
```

and, once that run is green, the patch tool repository's `release-features.yml` with `isabelle_build=<N>`,
`isabelle_from=run:<id of that run>` and `publish=false` (its `RELEASE.md`, "The batch release workflow", explains
the other inputs). Go on only when the rehearsal is green. A run's packages are kept for 7 days; after that, dispatch
`ci.yml` again. With feature packages, precede every new dispatch of `release.yml` with a new green rehearsal.

## Release

Run, started and watched by the SKILL, "7. Start and watch a run":

```sh
gh workflow run release.yml -R xqyww123/isabelle-packaging-ci -f release=<R> -f build_number=<N>
```

The run has three parts: `build` (build.yml's jobs, listed as `build / …`), `publish`, and `smoke` (one job per
platform), which installs the published packages from the channel on clean machines. A second dispatch waits until
the first run has finished. A run's packages are kept for 7 days, so its failed jobs can be re-run only within them.
A failed job: the SKILL, "9. When a job fails", and the next section.

## A GUI check without a verdict

If only a GUI check of `build` failed with "a release needs a GUI verdict", the warning above that error says why
the CI's GUI judge (Claude, run by `scripts/gui_judge.sh`) gave no verdict:
- a used-up quota: re-run the failed jobs (the SKILL, "7. Start and watch a run") after it resets;
- "Not logged in", an expired token, or "no claude CLI and no CLAUDE_CODE_OAUTH_TOKEN": ask the owner to set or renew
  the `CLAUDE_CODE_OAUTH_TOKEN` secret (`claude setup-token`), then re-run the failed jobs;
- "could not tell whether only the failing lemma is flagged": re-run the failed jobs once; if it says so again,
  report it to the owner with the uploaded screenshot;
- any other reason: report it to the owner with the uploaded screenshot.

## After publishing

If feature packages exist for `<R>`, release them on the owner's order against build `<N>` (`isabelle_build=<N>`,
`isabelle_from=channel`), as the SKILL isabelle-patch-feature (in the patch tool repository), "3.4 Releasing a
feature", step 8, says.

Why the CI is built the way it is: `PACKAGING_DESIGN.md`.
