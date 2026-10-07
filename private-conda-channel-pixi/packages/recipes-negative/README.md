# Negative-test packages

Not part of the application. The gates publish these to `conda-staging` to show
the release gate refusing them (G7):

- `acme-legacy`: vendors an old `urllib3` (1.24.1, the dist-info is enough for
  scanners) so the hosted scan reports known vulnerabilities.
- `acme-copyleft`: declares `GPL-3.0-only`, which the release gate's license rule denies.

Build with `RECIPES_DIR=packages/recipes-negative packages/build.sh`.
