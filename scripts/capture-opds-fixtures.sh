#!/usr/bin/env bash
# Captures OPDS test fixtures from a live Calibre-Web-Automated server into
# iOSReaderTests/Fixtures/. Prompts for password interactively (not stored).
#
# Re-runnable: silently overwrites existing fixtures. Skips the synthesized
# fixtures (multi-format, mixed) if they already exist so manual edits survive.
#
# Usage:
#   ./scripts/capture-opds-fixtures.sh
#   ./scripts/capture-opds-fixtures.sh https://other.cwa.example otheruser

set -euo pipefail

SERVER="${1:-https://cwa.example.com}"
USER="${2:-raphi011}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
F="$REPO_ROOT/iOSReaderTests/Fixtures"

mkdir -p "$F"

read -s -p "Password for $USER on $SERVER: " PW
echo

fetch() {
    local path="$1"
    local out="$2"
    echo "  GET $SERVER$path  ->  $(basename "$out")"
    curl -sSfu "$USER:$PW" -H 'Accept: application/atom+xml' \
        "$SERVER$path" -o "$out"
}

echo "==> Fetching real fixtures from $SERVER"
fetch "/opds/"                         "$F/cwa-opds-root.xml"
fetch "/opds/books"                    "$F/cwa-opds-books-letter.xml"
fetch "/opds/books/letter/00"          "$F/cwa-opds-publications-p1.xml"
fetch "/opds/osd"                      "$F/cwa-opensearch-description.xml"

# /opds/ already advertises rel="search", so the with-search fixture is just
# a renamed copy. Kept as a separate file so the parser test asserting search
# descriptor extraction is explicit about which fixture exercises it.
cp "$F/cwa-opds-root.xml" "$F/cwa-opds-with-search.xml"

unset PW

# Synthesized fixtures: only write if missing, so manual tweaks survive re-runs.
if [[ ! -f "$F/cwa-opds-multi-format.xml" ]]; then
    echo "==> Synthesizing cwa-opds-multi-format.xml"
    cat > "$F/cwa-opds-multi-format.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom"
      xmlns:opds="http://opds-spec.org/2010/catalog">
  <id>urn:uuid:multi-format-test</id>
  <title>Multi-format test</title>
  <updated>2026-05-11T00:00:00Z</updated>
  <link rel="self" href="https://example/opds/multiformat"
        type="application/atom+xml;profile=opds-catalog"/>
  <entry>
    <id>urn:cwa:book:42</id>
    <title>Multi-Format Book</title>
    <author><name>Test Author</name></author>
    <updated>2026-05-11T00:00:00Z</updated>
    <link rel="http://opds-spec.org/image/thumbnail"
          href="/opds/thumb_240_240/42" type="image/jpeg"/>
    <link rel="http://opds-spec.org/image"
          href="/opds/cover/42" type="image/jpeg"/>
    <link rel="http://opds-spec.org/acquisition"
          href="/opds/download/42/epub" type="application/epub+zip"/>
    <link rel="http://opds-spec.org/acquisition"
          href="/opds/download/42/pdf"  type="application/pdf"/>
    <link rel="http://opds-spec.org/acquisition"
          href="/opds/download/42/cbz"  type="application/x-cbz"/>
  </entry>
</feed>
XML
fi

if [[ ! -f "$F/cwa-opds-publications-p2.xml" ]]; then
    echo "==> Synthesizing cwa-opds-publications-p2.xml (terminal page)"
    cat > "$F/cwa-opds-publications-p2.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom"
      xmlns:dc="http://purl.org/dc/terms/"
      xmlns:dcterms="http://purl.org/dc/terms/">
  <id>urn:uuid:terminal-page-test</id>
  <title>Calibre-Web Automated</title>
  <updated>2026-05-11T00:00:00+00:00</updated>
  <link rel="self" href="/opds/books/letter/00?offset=10000"
        type="application/atom+xml;profile=opds-catalog;type=feed;kind=acquisition"/>
  <link rel="start" href="/opds"
        type="application/atom+xml;profile=opds-catalog;type=feed;kind=navigation"/>
  <link rel="up" href="/opds/books/letter/00"
        type="application/atom+xml;profile=opds-catalog;type=feed;kind=navigation"/>
  <entry>
    <title>Terminal Entry One</title>
    <id>urn:cwa:book:terminal-1</id>
    <author><name>Last Author</name></author>
    <updated>2026-05-11T00:00:00+00:00</updated>
    <link rel="http://opds-spec.org/image/thumbnail"
          href="/opds/thumb_240_240/9991" type="image/jpeg"/>
    <link rel="http://opds-spec.org/image"
          href="/opds/cover/9991" type="image/jpeg"/>
    <link rel="http://opds-spec.org/acquisition"
          href="/opds/download/9991/epub" type="application/epub+zip"/>
  </entry>
  <entry>
    <title>Terminal Entry Two</title>
    <id>urn:cwa:book:terminal-2</id>
    <author><name>Final Author</name></author>
    <updated>2026-05-11T00:00:00+00:00</updated>
    <link rel="http://opds-spec.org/acquisition"
          href="/opds/download/9992/epub" type="application/epub+zip"/>
  </entry>
</feed>
XML
fi

if [[ ! -f "$F/cwa-opds-mixed.xml" ]]; then
    echo "==> Synthesizing cwa-opds-mixed.xml"
    cat > "$F/cwa-opds-mixed.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <id>urn:uuid:mixed-test</id>
  <title>Mixed nav + publication</title>
  <updated>2026-05-11T00:00:00Z</updated>
  <link rel="self" href="https://example/opds/mixed"
        type="application/atom+xml;profile=opds-catalog"/>
  <entry>
    <id>urn:nav:sub-a</id>
    <title>Sub-catalog A</title>
    <link rel="subsection" href="/opds/sub-a"
          type="application/atom+xml;profile=opds-catalog"/>
  </entry>
  <entry>
    <id>urn:cwa:book:7</id>
    <title>Inline Book</title>
    <author><name>A Person</name></author>
    <updated>2026-05-11T00:00:00Z</updated>
    <link rel="http://opds-spec.org/acquisition"
          href="/dl/inline.epub" type="application/epub+zip"/>
  </entry>
</feed>
XML
fi

# Drop the legacy synthetic fixture if it still lives in the repo.
if [[ -f "$F/calibre-web-opds.xml" ]]; then
    echo "==> Removing legacy fixture calibre-web-opds.xml"
    rm "$F/calibre-web-opds.xml"
fi

echo
echo "==> Sanity checks"
echo "rel=next count in publications-p1 (expect >= 1):"
grep -c 'rel="next"' "$F/cwa-opds-publications-p1.xml" || true
echo "rel=next count in publications-p2 (expect 0):"
grep -c 'rel="next"' "$F/cwa-opds-publications-p2.xml" || true
echo "rel=search count in root (expect >= 1):"
grep -c 'rel="search"' "$F/cwa-opds-root.xml" || true
echo "subsection count in books-letter (expect >= 26):"
grep -c 'rel="subsection"' "$F/cwa-opds-books-letter.xml" || true

echo
echo "==> Final fixture set"
ls -1 "$F"/*.xml | sort
echo
echo "Bytes:"
wc -c "$F"/*.xml
