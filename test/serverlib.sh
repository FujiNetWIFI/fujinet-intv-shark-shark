# Shared relay-server launcher for the test scripts.  Source, don't execute:
#     . "$(dirname "$0")/serverlib.sh"
#
# SERVER=py (default) runs server/intv_relay_server.py, which stays the
# canonical reference implementation.  SERVER=c runs the C port in server/c/,
# which tools/server_diff.py holds to byte-for-byte equality with it.
#
# Callers background and redirect as before:
#     ( relay_server --port 9113 --auto-go "$PLAYERS" ) > "$LOG" 2>&1 &
#     SRV=$!
# The exec below replaces the subshell, so $! is still the real server PID and
# every existing kill/trap keeps working.

relay_server() {
    case "${SERVER:-py}" in
    py)
        exec python3 server/intv_relay_server.py "$@"
        ;;
    c)
        if [ ! -x server/c/intv-relay ]; then
            echo "SERVER=c: server/c/intv-relay is not built -- run" >&2
            echo "  make -C server/c" >&2
            exit 1
        fi
        # The Python in this repo is pinned at MAX_SEATS=2; the C binary is
        # game-agnostic, so the seat count has to be passed explicitly.
        exec server/c/intv-relay \
            --max-seats "${MAX_SEATS:-${PLAYERS:-2}}" "$@"
        ;;
    *)
        echo "SERVER must be 'py' or 'c' (got '$SERVER')" >&2
        exit 1
        ;;
    esac
}
