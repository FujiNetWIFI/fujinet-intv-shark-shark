#!/bin/sh
# Production launch on the shared host (fujinet.online): relay on the
# game's assigned port, registered as a room on the FujiNet Lobby.
#
# Port assignments (one per game on the shared host):
#   9100 Baseball  9101 Auto Racing  9102 NFL Football (9103 probe)
#   9104 Armor Battle  9105 echo latency probe  9106 Utopia  9107 Frog Bog
#   9108 PBA Bowling (2-4 players)  9109 NASL Soccer  9110 Sea Battle
#   9111 PGA Golf (2-4 players)  9112 Boxing  9113 Shark! Shark! (1-2 players)
#
# The Lobby entry ("room") carries the game's name, appkey and the client
# ROM the INTV Lobby client boots; override any of it via the environment:
#   LOBBY_URL, LOBBY_APPKEY, LOBBY_SERVERURL, LOBBY_CLIENT_URL
# Everything defaults correctly for this game -- a bare run is a correct
# production start.  Never run this against a test/rig setup; local rigs
# must stay unregistered (make rig forces 127.0.0.1 and no --lobby-enabled).
#
# RELAY=py (default) runs the reference Python server; RELAY=c runs the C
# port in server/c/ (build it with `make -C server/c`).  The two are held to
# byte-for-byte equality by tools/server_diff.py.  Note that the C build talks
# to the Lobby's plain HTTP port -- it defaults to http://fujinet.online:8080
# rather than the TLS proxy the Python uses, so if you set LOBBY_URL, set it
# to an http:// URL.
set -e
cd "$(dirname "$0")/.."

relay() {
    case "${RELAY:-py}" in
    py)
        exec python3 server/intv_relay_server.py "$@"
        ;;
    c)
        [ -x server/c/intv-relay ] || {
            echo "RELAY=c: server/c/intv-relay is not built -- run" >&2
            echo "  make -C server/c" >&2
            exit 1
        }
        exec server/c/intv-relay --max-seats "${MAX_SEATS:-2}" "$@"
        ;;
    *)
        echo "RELAY must be 'py' or 'c' (got '$RELAY')" >&2
        exit 1
        ;;
    esac
}

relay \
    --port "${PORT:-9113}" \
    --lobby-enabled \
    ${LOBBY_URL:+--lobby-url "$LOBBY_URL"} \
    ${LOBBY_APPKEY:+--lobby-appkey "$LOBBY_APPKEY"} \
    ${LOBBY_SERVERURL:+--lobby-serverurl "$LOBBY_SERVERURL"} \
    ${LOBBY_CLIENT_URL:+--lobby-client-url "$LOBBY_CLIENT_URL"} \
    "$@"
