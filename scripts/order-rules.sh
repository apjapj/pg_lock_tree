# vendored from pg-dev-infra harness/order-rules.sh; do not edit here.
# Edit the source there and re-vendor (pg-dev-infra/scripts/vendor-harness.sh).
# vendored-from: pg-dev-infra@5310af5
# vendored-sha256: 96b9630e8e96fc4e2fa4e7b4cdd419f73136f2ce553a170aa6dfd8058916cba1
# order-rules.sh: the two order rules, so their logic exists once. This file is the source; each
# repository vendors a copy into its scripts/ (see pg-dev-infra scripts/vendor-harness.sh) and
# sources it. No shebang: it is sourced, never run.
#
#   nondeterministic-order  a result may come back in any order
#   tie-break               ordered, but ties within that order are not settled
#
# Two places know the rule and both call here. check-examples.sh judges the PLAN (EXPLAIN, no rows)
# and only warns. scenarios/lib.sh judges val()'s OUTPUT, where the row count is known, and fails.
# A set-returning function is ordered by construction and trips neither rule.

# order_is_unique <stmt>: true when the statement's ORDER BY is on a unique key, or when it cannot be
# told. It answers false only when it can see the key is not unique: an ORDER BY it cannot parse (a
# join, an expression) returns true, so a caller warns and never fails on a guess.
order_is_unique() {
    local stmt=$1 tbl cols cl n
    tbl=$(printf '%s' "$stmt" | grep -oiE 'FROM +[A-Za-z0-9_."]+' | head -1 | sed -E 's/^FROM +//; s/"//g')
    cols=$(printf '%s' "$stmt" | grep -oiE 'ORDER BY +[^;]*' | head -1 \
           | sed -E 's/^ORDER BY +//I; s/ (ASC|DESC)//gI; s/ NULLS (FIRST|LAST)//gI; s/,/ /g; s/"//g; s/ +/ /g')
    [ -n "$tbl" ] && [ -n "$cols" ] || return 0
    cl=$(printf '%s' "$cols" | tr ' ' '\n' | grep -v '^$' | sed "s/.*/'&'/" | paste -sd, -)
    [ -n "$cl" ] || return 0
    n=$(psql -X -tA -c "
        SELECT count(*) FROM pg_index i
          JOIN pg_class c ON c.oid = i.indrelid
          JOIN pg_namespace ns ON ns.oid = c.relnamespace
         WHERE i.indisunique
           AND (ns.nspname || '.' || c.relname = '$tbl' OR c.relname = '$tbl')
           AND (SELECT array_agg(a.attname) FROM pg_attribute a
                 WHERE a.attrelid = c.oid AND a.attnum = ANY (i.indkey))
               <@ (SELECT array_agg(x) FROM unnest(ARRAY[$cl]) x)" 2>/dev/null)
    [ "${n:-0}" -ge 1 ]
}

# order_explain_verdict <stmt>: the rule the plan trips, or nothing. Single-row-by-construction plans
# (a plain Aggregate or Result, LIMIT 1) and set-returning functions trip nothing.
order_explain_verdict() {
    local stmt=$1 plan top
    plan=$(psql -X -tA -c "EXPLAIN (COSTS OFF) $stmt" 2>/dev/null) || return 0
    top=$(printf '%s\n' "$plan" | sed -n '1s/^ *//p')
    case "$top" in
        Sort*|"Incremental Sort"*)
            order_is_unique "$stmt" || echo tie-break ;;
        Aggregate*|Result*) : ;;
        Limit*)
            printf '%s' "$stmt" | grep -qiE 'LIMIT 1([^0-9]|$)' || echo nondeterministic-order ;;
        *)
            printf '%s' "$stmt" | grep -qE '(FROM|JOIN) +[A-Za-z0-9_.]+ *\(' || echo nondeterministic-order ;;
    esac
    return 0
}

# order_val_multirow <sql> <out>: nondeterministic-order when <out> has more than one row, <sql> has no
# ORDER BY, and the statement's source is not a set-returning function. The row count is known here.
order_val_multirow() {
    local sql=$1 out=$2
    [ "$(printf '%s\n' "$out" | wc -l)" -gt 1 ] || return 0
    printf '%s' "$sql" | grep -qiE 'ORDER BY' && return 0
    printf '%s' "$sql" | grep -qE '(FROM|JOIN) +[A-Za-z0-9_.]+ *\(' && return 0
    echo nondeterministic-order
}
