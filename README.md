# Artifact Keeper Walkthroughs

Step-by-step walkthroughs for real deployments built on
[Artifact Keeper](https://github.com/artifact-keeper/artifact-keeper). Each walkthrough is
complete in this repository: the narrated guide and every script, Containerfile and config it
runs.

**Live site:** <https://artifact-keeper.github.io/walkthroughs/>

| Walkthrough | Guide | Code |
|---|---|---|
| Rocky Linux image mode on bare metal | [site](https://artifact-keeper.github.io/walkthroughs/rocky-linux-image-mode-bare-metal/) | [`rocky-linux-image-mode-bare-metal/`](rocky-linux-image-mode-bare-metal/) |

## Layout

One slug per walkthrough, used in two places:

```text
<slug>/                 the code: Makefile, scripts, Containerfiles, configs, per-directory READMEs
docs/<slug>/            the narrative: index.md (overview), one page per step, reference pages
docs/<slug>/images/     screenshots for that walkthrough only
docs/index.md           the site's home page, with a card per walkthrough
mkdocs.yml              site configuration and the nav
includes/               abbreviations appended to every page
```

The site is built with [MkDocs Material](https://squidfunk.github.io/mkdocs-material/) and
deployed to GitHub Pages by `.github/workflows/pages.yml` on every push to `main` that touches
the site. A walkthrough is served at
`https://artifact-keeper.github.io/walkthroughs/<slug>/`, and its code is browsable at
`https://github.com/artifact-keeper/walkthroughs/tree/main/<slug>`.

## Build the site locally

```bash
uv run --no-project --with-requirements requirements-docs.txt mkdocs build --strict
uv run --no-project --with-requirements requirements-docs.txt mkdocs serve
```

CI runs the same strict build; a broken link or a page missing from the nav fails it.

## Adding a walkthrough

1. **Pick a slug** that reads well in a URL, for example `rocky-linux-image-mode-bare-metal`.
2. **Put the code in `<slug>/`.** It must run from that directory on its own (a `Makefile` or
   a short command sequence in its `README.md`), with no paths outside it. Keep generated
   state, keys, secrets and downloaded media out of git with a `.gitignore` per directory.
3. **Put the narrative in `docs/<slug>/`.** `index.md` is the overview: what you will build,
   prerequisites, an architecture diagram, a page-by-page outline, time to complete, and a
   "Run it yourself" box. Then one page per step; make every page stand alone. Reference
   material (environment, architecture, troubleshooting, lab notes) can live alongside.
4. **Add a nav entry** in `mkdocs.yml`: a section named for the walkthrough whose first item
   is `docs/<slug>/index.md` (the `navigation.indexes` feature makes it the section's landing
   page), followed by the step pages. Add a card to `docs/index.md` and a row to the table
   above.
5. **Images go in `docs/<slug>/images/`**, referenced with relative paths, with meaningful
   alt text.
6. **Link within the repository.** Pages link to each other with relative paths; links to
   code use `https://github.com/artifact-keeper/walkthroughs/blob/main/<slug>/<file>`. Every
   command shown in a page must match the code in `<slug>/`.
7. **Open a pull request** using `.github/PULL_REQUEST_TEMPLATE.md`. See
   [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE), except vendored third-party code, which keeps its own license (for example
`rocky-linux-image-mode-bare-metal/base/upstream/rocky-bootc/`).
