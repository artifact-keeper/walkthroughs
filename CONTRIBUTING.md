# Contributing to Artifact Keeper Walkthroughs

Thanks for your interest in contributing! Here's how to get started.

## Getting Started

1. Fork the repository
2. Clone your fork: `git clone https://github.com/YOUR_USERNAME/walkthroughs.git`
3. Create a branch: `git checkout -b docs/your-walkthrough` (use `fix/` or `chore/` as appropriate)
4. Make your changes
5. Run the same check CI runs (see [What CI checks](#what-ci-checks))
6. Commit and push to your fork
7. Open a Pull Request against `main`, referencing an issue (`Closes #N`) when there is one

## What CI checks

Every PR must be green before merge. `.github/workflows/pages.yml` runs a strict MkDocs build:

```bash
uv run --no-project --with-requirements requirements-docs.txt mkdocs build --strict
```

Strict mode fails on broken internal links, pages missing from the nav, and other warnings.
Run it locally before pushing; do not use "push and see if CI passes" as a workflow.

## What to Contribute

- **New walkthroughs.** A real deployment built on Artifact Keeper, with its code in
  `<slug>/` and its pages in `docs/<slug>/`. See "Layout" and "Adding a walkthrough" in the
  [README](README.md).
- **Corrections.** A command that no longer works, a link that moved, a step that is unclear.
  Fix the code in `<slug>/` and the page in `docs/<slug>/` in the same PR.
- **Requests.** Open an issue describing the deployment you would like to see.

## Guidelines

- Keep PRs focused on a single walkthrough or a single change.
- Write in a plain, direct voice: give the decision, then the reason. Define a tool in a short
  parenthetical the first time it appears. Use "you" for instructions.
- Open every walkthrough's overview page and code README with the "An example, not a complete
  defense" warning: the setup is a lab example, does not cover every edge case or attack, and is
  not a hardened production configuration. Link it to the walkthrough's findings.
- Every page stands alone. Link to other pages instead of saying "as above".
- Every command in a page must match the code in `<slug>/`. Mark abridged code blocks as
  abridged and link to the full file.
- Never commit generated state, keys, secrets, VM disks or downloaded media; keep a
  `.gitignore` in each code directory.
- Images go in the walkthrough's own `images/` folder, with descriptive alt text.

## The e2e contract

Every walkthrough runs nightly against the latest Artifact Keeper release and `:dev`
([`e2e/`](e2e/README.md)). For the runner to do that, a walkthrough's `<slug>/` must:

1. **Have three make targets**, each runnable from a fresh clone with no prompts:
   - `make all`: the whole pipeline, from an empty registry; exit non-zero on failure.
   - `make gates`: every check, after `make all`; exit non-zero if any check fails.
   - `make clean`: delete everything the walkthrough created: containers, volumes, networks,
     generated secrets, tokens and outputs. After it, `make all` starts from nothing. Pulled
     images and slow-to-rebuild build caches may stay.
2. **Take the Artifact Keeper images from the environment.** `registry/up.sh` uses
   `AK_BACKEND_IMAGE` and `AK_WEB_IMAGE` (full references, e.g.
   `ghcr.io/artifact-keeper/artifact-keeper-backend:1.11.11@sha256:...`) when they are set, and
   the walkthrough's pinned defaults (`.env.example`, `compose/VERSIONS`) when they are not.
   The pins in the files stay the documented versions; the override is for one run only.
3. **Print one standard line per check** on `make gates`' standard output:

   ```
   PASS         G3   <check>
   FAIL         G3   <check>: <why>
   BLOCKED(F4)  G3   <check>: <why>
   ```

   The status is `PASS`, `FAIL` or `BLOCKED(<reason>)`; then the gate (`G` and a number); then
   the check, and for `FAIL` and `BLOCKED` a colon and the reason. Use `BLOCKED` for a check
   that cannot run here and says nothing about the walkthrough: an unlanded Artifact Keeper fix,
   an account or secret that is not configured (`BLOCKED(account)`, `BLOCKED(secret)`), missing
   hardware (`BLOCKED(kvm)`). Also append each verdict to `out/gates/results.tsv`
   (UTC time, status, gate, check, why; tab separated), which the runner prefers to the log.
4. **Take secrets from the environment only**, by name, and never print them. When one is
   missing, report the checks that need it as `BLOCKED`, not `FAIL`.
5. **Name everything it creates with its own prefix** (containers, volumes, networks), publish
   host ports on `127.0.0.1` only, pin network subnets, and register those names, ports and
   subnets in [`e2e/walkthroughs.toml`](e2e/walkthroughs.toml). The runner checks them before
   every run and reports `BLOCKED(conflict)` instead of touching a stack that is already there.

Long or hardware-bound steps (a VM install) belong in `make gates` behind a check that reports
`BLOCKED` when the host cannot run them.

## Reporting Security Issues

Please do **not** open a public issue for security vulnerabilities in Artifact Keeper. Use
GitHub's private vulnerability reporting on
[artifact-keeper/artifact-keeper](https://github.com/artifact-keeper/artifact-keeper) or email
the maintainers directly.

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
