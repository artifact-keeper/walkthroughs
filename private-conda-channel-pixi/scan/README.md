# scan

`scan.sh`: Syft (`+conda-meta-cataloger`) and Grype on the image and on the installed
environment; the registry's environment SBOM from `pixi.lock`
(`POST /api/v1/sbom/environment?filename=pixi.lock`), the lockfile registered as an environment
(`POST /api/v1/repositories/conda-internal/environments?filename=pixi.lock&name=acme-analytics`),
and PURL reverse lookups (`GET /api/v1/environments/lookup?purl=...`). Outputs in `../out/scan/`.
