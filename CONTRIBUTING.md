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
- Every page stands alone. Link to other pages instead of saying "as above".
- Every command in a page must match the code in `<slug>/`. Mark abridged code blocks as
  abridged and link to the full file.
- Never commit generated state, keys, secrets, VM disks or downloaded media; keep a
  `.gitignore` in each code directory.
- Images go in the walkthrough's own `images/` folder, with descriptive alt text.

## Reporting Security Issues

Please do **not** open a public issue for security vulnerabilities in Artifact Keeper. Use
GitHub's private vulnerability reporting on
[artifact-keeper/artifact-keeper](https://github.com/artifact-keeper/artifact-keeper) or email
the maintainers directly.

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
