# Fixed ThemeRunner corpus

The templates in `tests/` and the Liquid 5 helpers in `shopify5/` are copied from
Liquid 5.14.0, commit `4e39ae4cc3da`, `performance/tests` and `performance/shopify`.
The Liquid 4 helpers in `shopify4/` provide the corresponding older render API.
The database fixture and loader are shared by every engine. The upstream MIT
license is included in `LICENSE`.

The benchmark parses every page and its layout separately. It keeps this corpus
in the repository so that changing the installed Liquid version cannot change
its input. Outputs, input hashes and measurements are recorded outside this
folder by `cross_compare.rb`.

The separate `fleur_*` Ruby files generate original synthetic workloads inspired
by execution patterns in liquid-hub/fleur at commit
`f8edd032a5f74f02e359e6c7ad5b047c7bcc07e4`. They do not copy its SVG artwork or
provide application-specific platform implementations. Fixture provenance links identify the
source patterns. Select them with `THEME_CORPUS=fleur`; the default corpus above
is unchanged. See `../README.md` for cache modes and independent verification.
