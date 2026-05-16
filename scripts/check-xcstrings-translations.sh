#!/usr/bin/env bash
#
# check-xcstrings-translations.sh — fail if any non-source locale is
# missing a translation in any .xcstrings catalog under REQUIRED_LOCALES,
# or if any translation is marked stale.
#
# Skips entries flagged shouldTranslate: false and entries whose
# extractionState is "stale" (orphaned in the catalog but not in code).

set -euo pipefail

REQUIRED_LOCALES=("de")
CATALOGS=(
  "Kios/Resources/Localizable.xcstrings"
  "KiosControls/Localizable.xcstrings"
)

fail=0

for catalog in "${CATALOGS[@]}"; do
  if [[ ! -f "$catalog" ]]; then
    echo "✗ missing catalog: $catalog"
    fail=1
    continue
  fi

  for locale in "${REQUIRED_LOCALES[@]}"; do
    missing=$(jq -r --arg loc "$locale" '
      .strings
      | to_entries
      | map(select(.value.shouldTranslate != false))
      | map(select((.value.extractionState // "extracted") != "stale"))
      | map(select(
            (.value.localizations[$loc] // null) == null
          or (.value.localizations[$loc].stringUnit.state // "new") == "new"
        ))
      | .[].key
    ' "$catalog")

    if [[ -n "$missing" ]]; then
      echo "✗ $catalog: missing or untranslated [$locale]:"
      while IFS= read -r key; do
        printf "    - %s\n" "$key"
      done <<< "$missing"
      fail=1
    fi

    stale=$(jq -r --arg loc "$locale" '
      .strings
      | to_entries
      | map(select(.value.localizations[$loc].stringUnit.state == "stale"))
      | .[].key
    ' "$catalog")

    if [[ -n "$stale" ]]; then
      echo "✗ $catalog: stale [$locale]:"
      while IFS= read -r key; do
        printf "    - %s\n" "$key"
      done <<< "$stale"
      fail=1
    fi
  done
done

if [[ $fail -eq 0 ]]; then
  echo "✓ all catalogs translated for: ${REQUIRED_LOCALES[*]}"
fi
exit $fail
