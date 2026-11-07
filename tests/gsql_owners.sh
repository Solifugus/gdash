# Sourced by the runners. G-SQL owners, and waiting for them to finish.
#
# A G-SQL database is served by an owner process the first client starts. It
# is not that client's child, and it outlives it: by its linger (the suite sets
# GDASH_GSQL_LINGER=0) and, after a large write, by the moment it takes to
# finish writing a sorted file (GDASH-20 S0-5). A scratch tree removed while
# an owner is still writing into it is not clean -- the owner recreates files
# in it, or the removal fails.
#
# So scratch-clean first WAITS, with a bound, for owners serving a path under
# the scratch tree, and fails naming them if any remain. It never signals one:
# the match is on the owner's argv, which names the database path gdash gave
# it, and a process this run did not start is not this run's to stop (the
# discipline of e5b1a39). Until the platform's own wait lands (ask A4), the
# process table is the only place this can be read.

export GDASH_GSQL_LINGER="${GDASH_GSQL_LINGER:-0}"

# PIDs of owners whose argv names a path under $1.
gsql_owners_under(){
    local dir="$1" pid
    for pid in $(pgrep -f -- '--gsql-owner' 2>/dev/null); do
        if tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qF -- "$dir/"; then
            echo "$pid"
        fi
    done
}

# Wait up to $2 seconds (default 15) for every owner under $1 to exit.
wait_for_gsql_owners(){
    local dir="$1" limit="${2:-15}" tries=0 left
    while :; do
        left="$(gsql_owners_under "$dir")"
        [[ -z "$left" ]] && return 0
        if (( tries >= limit * 10 )); then
            echo "SCRATCH NOT CLEAN: G-SQL owners still serving $dir after ${limit}s: $(echo $left)" >&2
            return 1
        fi
        sleep 0.1
        tries=$((tries + 1))
    done
}
