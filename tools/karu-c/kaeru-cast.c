/*
 * kaeru-cast: send links and transport commands to the Kikru cast server.
 *
 * The Kikru cast server (started by `:Kikru cast server`, default port 8722) takes
 * HTTP requests on 127.0.0.1. This client speaks plain HTTP/1.1 over POSIX sockets,
 * so it has no dependencies beyond a C compiler (gcc, clang, Termux clang).
 *
 *   kaeru-cast [-H host] [-p port] [-t token] cast <url> [--mode play|queue|next]
 *   kaeru-cast [-H host] [-p port] [-t token] status
 *   kaeru-cast [-H host] [-p port] [-t token] play|pause|toggle|next|prev|stop
 *   kaeru-cast [-H host] [-p port] [-t token] volume <0-130>
 *
 * Environment: KAERU_CAST_HOST, KAERU_CAST_PORT, KAERU_CAST_TOKEN.
 * Exit status: 0 on HTTP 2xx, 1 on other HTTP status, 2 on usage errors, 3 when
 * the server cannot be reached.
 */
#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <netdb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/types.h>
#include <unistd.h>

#define DEFAULT_HOST "127.0.0.1"
#define DEFAULT_PORT "8722"
#define MAX_RESPONSE (1024 * 1024)
#define MAX_TARGET 8192
#define RECV_TIMEOUT_SEC 15

static const char *usage =
    "usage: kaeru-cast [-H host] [-p port] [-t token] <command> [args]\n"
    "  cast <url> [--mode play|queue|next]   send a link (YouTube, direct audio, ...)\n"
    "  status                                 show player and cast status (JSON)\n"
    "  play | pause | toggle | next | prev | stop\n"
    "  volume <0-130>\n";

/* Append `c` to a growable buffer. Returns 0 on success. */
static int buf_append(char **buf, size_t *len, size_t *cap, const char *data, size_t n) {
    if (*len + n + 1 > *cap) {
        size_t want = *cap ? *cap : 256;
        while (want < *len + n + 1) {
            want *= 2;
        }
        char *grown = realloc(*buf, want);
        if (!grown) {
            return -1;
        }
        *buf = grown;
        *cap = want;
    }
    memcpy(*buf + *len, data, n);
    *len += n;
    (*buf)[*len] = '\0';
    return 0;
}

/* Percent-encode everything except unreserved characters (RFC 3986). Caller frees. */
static char *url_encode(const char *in) {
    static const char hex[] = "0123456789ABCDEF";
    size_t n = strlen(in);
    char *out = malloc(n * 3 + 1);
    if (!out) {
        return NULL;
    }
    size_t j = 0;
    for (size_t i = 0; i < n; i++) {
        unsigned char c = (unsigned char)in[i];
        if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
            c == '-' || c == '_' || c == '.' || c == '~') {
            out[j++] = (char)c;
        } else {
            out[j++] = '%';
            out[j++] = hex[c >> 4];
            out[j++] = hex[c & 15];
        }
    }
    out[j] = '\0';
    return out;
}

/* Connect to host:port. Returns a socket or -1. */
static int connect_to(const char *host, const char *port) {
    struct addrinfo hints, *res = NULL, *ai;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    int rc = getaddrinfo(host, port, &hints, &res);
    if (rc != 0) {
        fprintf(stderr, "kaeru-cast: cannot resolve %s: %s\n", host, gai_strerror(rc));
        return -1;
    }
    int fd = -1;
    for (ai = res; ai; ai = ai->ai_next) {
        fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0) {
            continue;
        }
        if (connect(fd, ai->ai_addr, ai->ai_addrlen) == 0) {
            break;
        }
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);
    if (fd >= 0) {
        struct timeval wait = {RECV_TIMEOUT_SEC, 0};
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, sizeof wait);
    }
    return fd;
}

/* Send one GET request and read the whole reply. Returns HTTP status or -1. */
static int http_get(const char *host, const char *port, const char *target,
                    char **body, size_t *body_len) {
    int fd = connect_to(host, port);
    if (fd < 0) {
        fprintf(stderr, "kaeru-cast: no Kikru cast server at %s:%s (start it with :Kikru cast server)\n", host, port);
        return -1;
    }
    char request[4096];
    int n = snprintf(request, sizeof request,
                     "GET %s HTTP/1.1\r\nHost: %s:%s\r\nConnection: close\r\nUser-Agent: kaeru-cast/1\r\n\r\n",
                     target, host, port);
    if (n <= 0 || (size_t)n >= sizeof request) {
        close(fd);
        fprintf(stderr, "kaeru-cast: request too long\n");
        return -1;
    }
    size_t sent = 0;
    while (sent < (size_t)n) {
        ssize_t w = send(fd, request + sent, (size_t)n - sent, 0);
        if (w < 0) {
            if (errno == EINTR) {
                continue;
            }
            close(fd);
            fprintf(stderr, "kaeru-cast: send failed: %s\n", strerror(errno));
            return -1;
        }
        sent += (size_t)w;
    }
    char *raw = NULL;
    size_t len = 0, cap = 0;
    char chunk[4096];
    for (;;) {
        ssize_t r = recv(fd, chunk, sizeof chunk, 0);
        if (r < 0 && errno == EINTR) {
            continue;
        }
        if (r == 0) {
            break;
        }
        if (r < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                free(raw);
                close(fd);
                fprintf(stderr, "kaeru-cast: no reply within %d seconds\n", RECV_TIMEOUT_SEC);
                return -1;
            }
            break;
        }
        if (len + (size_t)r > MAX_RESPONSE) {
            free(raw);
            close(fd);
            fprintf(stderr, "kaeru-cast: response too large\n");
            return -1;
        }
        buf_append(&raw, &len, &cap, chunk, (size_t)r);
    }
    close(fd);
    if (!raw || len < 12 || strncmp(raw, "HTTP/", 5) != 0) {
        free(raw);
        fprintf(stderr, "kaeru-cast: not an HTTP reply\n");
        return -1;
    }
    int status = atoi(raw + 9);
    char *sep = strstr(raw, "\r\n\r\n");
    size_t offset = sep ? (size_t)(sep - raw) + 4 : len;
    *body_len = len - offset;
    *body = malloc(*body_len + 1);
    if (!*body) {
        free(raw);
        return -1;
    }
    memcpy(*body, raw + offset, *body_len);
    (*body)[*body_len] = '\0';
    free(raw);
    return status;
}

static int is_transport(const char *cmd) {
    static const char *names[] = {"play", "pause", "toggle", "next", "prev", "stop", NULL};
    for (int i = 0; names[i]; i++) {
        if (strcmp(cmd, names[i]) == 0) {
            return 1;
        }
    }
    return 0;
}

int main(int argc, char **argv) {
    const char *host = getenv("KAERU_CAST_HOST") ? getenv("KAERU_CAST_HOST") : DEFAULT_HOST;
    const char *port = getenv("KAERU_CAST_PORT") ? getenv("KAERU_CAST_PORT") : DEFAULT_PORT;
    const char *token = getenv("KAERU_CAST_TOKEN");
    int i = 1;
    while (i < argc && argv[i][0] == '-') {
        if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
            fputs(usage, stdout);
            return 0;
        }
        if (i + 1 >= argc) {
            fprintf(stderr, "kaeru-cast: %s needs a value\n", argv[i]);
            return 2;
        }
        if (strcmp(argv[i], "-H") == 0) {
            host = argv[i + 1];
        } else if (strcmp(argv[i], "-p") == 0) {
            port = argv[i + 1];
        } else if (strcmp(argv[i], "-t") == 0) {
            token = argv[i + 1];
        } else {
            fprintf(stderr, "kaeru-cast: unknown option %s\n", argv[i]);
            return 2;
        }
        i += 2;
    }
    if (i >= argc) {
        fputs(usage, stderr);
        return 2;
    }
    const char *cmd = argv[i++];
    char target[MAX_TARGET];
    char *encoded = NULL;
    int ok = 1;

    if (strcmp(cmd, "status") == 0) {
        snprintf(target, sizeof target, "/status");
    } else if (strcmp(cmd, "cast") == 0) {
        if (i >= argc) {
            fprintf(stderr, "kaeru-cast: cast needs a URL\n");
            return 2;
        }
        const char *url = argv[i++];
        const char *mode = "play";
        if (i + 1 < argc && strcmp(argv[i], "--mode") == 0) {
            mode = argv[i + 1];
            i += 2;
        }
        if (strcmp(mode, "play") != 0 && strcmp(mode, "queue") != 0 && strcmp(mode, "next") != 0) {
            fprintf(stderr, "kaeru-cast: --mode must be play, queue or next\n");
            return 2;
        }
        encoded = url_encode(url);
        if (!encoded) {
            return 1;
        }
        if (snprintf(target, sizeof target, "/cast?url=%s&mode=%s", encoded, mode) >= (int)sizeof target) {
            fprintf(stderr, "kaeru-cast: the URL is too long\n");
            free(encoded);
            return 2;
        }
    } else if (is_transport(cmd)) {
        snprintf(target, sizeof target, "/%s", cmd);
    } else if (strcmp(cmd, "volume") == 0) {
        if (i >= argc) {
            fprintf(stderr, "kaeru-cast: volume needs a value (0-130)\n");
            return 2;
        }
        char *end = NULL;
        long value = strtol(argv[i], &end, 10);
        if (end == argv[i] || *end != '\0' || value < 0 || value > 130) {
            fprintf(stderr, "kaeru-cast: volume must be a number from 0 to 130\n");
            return 2;
        }
        snprintf(target, sizeof target, "/volume?value=%ld", value);
    } else {
        fprintf(stderr, "kaeru-cast: unknown command %s\n%s", cmd, usage);
        return 2;
    }

    if (token && *token) {
        char *enc_token = url_encode(token);
        if (!enc_token) {
            free(encoded);
            return 1;
        }
        char base[MAX_TARGET];
        memcpy(base, target, sizeof target);
        int wrote = snprintf(target, sizeof target, "%s%ctoken=%s", base, strchr(base, '?') ? '&' : '?', enc_token);
        free(enc_token);
        if (wrote < 0 || wrote >= (int)sizeof target) {
            free(encoded);
            fprintf(stderr, "kaeru-cast: the request is too long\n");
            return 2;
        }
    }

    char *body = NULL;
    size_t body_len = 0;
    int status = http_get(host, port, target, &body, &body_len);
    free(encoded);
    if (status < 0) {
        free(body);
        return 3;
    }
    if (body_len > 0) {
        fwrite(body, 1, body_len, stdout);
        if (body[body_len - 1] != '\n') {
            fputc('\n', stdout);
        }
    }
    ok = status >= 200 && status < 300;
    free(body);
    if (!ok) {
        fprintf(stderr, "kaeru-cast: HTTP %d\n", status);
    }
    return ok ? 0 : 1;
}
