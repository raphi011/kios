#!/usr/bin/env bash
# Print the latest Kobo bookmark for a Calibre book id. Defaults to 271
# (Pragmatic Thinking and Learning, the cross-device sync smoke-test book).
#
# Usage:
#   scripts/kobo-bookmark.sh                # default book (271)
#   scripts/kobo-bookmark.sh 245            # by id
#   scripts/kobo-bookmark.sh -t Pragmatic   # by title fragment
#   scripts/kobo-bookmark.sh -w             # watch (refresh every 3s)
#   scripts/kobo-bookmark.sh -n 5           # show last N bookmark writes
#
# Requires kubectl with context pointing at the cluster running CWA.

set -euo pipefail

WATCH=0
LIMIT=1
BOOK_ID=271
TITLE_FRAG=""

while getopts "wt:n:h" opt; do
  case "$opt" in
    w) WATCH=1 ;;
    t) TITLE_FRAG="$OPTARG" ;;
    n) LIMIT="$OPTARG" ;;
    h) sed -n '2,12p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) exit 1 ;;
  esac
done
shift $((OPTIND - 1))
[ "$#" -ge 1 ] && BOOK_ID="$1"

resolve_book_id() {
  if [ -n "$TITLE_FRAG" ]; then
    BOOK_ID=$(kubectl exec -n calibre-web deploy/calibre-web -- \
      sqlite3 /calibre-library/metadata.db \
      "SELECT id FROM books WHERE title LIKE '%${TITLE_FRAG}%' ORDER BY id DESC LIMIT 1;")
    if [ -z "$BOOK_ID" ]; then
      echo "No book matching '$TITLE_FRAG'" >&2
      exit 1
    fi
  fi
}

show() {
  resolve_book_id
  local title
  title=$(kubectl exec -n calibre-web deploy/calibre-web -- \
    sqlite3 /calibre-library/metadata.db \
    "SELECT title FROM books WHERE id = ${BOOK_ID};")
  echo "Book: ${title:-<unknown>} (id=${BOOK_ID})"
  echo
  kubectl exec -n calibre-web deploy/calibre-web -- \
    sqlite3 -column -header /config/app.db "
SELECT
  b.last_modified                   AS last_modified,
  b.location_source                 AS chapter,
  b.location_value                  AS span,
  b.progress_percent                AS within_pct,
  b.content_source_progress_percent AS whole_pct,
  COALESCE(b.device_id, '(null)')   AS device_id
FROM kobo_bookmark b
JOIN kobo_reading_state s ON b.kobo_reading_state_id = s.id
WHERE s.book_id = ${BOOK_ID}
ORDER BY b.last_modified DESC
LIMIT ${LIMIT};
"
}

if [ "$WATCH" -eq 1 ]; then
  while true; do
    clear
    show
    sleep 3
  done
else
  show
fi
