/* Intellivision netplay matchmaking + relay server -- C implementation.
 *
 * A transliteration of ../../intv_relay_server.py (protocol v2), which stays
 * the canonical reference.  Function names and their order in this file match
 * the Python methods one-for-one so that a future protocol change can be
 * diffed mechanically rather than re-derived; tools/server_diff.py holds the
 * two implementations to byte-for-byte equality on the wire and in the log.
 *
 * Unlike the Python, this binary is GAME-AGNOSTIC: --max-seats picks the room
 * capacity (Soccer 2, Bowling 4).  ROSTER_SLOTS is NOT a capacity -- it is a
 * PROTOCOL constant.  The console's SES_FLEN table pins START at 38 bytes and
 * ROOM at 34, so the roster stays 4-padded no matter what --max-seats says.
 * Shrinking it silently misframes every client.
 *
 * Wire format, both directions:
 *     frame := len(1) type(1) payload(len-1 bytes)
 * `len` counts type+payload.  TCP provides ordering/integrity; frames are
 * validated structurally and a malformed stream drops the connection.
 *
 * Deliberate differences from the Python, all documented in README.md:
 *   - the partial-frame guard the v2 rewrite dropped is restored (see feed());
 *   - SIGTERM shuts down gracefully, so the Lobby gets its offline POST;
 *   - --auto-go is clamped to --max-seats instead of silently never firing.
 */
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/random.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#include "lobby.h"

/* ---- protocol constants ----------------------------------------------- */

enum {
    T_HELLO = 0x01, T_LIST = 0x02, T_LOBBY = 0x03, T_JOIN  = 0x04,
    T_START = 0x05, T_INPUT = 0x06, T_CRC   = 0x07, T_STATE = 0x08,
    T_RESYNC = 0x09, T_BYE  = 0x0A, T_PEER_LEFT = 0x0B, T_PING = 0x0C,
    T_PONG  = 0x0D, T_ROOM  = 0x0E, T_GO    = 0x0F
};

/* Two generations of this protocol are in service.
 *
 * v2 (PBA Bowling, NASL Soccer) is room-based: JOIN builds a room, the host
 * sends GO, INPUT/CRC are seat-tagged, START carries a 4-slot roster.
 * v1 (Baseball, Auto Racing, NFL Football, Armor Battle, Utopia, Frog Bog)
 * pairs two players directly: JOIN starts the match at once, there is no ROOM
 * or GO frame at all, INPUT/CRC are untagged, and START names one opponent.
 *
 * --proto selects one for the whole port.  It is deliberately NOT
 * auto-detected per connection: a relay serves one game per port, and a v1
 * console can never be paired with a v2 console, so guessing would only turn
 * a clean rejection into a corrupt match.  Reference implementations are
 * ../intv_relay_server.py (v2) and any sibling's server/bbnet_server.py (v1).
 */
#define PROTO_V1                1
#define PROTO_V2                2
#define DEFAULT_DELAY           3
/* Roster slots ON THE WIRE.  A PROTOCOL constant, not a capacity. */
#define ROSTER_SLOTS            4
#define MAX_SEATS_CAP           ROSTER_SLOTS

#define MAX_TX_BACKLOG    (64 * 1024)   /* bytes queued per client before drop */
#define TX_CAP            MAX_TX_BACKLOG
#define RX_CAP                  256     /* > 201, the largest legal frame      */
#define MAX_CLIENTS             64      /* global established-connection cap   */
#define MAX_ROOMS               (MAX_CLIENTS / 2)  /* a live room has >= 2     */
#define MAX_CONNECTIONS_PER_IP  8       /* generous: FujiNets share a NAT addr */
#define HELLO_TIMEOUT           60      /* seconds to identify before drop     */
#define STATS_INTERVAL          60      /* seconds between abuse summaries     */
#define CRC_TICKS               64      /* ticks of CRC history per room       */
#define CRC_SEATS               8       /* distinct wire seats per tick        */
#define FRAME_MAX               256     /* outbound scratch; largest real = 74 */
#define LOBBY_ENTRIES           8       /* INTV client frame buffer sizing     */

/* ---- types ------------------------------------------------------------- */

/* v1 only: a client's own tick -> crc log.  The comparator pops from the
 * PARTNER's log, so the two sides are per-client, not per-room the way v2
 * does it.  One spare slot because the Python inserts before evicting. */
typedef struct {
    int      in_use;
    uint16_t tick;
    uint16_t crc;
} crclog_t;

typedef struct {
    int      in_use;
    int      fd;                    /* -1 once dropped                     */
    uint32_t gen;                   /* bumped on free; other half of the tag */
    uint32_t ip;                    /* network order, for the per-IP cap    */
    char     addrstr[32];           /* ('127.0.0.1', 51234) -- Python repr  */
    uint8_t  rx[RX_CAP];
    uint16_t rx_len;
    uint8_t  tx[TX_CAP];
    uint32_t tx_len;
    char     name[9];               /* "" until HELLO                       */
    int      room;                  /* rooms[] index, -1 = none             */
    double   connected_at;
    int      dead;                  /* set by drop(); guards late events     */
    uint32_t armed;                 /* current epoll event mask              */
    crclog_t crclog[CRC_TICKS + 1]; /* v1 only                               */
    int      ncrclog;               /* v1 only                               */
    uint32_t crc_ok;                /* v1 only: matched pairs this match     */
} client_t;

typedef struct {
    int      in_use;
    uint8_t  seat;
    uint16_t crc;
} crcslot_t;

typedef struct {
    int       in_use;
    uint16_t  tick;
    int       nseats;
    crcslot_t s[CRC_SEATS];
} crcrow_t;

typedef struct {
    int      used;
    int      members[MAX_SEATS_CAP];   /* client indices, JOIN order = seats */
    int      nmembers;
    int      started;
    uint16_t seed;
    uint32_t crc_ok;                   /* fully-agreed CRC rounds this match */
    int      ncrc;
    /* One spare row: log_crc inserts BEFORE evicting, exactly as the Python
     * dict does, so the table can transiently hold CRC_TICKS + 1 rows. */
    crcrow_t crc[CRC_TICKS + 1];
} room_t;

typedef struct {
    char name[9];
    int  ci;
} nameent_t;

typedef struct {
    unsigned tx_backlog_drops;
    unsigned hello_timeouts;
    unsigned connection_limit_rejections;
    unsigned lobby_publish_failures;
} stats_t;

/* ---- globals ----------------------------------------------------------- */

static client_t  clients[MAX_CLIENTS];
static room_t    rooms[MAX_ROOMS];
static nameent_t by_name[MAX_CLIENTS];
static int       n_by_name;
static int       n_clients;

static int       ep = -1;
static int       sigpipe_fd[2] = { -1, -1 };
static volatile sig_atomic_t stop_requested;

static stats_t   stats;
static stats_t   last_stats;
static lobby_t  *lob;

static int    g_port      = 9109;
static int    g_delay     = DEFAULT_DELAY;
static int    g_auto_go;
static int    g_max_seats = 2;
static int    g_proto     = PROTO_V2;
static int    g_debug;
static int    g_fixed_seed;

#define TAG_LISTEN UINT64_C(0xFFFFFFFFFFFFFFFF)
#define TAG_SIG    UINT64_C(0xFFFFFFFFFFFFFFFE)

static void drop(int ci, const char *fmt, ...)
    __attribute__((format(printf, 2, 3)));
static void on_list(int ci);

/* ---- logging ----------------------------------------------------------- */

/* logging.basicConfig(format="%(asctime)s %(levelname)s %(message)s").  The
 * stream is stderr (Python's default when no stream= is given) and every
 * harness merges it with 2>&1.  stderr is line-buffered in main() so each
 * record is a single write(2), matching StreamHandler's write-then-flush --
 * the test scripts read the log while the server is still running. */
void relay_log(const char *level, const char *fmt, ...)
{
    struct timeval tv;
    struct tm tm;
    char ts[32];
    va_list ap;

    if (!g_debug && strcmp(level, "DEBUG") == 0)
        return;

    gettimeofday(&tv, NULL);
    localtime_r(&tv.tv_sec, &tm);
    strftime(ts, sizeof ts, "%Y-%m-%d %H:%M:%S", &tm);

    flockfile(stderr);
    fprintf(stderr, "%s,%03ld %s ", ts, (long)(tv.tv_usec / 1000), level);
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
    funlockfile(stderr);
}

#define LOG_I(...) relay_log("INFO", __VA_ARGS__)
#define LOG_W(...) relay_log("WARNING", __VA_ARGS__)
#define LOG_D(...) relay_log("DEBUG", __VA_ARGS__)

/* ---- small helpers ----------------------------------------------------- */

static double mono(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

/* frame(ftype, payload) -> writes into buf, returns total bytes. */
static size_t frame_build(uint8_t *buf, uint8_t ftype,
                          const uint8_t *payload, size_t plen)
{
    buf[0] = (uint8_t)(plen + 1);       /* len counts type+payload */
    buf[1] = ftype;
    if (plen)
        memcpy(buf + 2, payload, plen);
    return plen + 2;
}

static void pad_name(uint8_t *dst8, const char *name)
{
    size_t n = strlen(name);
    if (n > 8)
        n = 8;
    memset(dst8, 0, 8);
    memcpy(dst8, name, n);
}

/* Client.__repr__: <ALICE> before HELLO becomes <('127.0.0.1', 51234)>. */
static const char *crepr(int ci)
{
    static char buf[4][48];
    static int  turn;
    char *b = buf[turn = (turn + 1) & 3];
    snprintf(b, sizeof buf[0], "<%s>",
             clients[ci].name[0] ? clients[ci].name : clients[ci].addrstr);
    return b;
}

/* Room.__repr__: "[" + " ".join(m.name or "?") + "]" */
static const char *rrepr(int ri)
{
    static char buf[2][64];
    static int  turn;
    char *b = buf[turn = (turn + 1) & 1];
    size_t o = 0;
    b[o++] = '[';
    for (int i = 0; i < rooms[ri].nmembers; i++) {
        const char *nm = clients[rooms[ri].members[i]].name;
        o += (size_t)snprintf(b + o, sizeof buf[0] - o, "%s%s",
                              i ? " " : "", nm[0] ? nm : "?");
        if (o >= sizeof buf[0] - 2)
            break;
    }
    snprintf(b + o, sizeof buf[0] - o, "]");
    return b;
}

/* A simplified repr() for the one log line that quotes wire bytes.  Python
 * would render U+FFFD for a non-ASCII byte; we render \xNN.  Nothing greps
 * this line -- see README.md, "documented divergences". */
static const char *brepr(const uint8_t *s, size_t n)
{
    static char b[80];
    size_t o = 0;
    b[o++] = '\'';
    for (size_t i = 0; i < n && o < sizeof b - 6; i++) {
        if (s[i] >= 0x20 && s[i] < 0x7F && s[i] != '\'' && s[i] != '\\')
            b[o++] = (char)s[i];
        else
            o += (size_t)snprintf(b + o, sizeof b - o, "\\x%02x", s[i]);
    }
    b[o++] = '\'';
    b[o] = '\0';
    return b;
}

static uint64_t rng_state;

static uint16_t next_seed(void)
{
    uint16_t v;
    if (g_fixed_seed)
        return (uint16_t)g_fixed_seed;
    do {                                /* random.randrange(1, 0x10000) */
        rng_state += UINT64_C(0x9E3779B97F4A7C15);
        uint64_t z = rng_state;
        z = (z ^ (z >> 30)) * UINT64_C(0xBF58476D1CE4E5B9);
        z = (z ^ (z >> 27)) * UINT64_C(0x94D049BB133111EB);
        v = (uint16_t)((z ^ (z >> 31)) & 0xFFFF);
    } while (v == 0);
    return v;
}

static uint64_t tag_of(int ci)
{
    return ((uint64_t)clients[ci].gen << 32) | (uint32_t)ci;
}

/* ---- by_name: an insertion-ordered array, never a hash ------------------
 *
 * on_list() slices by_name.values()[:8], so Python's dict order IS the lobby
 * a console displays.  Three distinct semantics have to survive the port:
 *   by_name[new] = c        -> appended at the end
 *   by_name[existing] = c   -> KEEPS its original position
 *   del by_name[name]       -> removed, the rest keep their relative order
 * A hash map gets all three wrong in a way no console gate would attribute
 * to the server; tools/server_diff.py scenario S1 exists to catch it. */

static int name_find(const char *name)
{
    for (int i = 0; i < n_by_name; i++)
        if (strcmp(by_name[i].name, name) == 0)
            return i;
    return -1;
}

static void name_set(const char *name, int ci)
{
    int i = name_find(name);
    if (i >= 0) {
        by_name[i].ci = ci;             /* in place: position is preserved */
        return;
    }
    if (n_by_name >= MAX_CLIENTS)
        return;                         /* unreachable: names <= clients */
    snprintf(by_name[n_by_name].name, sizeof by_name[0].name, "%s", name);
    by_name[n_by_name].ci = ci;
    n_by_name++;
}

static void name_del_at(int i)
{
    memmove(&by_name[i], &by_name[i + 1],
            (size_t)(n_by_name - i - 1) * sizeof by_name[0]);
    n_by_name--;
}

/* ---- rooms ------------------------------------------------------------- */

static int room_alloc(int host_ci)
{
    for (int i = 0; i < MAX_ROOMS; i++) {
        if (!rooms[i].used) {
            memset(&rooms[i], 0, sizeof rooms[i]);
            rooms[i].used = 1;
            rooms[i].members[0] = host_ci;
            rooms[i].nmembers = 1;
            return i;
        }
    }
    return -1;
}

static int room_seat(int ri, int ci)
{
    for (int i = 0; i < rooms[ri].nmembers; i++)
        if (rooms[ri].members[i] == ci)
            return i;
    return -1;
}

/* 4 x name8, seat-ordered, unused slots all-NUL.  Always ROSTER_SLOTS wide. */
static void room_roster(int ri, uint8_t *out32)
{
    memset(out32, 0, 8 * ROSTER_SLOTS);
    for (int i = 0; i < rooms[ri].nmembers && i < ROSTER_SLOTS; i++)
        pad_name(out32 + i * 8, clients[rooms[ri].members[i]].name);
}

/* ---- plumbing ---------------------------------------------------------- */

static void lobby_update_count(void)
{
    if (lob)
        lobby_update(lob, n_by_name);
}

static void update_events(int ci)
{
    client_t *c = &clients[ci];
    uint32_t want = EPOLLIN | (c->tx_len ? (uint32_t)EPOLLOUT : 0u);
    struct epoll_event ev;

    if (c->dead || c->fd < 0 || want == c->armed)
        return;
    ev.events   = want;
    ev.data.u64 = tag_of(ci);
    if (epoll_ctl(ep, EPOLL_CTL_MOD, c->fd, &ev) == 0)
        c->armed = want;
}

static void flush(int ci)
{
    client_t *c = &clients[ci];

    while (c->tx_len) {
        ssize_t k = send(c->fd, c->tx, c->tx_len, MSG_NOSIGNAL);
        if (k < 0 && errno == EINTR)
            continue;                   /* PEP 475: Python retries too */
        if (k < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
            break;
        if (k < 0) {
            drop(ci, "send error");
            return;
        }
        if (k == 0) {
            drop(ci, "send returned 0");
            return;
        }
        memmove(c->tx, c->tx + k, c->tx_len - (size_t)k);   /* del tx[:n] */
        c->tx_len -= (uint32_t)k;
    }
    update_events(ci);
}

static void send_raw(int ci, const uint8_t *data, size_t n)
{
    client_t *c = &clients[ci];

    if (c->dead)
        return;
    /* The array bound IS the backlog cap, so this check is exactly "the
     * memcpy below would not fit". */
    if ((size_t)c->tx_len + n > MAX_TX_BACKLOG) {
        stats.tx_backlog_drops++;
        drop(ci, "transmit backlog exceeded");
        return;
    }
    memcpy(c->tx + c->tx_len, data, n);
    c->tx_len += (uint32_t)n;
    flush(ci);
}

static void send_frame(int ci, uint8_t ftype, const uint8_t *payload, size_t plen)
{
    uint8_t buf[FRAME_MAX];
    size_t n = frame_build(buf, ftype, payload, plen);
    send_raw(ci, buf, n);
}

static int client_alloc(int fd, const struct sockaddr_in *sa)
{
    char ipbuf[INET_ADDRSTRLEN];

    for (int i = 0; i < MAX_CLIENTS; i++) {
        client_t *c = &clients[i];
        if (c->in_use)
            continue;
        uint32_t gen = c->gen;          /* survives the wipe */
        memset(c, 0, sizeof *c);
        c->gen    = gen;
        c->in_use = 1;
        c->fd     = fd;
        c->room   = -1;
        c->ip     = sa->sin_addr.s_addr;
        c->connected_at = mono();
        inet_ntop(AF_INET, &sa->sin_addr, ipbuf, sizeof ipbuf);
        snprintf(c->addrstr, sizeof c->addrstr, "('%s', %u)",
                 ipbuf, (unsigned)ntohs(sa->sin_port));
        n_clients++;
        return i;
    }
    return -1;
}

static void client_free(int ci)
{
    clients[ci].in_use = 0;
    clients[ci].gen++;                  /* stale epoll tags stop matching */
    n_clients--;
}

static void accept_client(int srv)
{
    struct sockaddr_in sa;
    socklen_t sl = sizeof sa;
    char addrstr[32], ipbuf[INET_ADDRSTRLEN];
    int per_ip = 0, ci, one = 1, fd;

    fd = accept(srv, (struct sockaddr *)&sa, &sl);
    if (fd < 0)
        return;

    inet_ntop(AF_INET, &sa.sin_addr, ipbuf, sizeof ipbuf);
    snprintf(addrstr, sizeof addrstr, "('%s', %u)",
             ipbuf, (unsigned)ntohs(sa.sin_port));

    if (n_clients >= MAX_CLIENTS) {
        stats.connection_limit_rejections++;
        LOG_W("reject %s: server full (%d clients)", addrstr, n_clients);
        close(fd);
        return;
    }
    for (int i = 0; i < MAX_CLIENTS; i++)
        if (clients[i].in_use && clients[i].ip == sa.sin_addr.s_addr)
            per_ip++;
    if (per_ip >= MAX_CONNECTIONS_PER_IP) {
        stats.connection_limit_rejections++;
        LOG_W("reject %s: per-IP limit (%d)", addrstr, per_ip);
        close(fd);
        return;
    }

    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);

    ci = client_alloc(fd, &sa);
    if (ci < 0) {                       /* unreachable: n_clients checked */
        close(fd);
        return;
    }
    struct epoll_event ev = { .events = EPOLLIN, .data = { .u64 = tag_of(ci) } };
    if (epoll_ctl(ep, EPOLL_CTL_ADD, fd, &ev) != 0) {
        close(fd);
        client_free(ci);
        return;
    }
    clients[ci].armed = EPOLLIN;
    LOG_I("connect from %s", addrstr);
}

static void sweep(double now)
{
    for (int i = 0; i < MAX_CLIENTS; i++) {
        client_t *c = &clients[i];
        if (c->in_use && !c->dead && !c->name[0] &&
            now - c->connected_at > HELLO_TIMEOUT) {
            stats.hello_timeouts++;
            drop(i, "no hello within %ds", HELLO_TIMEOUT);
        }
    }
}

static void log_stats(void)
{
    int unidentified = 0;

    stats.lobby_publish_failures = lobby_failures(lob);
    if (memcmp(&stats, &last_stats, sizeof stats) == 0)
        return;
    last_stats = stats;
    for (int i = 0; i < MAX_CLIENTS; i++)
        if (clients[i].in_use && !clients[i].name[0])
            unidentified++;
    /* Python emits " ".join(f"{k}={v}" for sorted(counts.items())) -- the
     * tail is alphabetical by key. */
    LOG_I("stats: active_clients=%d unidentified_clients=%d "
          "connection_limit_rejections=%u hello_timeouts=%u "
          "lobby_publish_failures=%u tx_backlog_drops=%u",
          n_clients, unidentified, stats.connection_limit_rejections,
          stats.hello_timeouts, stats.lobby_publish_failures,
          stats.tx_backlog_drops);
}

static void room_broadcast(int ri)
{
    uint8_t payload[1 + 8 * ROSTER_SLOTS];
    int mm[MAX_SEATS_CAP], nm = rooms[ri].nmembers;

    payload[0] = (uint8_t)rooms[ri].nmembers;
    room_roster(ri, payload + 1);
    memcpy(mm, rooms[ri].members, sizeof mm);   /* snapshot: a send can drop */
    for (int i = 0; i < nm; i++)
        send_frame(mm[i], T_ROOM, payload, sizeof payload);
}

/* Return every member to solo; `notify` get ROOM count=0. */
static void dissolve(int ri, const int *notify, int nnotify)
{
    uint8_t payload[1 + 8 * ROSTER_SLOTS] = { 0 };

    for (int i = 0; i < rooms[ri].nmembers; i++)
        clients[rooms[ri].members[i]].room = -1;
    for (int i = 0; i < nnotify; i++)
        send_frame(notify[i], T_ROOM, payload, sizeof payload);
    rooms[ri].nmembers = 0;
    rooms[ri].used = 0;
}

static void drop(int ci, const char *fmt, ...)
{
    client_t *c = &clients[ci];
    char why[128];
    va_list ap;
    int ri, seat;

    if (c->dead)
        return;
    c->dead = 1;

    va_start(ap, fmt);
    vsnprintf(why, sizeof why, fmt, ap);
    va_end(ap);
    LOG_I("drop %s: %s", crepr(ci), why);

    if (c->fd >= 0) {
        epoll_ctl(ep, EPOLL_CTL_DEL, c->fd, NULL);
        close(c->fd);
        c->fd = -1;
    }

    /* Remove every alias, not just the current name: repeated HELLOs may
     * have left more than one entry pointing here. */
    int stale = 0;
    for (int i = n_by_name - 1; i >= 0; i--) {
        if (by_name[i].ci == ci) {
            name_del_at(i);
            stale++;
        }
    }
    if (stale)
        lobby_update_count();

    ri = c->room;
    if (ri < 0) {
        client_free(ci);
        return;
    }
    seat = room_seat(ri, ci);
    c->room = -1;
    if (seat >= 0) {
        memmove(&rooms[ri].members[seat], &rooms[ri].members[seat + 1],
                (size_t)(rooms[ri].nmembers - seat - 1) * sizeof(int));
        rooms[ri].nmembers--;
    }

    if (g_proto == PROTO_V1) {
        /* v1 has no rooms: the partner is simply unlinked and told the peer
         * left, with an EMPTY PEER_LEFT payload.  Note the Python reports the
         * PARTNER's crc_ok, and does no lobby_update() on this path. */
        int partner = rooms[ri].nmembers > 0 ? rooms[ri].members[0] : -1;

        rooms[ri].nmembers = 0;
        rooms[ri].used = 0;
        if (partner >= 0) {
            LOG_I("match ended: %u CRC pairs verified", clients[partner].crc_ok);
            clients[partner].room = -1;
            send_frame(partner, T_PEER_LEFT, NULL, 0);
            LOG_I("%s back to lobby (peer left)", crepr(partner));
        }
        client_free(ci);
        return;
    }

    if (rooms[ri].started) {
        /* Any drop ends the match for everyone (user decision): name the
         * leaver, dissolve, all survivors back to the lobby. */
        uint8_t pl[9];
        int survivors[MAX_SEATS_CAP], ns = rooms[ri].nmembers;

        LOG_I("match ended: %u CRC rounds verified; %s (seat %d) left",
              rooms[ri].crc_ok, crepr(ci), seat);
        pl[0] = (uint8_t)seat;
        pad_name(pl + 1, c->name);
        memcpy(survivors, rooms[ri].members, sizeof survivors);
        dissolve(ri, NULL, 0);
        for (int i = 0; i < ns; i++) {
            send_frame(survivors[i], T_PEER_LEFT, pl, sizeof pl);
            LOG_I("%s back to lobby (peer left)", crepr(survivors[i]));
        }
    } else if (seat == 0) {
        int notify[MAX_SEATS_CAP], nn = rooms[ri].nmembers;
        memcpy(notify, rooms[ri].members, sizeof notify);
        LOG_I("room %s dissolved (host left)", rrepr(ri));
        dissolve(ri, notify, nn);
    } else if (rooms[ri].nmembers < 2) {
        int notify[MAX_SEATS_CAP], nn = rooms[ri].nmembers;
        memcpy(notify, rooms[ri].members, sizeof notify);
        dissolve(ri, notify, nn);
    } else {
        room_broadcast(ri);
    }
    lobby_update_count();
    client_free(ci);
}

/* ---- protocol ---------------------------------------------------------- */

static void handle(int ci, uint8_t ftype, const uint8_t *payload, size_t plen);

/* Reassemble frames out of the byte stream.
 *
 * THE FIX: intv_relay_server.py:333-348 has no "is the whole frame here yet"
 * guard -- every pre-v2 sibling does (armor-battle's line 258), and the v2
 * room rewrite dropped it.  Without it a TCP segment boundary mid-frame hands
 * handle() a truncated payload, or raises IndexError when only the length
 * byte has arrived.  Most likely to bite on the 99-byte STATE chunks during
 * resync.  C has no exception net, so this must be right.
 *
 * Progress proof: `space == 0` requires rx_len == RX_CAP == 256; then
 * lenb <= 255 so need <= 256 <= rx_len and a frame is always drainable, so
 * the inner loop cannot have broken on the incompleteness path.  The overflow
 * drop below is therefore unreachable, and stands as a production assert. */
static void feed(int ci, const uint8_t *p, size_t n)
{
    client_t *c = &clients[ci];

    while (n) {
        size_t space = RX_CAP - c->rx_len;
        size_t take;

        if (space == 0) {
            drop(ci, "rx overflow");
            return;
        }
        take = n < space ? n : space;
        memcpy(c->rx + c->rx_len, p, take);
        c->rx_len += (uint16_t)take;
        p += take;
        n -= take;

        for (;;) {
            unsigned lenb, need;
            uint8_t body[201];

            if (c->rx_len == 0)
                break;
            lenb = c->rx[0];
            need = lenb + 1u;
            /* Length validity is checked BEFORE completeness, exactly as the
             * Python does: a bad length byte drops on its own. */
            if (need < 2 || lenb > 200) {
                drop(ci, "bad frame length %u", lenb);
                return;
            }
            if (c->rx_len < need)
                break;                  /* <<< the guard */
            memcpy(body, c->rx + 1, lenb);
            memmove(c->rx, c->rx + need, c->rx_len - need);
            c->rx_len -= (uint16_t)need;
            handle(ci, body[0], body + 1, lenb - 1);
            if (c->dead)
                return;                 /* relay side effects can drop us */
        }
    }
}

static void service(int ci)
{
    uint8_t buf[4096];
    ssize_t n;

    for (;;) {
        n = recv(clients[ci].fd, buf, sizeof buf, 0);
        if (n < 0 && errno == EINTR)
            continue;
        break;
    }
    if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
        return;
    if (n < 0) {
        drop(ci, "recv error");
        return;
    }
    if (n == 0) {
        drop(ci, "closed");
        return;
    }
    feed(ci, buf, (size_t)n);
}

/* Python: payload[1:].decode("ascii","replace").rstrip("\0 ").
 *
 * Bytes >= 0x80 each decode to exactly ONE U+FFFD character, so character
 * count always equals byte count, and any such character fails the A-Z0-9
 * charset test anyway.  Byte-wise stripping therefore yields an identical
 * accept/reject decision on every possible input; only the text inside the
 * rejection log line can differ. */
static size_t rstrip_nul_space(const uint8_t *s, size_t n)
{
    while (n && (s[n - 1] == 0 || s[n - 1] == ' '))
        n--;
    return n;
}

static void on_hello(int ci, const uint8_t *payload, size_t plen)
{
    client_t *c = &clients[ci];
    const uint8_t *raw;
    size_t n;
    char name[9];
    int old;

    if (plen < 3) {
        drop(ci, "short hello");
        return;
    }
    /* bbnet_server.py's on_hello ignores the version byte entirely -- it
     * reads payload[1:] as the name and never looks at payload[0].  Matching
     * that means --proto 1 accepts whatever the console sends, exactly as the
     * reference does.  Only v2 validates. */
    if (g_proto == PROTO_V2 && payload[0] != PROTO_V2) {
        /* A v1 console connects fine and is then hung up on, which from the
         * couch looks like "nobody ever joins".  Name the cause -- ONCE per
         * process, both so a console retrying in a loop cannot spam the log
         * and because this line is a deliberate addition to a log format that
         * is otherwise a contract (tools/server_diff.py filters it by name
         * and reports the count; see C_ONLY_LINES there). */
        static int warned_v1;
        if (payload[0] == PROTO_V1 && !warned_v1) {
            warned_v1 = 1;
            LOG_W("a protocol v1 console tried to connect and this port is "
                  "running --proto 2.  Baseball, Auto Racing, NFL Football, "
                  "Armor Battle, Utopia and Frog Bog need --proto 1.");
        }
        drop(ci, "protocol version %u, want %d", payload[0], PROTO_V2);
        return;
    }
    raw = payload + 1;
    n = rstrip_nul_space(raw, plen - 1);
    if (n < 2 || n > 8) {
        drop(ci, "bad name %s", brepr(raw, n));
        return;
    }
    for (size_t i = 0; i < n; i++) {
        if (!((raw[i] >= 'A' && raw[i] <= 'Z') ||
              (raw[i] >= '0' && raw[i] <= '9'))) {
            drop(ci, "bad name %s", brepr(raw, n));
            return;
        }
    }
    memcpy(name, raw, n);
    name[n] = '\0';

    old = name_find(name);
    if (old >= 0 && by_name[old].ci != ci) {
        drop(by_name[old].ci, "replaced by new connection");
        if (c->dead)
            return;                     /* cannot happen; cheap to be sure */
    }
    if (c->name[0] && strcmp(c->name, name) != 0) {
        /* Repeated HELLO with a new name: clean up the old alias.  Python
         * logs the repr BEFORE the rename, so this line shows the OLD name. */
        int i = name_find(c->name);
        if (i >= 0 && by_name[i].ci == ci)
            name_del_at(i);
        LOG_I("rename %s -> %s", crepr(ci), name);
    }
    snprintf(c->name, sizeof c->name, "%s", name);
    name_set(name, ci);
    LOG_I("hello %s", crepr(ci));
    lobby_update_count();
    on_list(ci);
}

/* v2 LOBBY status byte: low 3 bits = room member count (1 = solo idle),
 * bit7 = unjoinable (match started or room full).
 * v1 is simply 0 = idle, 1 = busy (bbnet_server.py's `0 if c.idle else 1`). */
static uint8_t status_byte(int ci)
{
    int ri = clients[ci].room, n, busy;

    if (g_proto == PROTO_V1)
        return (uint8_t)(ri < 0 ? 0 : 1);
    if (ri < 0)
        return 1;
    n = rooms[ri].nmembers;
    busy = (rooms[ri].started || n >= g_max_seats) ? 0x80 : 0;
    return (uint8_t)(busy | n);
}

static void on_list(int ci)
{
    uint8_t payload[1 + LOBBY_ENTRIES * 9];
    size_t o = 1;
    int count = 0;

    /* by_name order is the display order; capped at 8 for the INTV client's
     * frame buffer sizing. */
    for (int i = 0; i < n_by_name && count < LOBBY_ENTRIES; i++) {
        int oc = by_name[i].ci;
        if (oc == ci || !clients[oc].name[0])
            continue;
        pad_name(payload + o, clients[oc].name);
        payload[o + 8] = status_byte(oc);
        o += 9;
        count++;
    }
    payload[0] = (uint8_t)count;
    send_frame(ci, T_LOBBY, payload, o);
}

static void start_room(int ri);
static void start_pair(int host, int guest);

static void on_join(int ci, const uint8_t *payload, size_t plen)
{
    client_t *c = &clients[ci];
    char name[9];
    size_t n;
    int ti, target, ri;

    if (!c->name[0]) {
        drop(ci, "join before hello");
        return;
    }
    if (c->room >= 0)
        return;                 /* already matched; ignore crossed join */

    n = rstrip_nul_space(payload, plen);
    if (n > 8) {
        on_list(ci);            /* cannot match any stored name */
        return;
    }
    memcpy(name, payload, n);
    name[n] = '\0';
    ti = name_find(name);
    target = ti >= 0 ? by_name[ti].ci : -1;

    if (g_proto == PROTO_V1) {
        /* v1: `target is None or not target.idle or target is client` --
         * idle means named and unpartnered.  There is no room to redirect
         * into and no GO: the match starts here. */
        if (target < 0 || target == ci || !clients[target].name[0] ||
            clients[target].room >= 0) {
            on_list(ci);        /* refresh; target gone or busy */
            return;
        }
        start_pair(target, ci); /* the waiting player is host */
        return;
    }

    /* Joining ANY member of a forming room joins that room (the join
     * redirects to the room, not the individual) -- what the lobby's
     * occupancy display implies, and what keeps the rig's auto-join
     * consoles from ping-ponging on a guest's entry. */
    if (target < 0 || target == ci || !clients[target].name[0] ||
        (clients[target].room >= 0 &&
         (rooms[clients[target].room].started ||
          rooms[clients[target].room].nmembers >= g_max_seats))) {
        on_list(ci);            /* refresh; target gone or unjoinable */
        return;
    }

    ri = clients[target].room;
    if (ri < 0) {
        ri = room_alloc(target);
        if (ri < 0) {           /* unreachable: MAX_ROOMS == MAX_CLIENTS/2 */
            LOG_W("no room slots free; refusing join from %s", crepr(ci));
            on_list(ci);
            return;
        }
        clients[target].room = ri;
    }
    rooms[ri].members[rooms[ri].nmembers++] = ci;
    c->room = ri;
    /* Python logs the room repr AFTER the append: it includes the joiner. */
    LOG_I("join: %s -> room %s", crepr(ci), rrepr(ri));
    room_broadcast(ri);
    lobby_update_count();
    if (g_auto_go && rooms[ri].nmembers >= g_auto_go)
        start_room(ri);
}

static void on_go(int ci)
{
    int ri = clients[ci].room;

    if (ri < 0 || rooms[ri].started || room_seat(ri, ci) != 0)
        return;
    if (rooms[ri].nmembers < 2 || rooms[ri].nmembers > g_max_seats)
        return;
    start_room(ri);
}

static void start_room(int ri)
{
    uint8_t payload[1 + 4 + 8 * ROSTER_SLOTS];
    int mm[MAX_SEATS_CAP], nm = rooms[ri].nmembers;

    rooms[ri].started = 1;
    rooms[ri].seed    = next_seed();
    memset(rooms[ri].crc, 0, sizeof rooms[ri].crc);
    rooms[ri].ncrc    = 0;
    rooms[ri].crc_ok  = 0;

    payload[1] = (uint8_t)nm;
    payload[2] = (uint8_t)(rooms[ri].seed & 0xFF);
    payload[3] = (uint8_t)(rooms[ri].seed >> 8);
    payload[4] = (uint8_t)g_delay;
    room_roster(ri, payload + 5);

    memcpy(mm, rooms[ri].members, sizeof mm);
    for (int seat = 0; seat < nm; seat++) {
        payload[0] = (uint8_t)seat;
        send_frame(mm[seat], T_START, payload, sizeof payload);
    }
    /* Python logs AFTER the sends and re-evaluates the room repr and member
     * count there, so a send that dropped a member is reflected in the line. */
    LOG_I("match: room %s started, %d players (seed $%04X)",
          rrepr(ri), rooms[ri].nmembers, rooms[ri].seed);
    lobby_update_count();
}

/* v1 pairing.  bbnet_server.py's on_join does all of this inline: allocate
 * the seed, cross-link the pair, reset both CRC logs, send the host's START
 * then the guest's, and log afterwards.  The host is the player who was
 * already waiting (the JOIN target), which is also role 0 / left controller. */
static void start_pair(int host, int guest)
{
    uint8_t payload[1 + 3 + 8];
    uint16_t seed = next_seed();
    int ri = room_alloc(host);

    if (ri < 0) {               /* unreachable: MAX_ROOMS == MAX_CLIENTS/2 */
        LOG_W("no room slots free; refusing join from %s", crepr(guest));
        on_list(guest);
        return;
    }
    rooms[ri].members[rooms[ri].nmembers++] = guest;
    rooms[ri].started = 1;
    rooms[ri].seed = seed;
    clients[host].room = ri;
    clients[guest].room = ri;

    for (int i = 0; i < 2; i++) {
        int m = rooms[ri].members[i];
        memset(clients[m].crclog, 0, sizeof clients[m].crclog);
        clients[m].ncrclog = 0;
        clients[m].crc_ok = 0;
    }

    payload[1] = (uint8_t)(seed & 0xFF);
    payload[2] = (uint8_t)(seed >> 8);
    payload[3] = (uint8_t)g_delay;

    payload[0] = 0;                             /* host: role 0 */
    pad_name(payload + 4, clients[guest].name);
    send_frame(host, T_START, payload, sizeof payload);

    payload[0] = 1;                             /* guest: role 1 */
    pad_name(payload + 4, clients[host].name);
    send_frame(guest, T_START, payload, sizeof payload);

    /* No lobby_update() here: bbnet_server.py's on_join has none, and it
     * would be a no-op anyway (curplayers is len(by_name), which a pairing
     * does not change). */
    LOG_I("match: host %s vs guest %s (seed $%04X)",
          crepr(host), crepr(guest), seed);
}

/* v1 CRC comparator.  Per-client logs, and the match is found by POPPING the
 * partner's entry for this tick -- so whoever reports second does the
 * comparison.  Mismatch names both clients; the agreed path bumps BOTH
 * counters but tests the reporter's for the every-4th line. */
static void log_crc_v1(int ci, const uint8_t *payload)
{
    client_t *c = &clients[ci];
    int ri = c->room;
    int partner = -1;
    uint16_t tick = (uint16_t)(payload[0] | (payload[1] << 8));
    uint16_t crc  = (uint16_t)(payload[2] | (payload[3] << 8));
    crclog_t *slot = NULL;

    for (int i = 0; i < rooms[ri].nmembers; i++)
        if (rooms[ri].members[i] != ci)
            partner = rooms[ri].members[i];
    if (partner < 0)
        return;

    for (int i = 0; i <= CRC_TICKS; i++) {      /* partner.crc_log.pop(tick) */
        crclog_t *e = &clients[partner].crclog[i];
        if (e->in_use && e->tick == tick) {
            e->in_use = 0;
            clients[partner].ncrclog--;
            if (e->crc != crc) {
                LOG_W("CRC MISMATCH tick %u: %s=$%04X %s=$%04X",
                      tick, crepr(ci), crc, crepr(partner), e->crc);
            } else {
                c->crc_ok++;
                clients[partner].crc_ok++;
                if (c->crc_ok % 4 == 0)
                    LOG_I("crc ok through tick %u (%u pairs)", tick, c->crc_ok);
            }
            return;
        }
    }

    /* No partner entry: record our own.  client.crc_log[tick] = crc is an
     * insert-or-replace, and the >64 eviction runs after the insert. */
    for (int i = 0; i <= CRC_TICKS; i++)
        if (c->crclog[i].in_use && c->crclog[i].tick == tick) {
            slot = &c->crclog[i];
            break;
        }
    if (!slot) {
        for (int i = 0; i <= CRC_TICKS; i++)
            if (!c->crclog[i].in_use) {
                slot = &c->crclog[i];
                slot->in_use = 1;
                slot->tick = tick;
                c->ncrclog++;
                break;
            }
        if (!slot)
            return;                             /* unreachable */
    }
    slot->crc = crc;

    if (c->ncrclog > CRC_TICKS) {
        crclog_t *lowest = NULL;
        for (int i = 0; i <= CRC_TICKS; i++)
            if (c->crclog[i].in_use &&
                (!lowest || c->crclog[i].tick < lowest->tick))
                lowest = &c->crclog[i];
        if (lowest) {
            lowest->in_use = 0;
            c->ncrclog--;
        }
    }
}

static void log_crc(int ci, const uint8_t *payload)
{
    room_t *r = &rooms[clients[ci].room];
    uint8_t seat = payload[0];
    uint16_t tick = (uint16_t)(payload[1] | (payload[2] << 8));
    uint16_t crc  = (uint16_t)(payload[3] | (payload[4] << 8));
    crcrow_t *row = NULL;
    int nvals = 0, agree = 1;
    uint16_t first = 0;

    for (int i = 0; i <= CRC_TICKS; i++)
        if (r->crc[i].in_use && r->crc[i].tick == tick) {
            row = &r->crc[i];
            break;
        }
    if (!row) {
        for (int i = 0; i <= CRC_TICKS; i++)
            if (!r->crc[i].in_use) {
                row = &r->crc[i];
                memset(row, 0, sizeof *row);
                row->in_use = 1;
                row->tick = tick;
                r->ncrc++;
                break;
            }
        if (!row)
            return;                     /* unreachable: CRC_TICKS+1 rows */
    }

    /* Insert-or-replace.  `seat` is wire-supplied (0-255) and Python uses it
     * as a dict key, so a lying client can report a seat it does not own and
     * that shows up verbatim in the mismatch line.  CRC_SEATS pairs
     * reproduce that at 1.6 KiB/room instead of the 1.1 MB a 256-entry array
     * would cost; beyond 8 distinct seats in one tick the extra is dropped
     * (see README.md). */
    {
        crcslot_t *slot = NULL;
        for (int i = 0; i < CRC_SEATS; i++)
            if (row->s[i].in_use && row->s[i].seat == seat) {
                slot = &row->s[i];
                break;
            }
        if (!slot) {
            for (int i = 0; i < CRC_SEATS; i++)
                if (!row->s[i].in_use) {
                    slot = &row->s[i];
                    slot->in_use = 1;
                    slot->seat = seat;
                    row->nseats++;
                    break;
                }
        }
        if (!slot)
            return;
        slot->crc = crc;
    }

    /* Python evicts AFTER inserting, and the evicted entry can be the row we
     * just touched -- its local `entry` reference survives the pop, so the
     * completion check still runs.  Keeping `row` valid across the eviction
     * reproduces that exactly. */
    if (r->ncrc > CRC_TICKS) {
        crcrow_t *lowest = NULL;
        for (int i = 0; i <= CRC_TICKS; i++)
            if (r->crc[i].in_use && (!lowest || r->crc[i].tick < lowest->tick))
                lowest = &r->crc[i];
        if (lowest) {
            lowest->in_use = 0;
            r->ncrc--;
        }
    }

    if (row->nseats < r->nmembers)
        return;

    /* len(set(entry.values())) != 1 */
    for (int i = 0; i < CRC_SEATS; i++) {
        if (!row->s[i].in_use)
            continue;
        if (nvals++ == 0)
            first = row->s[i].crc;
        else if (row->s[i].crc != first)
            agree = 0;
    }

    if (row->in_use) {                      /* room.crc.pop(tick, None) */
        row->in_use = 0;
        r->ncrc--;
    }

    if (!agree) {
        char line[CRC_SEATS * 20], *o = line;
        size_t left = sizeof line;
        int emitted = 0;
        /* sorted(entry.items()) -- ascending by seat */
        for (int pass = 0; pass < 256 && emitted < row->nseats; pass++) {
            for (int i = 0; i < CRC_SEATS; i++) {
                if (!row->s[i].in_use || row->s[i].seat != pass)
                    continue;
                int w = snprintf(o, left, "%sseat%u=$%04X", emitted ? " " : "",
                                 row->s[i].seat, row->s[i].crc);
                if (w > 0 && (size_t)w < left) { o += w; left -= (size_t)w; }
                emitted++;
            }
        }
        LOG_W("CRC MISMATCH tick %u: %s", tick, line);
    } else {
        r->crc_ok++;
        if (r->crc_ok % 4 == 0)
            LOG_I("crc ok through tick %u (%u rounds)", tick, r->crc_ok);
    }
}

static void handle(int ci, uint8_t ftype, const uint8_t *payload, size_t plen)
{
    if (ftype == T_INPUT || ftype == T_CRC || ftype == T_STATE ||
        ftype == T_RESYNC) {
        int ri = clients[ci].room;
        uint8_t buf[FRAME_MAX];
        size_t n;
        int mm[MAX_SEATS_CAP], nm;

        if (ri < 0 || !rooms[ri].started)
            return;             /* match just ended; console hasn't noticed */
        /* v1 CRC frames are untagged and one byte shorter. */
        if (ftype == T_CRC && plen == (g_proto == PROTO_V1 ? 4u : 5u)) {
            if (g_proto == PROTO_V1)
                log_crc_v1(ci, payload);
            else
                log_crc(ci, payload);
        }
        n = frame_build(buf, ftype, payload, plen);
        nm = rooms[ri].nmembers;
        memcpy(mm, rooms[ri].members, sizeof mm);
        for (int i = 0; i < nm; i++)
            if (mm[i] != ci)
                send_raw(mm[i], buf, n);
        return;
    }
    switch (ftype) {
    case T_HELLO: on_hello(ci, payload, plen); break;
    case T_LIST:  on_list(ci);                 break;
    case T_JOIN:  on_join(ci, payload, plen);  break;
    case T_GO:
        /* GO does not exist in v1 -- bbnet_server.py's handle() has no case
         * for it, so it falls through to the unknown-type drop. */
        if (g_proto == PROTO_V1)
            drop(ci, "unknown type $%02X", ftype);
        else
            on_go(ci);
        break;
    case T_BYE:   drop(ci, "bye");             break;
    case T_PING:  send_frame(ci, T_PONG, NULL, 0); break;
    default:      drop(ci, "unknown type $%02X", ftype); break;
    }
}

/* ---- signals ----------------------------------------------------------- */

static void on_signal(int sig)
{
    (void)sig;
    stop_requested = 1;
    if (sigpipe_fd[1] >= 0) {
        ssize_t r = write(sigpipe_fd[1], "x", 1);
        (void)r;
    }
}

/* ---- main -------------------------------------------------------------- */

static void usage(FILE *f)
{
    fprintf(f,
"usage: intv-relay [options]\n"
"  --port N                 listen port (default 9109)\n"
"  --proto N                wire protocol: 2 = rooms/GO (Bowling, Soccer),\n"
"                           1 = direct pairing (Baseball, Auto Racing, NFL\n"
"                           Football, Armor Battle, Utopia, Frog Bog).\n"
"                           Default 2.\n"
"  --max-seats N            room capacity, 2..%d (default 2; v1 is always 2)\n"
"  --game-name S            game name for the FujiNet Lobby registration\n"
"  --server-name S          server name for the FujiNet Lobby registration\n"
"  --delay N                lockstep input delay in game ticks (default %d)\n"
"  --auto-go N              rig only: start a room once it has N members\n"
"  --debug                  verbose logging\n"
"  --lobby-enabled          register with the FujiNet Lobby\n"
"  --lobby-url URL          http:// only (default http://fujinet.online:8080)\n"
"  --lobby-serverurl URL    public endpoint clients should use\n"
"  --lobby-client-url URL   TNFS path of the client ROM for Lobby boot\n"
"  --lobby-appkey N         FujiNet-registry appkey id (the Lobby rejects 0)\n"
"  --lobby-region S         ISO region, lowercase (default us)\n"
"  --lobby-keepalive SECS   re-POST interval (default 300; test hook)\n"
"  --fixed-seed N           test only: pin the match seed to N (1..65535)\n",
        MAX_SEATS_CAP, DEFAULT_DELAY);
}

int main(int argc, char **argv)
{
    /* The Lobby's Go server binds :8080 and the relay reaches it directly,
     * so we POST plain HTTP -- no TLS to terminate, nothing to link.  The
     * Python's https://lobby.fujinet.online is the proxy in front of this. */
    const char *lobby_url    = "http://fujinet.online:8080";
    const char *lobby_srvurl = "TCP://fujinet.online:9109/";
    const char *lobby_cliurl =
        "TNFS://apps.irata.online/Intellivision/Games/NASLSoccer.rom";
    const char *lobby_region = "us";
    const char *game_name    = "NASL Soccer";
    const char *server_name  = "Soccer Netplay";
    int    lobby_appkey    = 17;
    int    lobby_enabled   = 0;
    double lobby_keepalive = 300.0;
    int    srv, one = 1;
    struct sockaddr_in sa;
    double last_sweep, last_stats_at;
    static char logbuf[8192];

    setvbuf(stderr, logbuf, _IOLBF, sizeof logbuf);
    tzset();

    for (int i = 1; i < argc; i++) {
        const char *a = argv[i], *eq = strchr(a, '=');
        char flag[32];
        const char *val = NULL;

        if (strncmp(a, "--", 2) != 0) {
            fprintf(stderr, "unexpected argument: %s\n", a);
            return 2;
        }
        if (eq) {
            size_t fl = (size_t)(eq - a);
            if (fl >= sizeof flag) { fprintf(stderr, "bad flag: %s\n", a); return 2; }
            memcpy(flag, a, fl);
            flag[fl] = '\0';
            val = eq + 1;
        } else {
            snprintf(flag, sizeof flag, "%s", a);
        }

#define NEEDVAL()                                                             \
        do {                                                                  \
            if (!val) {                                                       \
                if (i + 1 >= argc) {                                          \
                    fprintf(stderr, "%s requires a value\n", flag);           \
                    return 2;                                                 \
                }                                                             \
                val = argv[++i];                                              \
            }                                                                 \
        } while (0)

        if (!strcmp(flag, "--help") || !strcmp(flag, "-h")) {
            usage(stdout);
            return 0;
        } else if (!strcmp(flag, "--port")) {
            NEEDVAL(); g_port = atoi(val);
        } else if (!strcmp(flag, "--proto")) {
            NEEDVAL(); g_proto = atoi(val);
        } else if (!strcmp(flag, "--max-seats")) {
            NEEDVAL(); g_max_seats = atoi(val);
        } else if (!strcmp(flag, "--game-name")) {
            NEEDVAL(); game_name = val;
        } else if (!strcmp(flag, "--server-name")) {
            NEEDVAL(); server_name = val;
        } else if (!strcmp(flag, "--delay")) {
            NEEDVAL(); g_delay = atoi(val);
        } else if (!strcmp(flag, "--auto-go")) {
            NEEDVAL(); g_auto_go = atoi(val);
        } else if (!strcmp(flag, "--debug")) {
            g_debug = 1;
        } else if (!strcmp(flag, "--lobby-enabled")) {
            lobby_enabled = 1;
        } else if (!strcmp(flag, "--lobby-url")) {
            NEEDVAL(); lobby_url = val;
        } else if (!strcmp(flag, "--lobby-serverurl")) {
            NEEDVAL(); lobby_srvurl = val;
        } else if (!strcmp(flag, "--lobby-client-url")) {
            NEEDVAL(); lobby_cliurl = val;
        } else if (!strcmp(flag, "--lobby-appkey")) {
            NEEDVAL(); lobby_appkey = atoi(val);
        } else if (!strcmp(flag, "--lobby-region")) {
            NEEDVAL(); lobby_region = val;
        } else if (!strcmp(flag, "--lobby-keepalive")) {
            NEEDVAL(); lobby_keepalive = atof(val);
        } else if (!strcmp(flag, "--fixed-seed")) {
            NEEDVAL(); g_fixed_seed = atoi(val);
        } else {
            fprintf(stderr, "unknown flag: %s\n", flag);
            usage(stderr);
            return 2;
        }
#undef NEEDVAL
    }

    if (g_proto != PROTO_V1 && g_proto != PROTO_V2) {
        fprintf(stderr, "--proto must be 1 or 2\n");
        return 2;
    }
    if (g_proto == PROTO_V1 && g_max_seats != 2) {
        fprintf(stderr, "--proto 1 pairs exactly two players; "
                        "--max-seats %d is meaningless there\n", g_max_seats);
        return 2;
    }
    if (g_max_seats < 2 || g_max_seats > MAX_SEATS_CAP) {
        fprintf(stderr, "--max-seats must be 2..%d (the wire roster is %d "
                        "slots wide)\n", MAX_SEATS_CAP, ROSTER_SLOTS);
        return 2;
    }
    if (g_port < 1 || g_port > 65535) {
        fprintf(stderr, "--port must be 1..65535\n");
        return 2;
    }
    if (g_fixed_seed < 0 || g_fixed_seed > 0xFFFF) {
        fprintf(stderr, "--fixed-seed must be 1..65535\n");
        return 2;
    }
    if (g_proto == PROTO_V1 && g_auto_go) {
        LOG_W("--auto-go has no meaning with --proto 1: a v1 JOIN starts the "
              "match immediately.  Ignoring it.");
        g_auto_go = 0;
    }
    /* Python has no upper clamp here, so --auto-go 5 --max-seats 4 silently
     * never fires.  Clamp and say so. */
    if (g_auto_go > g_max_seats) {
        LOG_W("--auto-go %d exceeds --max-seats %d; clamping to %d",
              g_auto_go, g_max_seats, g_max_seats);
        g_auto_go = g_max_seats;
    }
    if (g_auto_go < 0)
        g_auto_go = 0;

    {   /* seed the PRNG */
        uint64_t s = 0;
        if (getrandom(&s, sizeof s, 0) != (ssize_t)sizeof s)
            s = (uint64_t)time(NULL) ^ ((uint64_t)getpid() << 32);
        rng_state = s;
    }

    for (int i = 0; i < MAX_CLIENTS; i++)
        clients[i].fd = -1;

    signal(SIGPIPE, SIG_IGN);   /* CPython does this at startup; MSG_NOSIGNAL
                                 * covers send(), this covers everything else */

    if (pipe(sigpipe_fd) != 0) {
        perror("pipe");
        return 1;
    }
    fcntl(sigpipe_fd[0], F_SETFL, O_NONBLOCK);
    fcntl(sigpipe_fd[1], F_SETFL, O_NONBLOCK);
    {
        struct sigaction act = { 0 };
        act.sa_handler = on_signal;
        sigemptyset(&act.sa_mask);
        act.sa_flags = SA_RESTART;
        sigaction(SIGINT, &act, NULL);
        sigaction(SIGTERM, &act, NULL);
    }

    srv = socket(AF_INET, SOCK_STREAM, 0);
    if (srv < 0) {
        perror("socket");
        return 1;
    }
    setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    memset(&sa, 0, sizeof sa);
    sa.sin_family = AF_INET;
    sa.sin_addr.s_addr = htonl(INADDR_ANY);
    sa.sin_port = htons((uint16_t)g_port);
    if (bind(srv, (struct sockaddr *)&sa, sizeof sa) != 0) {
        perror("bind");
        return 1;
    }
    if (listen(srv, 8) != 0) {
        perror("listen");
        return 1;
    }
    fcntl(srv, F_SETFL, fcntl(srv, F_GETFL, 0) | O_NONBLOCK);

    ep = epoll_create1(EPOLL_CLOEXEC);
    if (ep < 0) {
        perror("epoll_create1");
        return 1;
    }
    {
        struct epoll_event ev = { .events = EPOLLIN, .data = { .u64 = TAG_LISTEN } };
        epoll_ctl(ep, EPOLL_CTL_ADD, srv, &ev);
        ev.data.u64 = TAG_SIG;
        epoll_ctl(ep, EPOLL_CTL_ADD, sigpipe_fd[0], &ev);
    }

    LOG_I("listening on :%d", g_port);

    if (lobby_enabled) {
        lob = lobby_start(lobby_url, lobby_srvurl, lobby_cliurl, lobby_appkey,
                          lobby_region, game_name, server_name, g_max_seats,
                          lobby_keepalive);
        if (lob)
            lobby_update(lob, 0);
    }

    last_sweep = last_stats_at = mono();
    while (!stop_requested) {
        struct epoll_event evs[MAX_CLIENTS + 2];
        int n = epoll_wait(ep, evs, (int)(sizeof evs / sizeof evs[0]), 1000);
        double now;

        if (n < 0 && errno == EINTR)
            n = 0;
        if (n < 0) {
            perror("epoll_wait");
            break;
        }
        for (int i = 0; i < n; i++) {
            uint64_t t = evs[i].data.u64;
            uint32_t m = evs[i].events;
            int ci;

            if (t == TAG_LISTEN) {
                accept_client(srv);     /* one accept per readiness event,
                                         * level-triggered: exactly what
                                         * selectors does */
                continue;
            }
            if (t == TAG_SIG) {
                char sink[64];
                while (read(sigpipe_fd[0], sink, sizeof sink) > 0)
                    ;
                continue;
            }
            ci = (int)(t & 0xFFFFFFFFu);
            if (ci < 0 || ci >= MAX_CLIENTS)
                continue;
            /* A client can be dropped and its slot reused by an accept()
             * inside this very batch.  Python is immune by object identity;
             * the generation half of the tag is what makes C immune. */
            if (!clients[ci].in_use || clients[ci].gen != (uint32_t)(t >> 32))
                continue;
            if ((m & EPOLLOUT) && !clients[ci].dead)
                flush(ci);
            if ((m & (EPOLLIN | EPOLLHUP | EPOLLERR)) && !clients[ci].dead)
                service(ci);
        }
        now = mono();
        if (now - last_sweep >= 1.0) {
            last_sweep = now;
            sweep(now);
        }
        if (now - last_stats_at >= STATS_INTERVAL) {
            last_stats_at = now;
            log_stats();
        }
    }

    if (lob)
        lobby_shutdown(lob);
    close(srv);
    close(ep);
    return 0;
}
