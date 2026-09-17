#!/usr/bin/env bash
# Regenerates the hledger conformance fixtures under
# Tests/SwiftLedgerTests/Conformance from the journals kept there.
#
# For every NAME.journal (files starting with "_" are parts other journals
# include and are skipped) this writes either:
#
#   NAME.print.json    what hledger reads: every transaction, every posting,
#                      every amount, with elided amounts filled in and costs
#                      inferred, projected down to the fields the test compares
#   NAME.balance.json  hledger's flat balance report, one row per account
#
# or, when hledger refuses the file:
#
#   NAME.error.txt     hledger's message, with this checkout's path removed
#
# Quantities are kept as hledger's exact decimal mantissa and place count, so
# the fixtures never round and the test compares values, never text.
#
# Requires hledger and jq. The tests themselves need neither: they read the
# committed fixtures. Run this after adding or editing a journal, and commit
# the result; hledger-version.txt records which hledger produced it.
set -euo pipefail

cd "$(dirname "$0")/../Tests/SwiftLedgerTests/Conformance"

PRINT_FILTER='[ .[] | {
  date: .tdate,
  date2: .tdate2,
  status: .tstatus,
  code: .tcode,
  description: .tdescription,
  postings: [ .tpostings[] | {
    account: .paccount,
    kind: .ptype,
    status: .pstatus,
    date: .pdate,
    amounts: [ .pamount[] | {
      commodity: .acommodity,
      mantissa: .aquantity.decimalMantissa,
      places: .aquantity.decimalPlaces,
      cost: (if .acost == null then null else {
        total: (.acost.tag == "TotalCost"),
        commodity: .acost.contents.acommodity,
        mantissa: .acost.contents.aquantity.decimalMantissa,
        places: .acost.contents.aquantity.decimalPlaces
      } end)
    } ],
    assertion: (if .pbalanceassertion == null then null else {
      commodity: .pbalanceassertion.baamount.acommodity,
      mantissa: .pbalanceassertion.baamount.aquantity.decimalMantissa,
      places: .pbalanceassertion.baamount.aquantity.decimalPlaces,
      total: .pbalanceassertion.batotal,
      inclusive: .pbalanceassertion.bainclusive
    } end)
  } ]
} ]'

BALANCE_FILTER='[ .[0][] | {
  account: .[0],
  amounts: [ .[3][] | {
    commodity: .acommodity,
    mantissa: .aquantity.decimalMantissa,
    places: .aquantity.decimalPlaces
  } ]
} ]'

hledger --version > hledger-version.txt

for journal in *.journal; do
  name="${journal%.journal}"
  case "$name" in _*) continue ;; esac
  rm -f "$name.print.json" "$name.balance.json" "$name.error.txt"

  if error=$(hledger -f "$journal" print -O json 2>&1 >"$name.print.raw"); then
    jq --indent 2 "$PRINT_FILTER" "$name.print.raw" > "$name.print.json"
    hledger -f "$journal" balance --flat -N -O json | jq --indent 2 "$BALANCE_FILTER" > "$name.balance.json"
    echo "ok     $name"
  else
    printf '%s\n' "$error" | sed "s|$PWD/||g" > "$name.error.txt"
    echo "error  $name"
  fi
  rm -f "$name.print.raw"
done
