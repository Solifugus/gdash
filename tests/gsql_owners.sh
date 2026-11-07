# Sourced by the runners. G-SQL owners, and waiting for them to finish.
#
# A G-SQL database is served by an owner process the first client starts. It
# is not that client's child, and it outlives it: by its linger (the suite sets
# GDASH_GSQL_LINGER=0) and, after a large write, by the moment it takes to
# finish writing a sorted file (GDASH-20 S0-5). A scratch tree removed while
# an owner is still writing into it is not clean -- the owner recreates files
# in it, or the removal fails.
#
# So scratch-clean first WAITS, with a bound, until no owner holds a database
# under the scratch tree, and fails naming any that still do. It asks the
# store's own lock through gsql.wait_for_owner (tests/wait_owners.bas), which
# needs no process table and signals nothing: a process this run did not start
# is not this run's to stop (the discipline of e5b1a39). Until gbasic 0424a49
# this matched owners' argv in /proc.

export GDASH_GSQL_LINGER="${GDASH_GSQL_LINGER:-0}"
GSQL_OWNERS_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Wait up to $2 seconds (default 15) until no owner holds a database under $1.
wait_for_gsql_owners(){
    local dir="$1" limit="${2:-15}" gb="${GDASH_GBASIC:-${GBASIC:-$HOME/development/gbasic/gbasic}}"
    if ! "$gb" "$GSQL_OWNERS_HERE/wait_owners.bas" "$dir" "$limit"; then
        echo "SCRATCH NOT CLEAN: G-SQL owners still hold databases under $dir after ${limit}s" >&2
        return 1
    fi
    return 0
}
