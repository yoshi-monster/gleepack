/* Entry point for the gleepack standalone Erlang VM.  Initialises the in-memory
 * VFS from the ZIP archive appended to this executable, then hands off to the
 * standard ERTS startup. */

#ifdef HAVE_CONFIG_H
#  include "config.h"
#endif

#include "sys.h"
#include "erl_vm.h"
#include "global.h"
#include "hash.h"
#include "zlib.h"

#include "gleepack_vfs.h"

#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdio.h>
#include <sys/mman.h>
#include <sys/stat.h>

#ifdef __APPLE__
#  include <mach-o/dyld.h>
#endif

/* The single global VFS instance.  Zero-initialised; zmap == NULL means no
 * archive was found and all /__gleepack__/ lookups return ENOENT. */
gleepack_vfs_t g_vfs = {0};

/* -- Hash table callbacks --------------------------------------------------*/

static void *vfs_meta_alloc(int type, size_t sz) {
    (void)type;
    return malloc(sz);
}

static void  vfs_meta_free(int type, void *p) {
    (void)type;
    free(p);
}

static HashValue vfs_hash(void *e) {
    char *s = ((gleepack_index_entry_t *)e)->filename;
    HashValue h = 5381;
    while (*s) h = ((h << 5) + h) ^ (unsigned char)*s++;
    return h;
}

static int vfs_cmp(void *a, void *b) {
    return strcmp(((gleepack_index_entry_t *)a)->filename,
                  ((gleepack_index_entry_t *)b)->filename);
}

static void *vfs_alloc(void *src) {
    gleepack_index_entry_t *e = malloc(sizeof(*e));

    *e = *(gleepack_index_entry_t*)src;
    e->filename = strdup(e->filename);
    return e;
}

static void vfs_free_entry(void *e) {
    gleepack_index_entry_t *entry = e;
    free(entry->filename);
    /* cached_data: DEFLATE entries are malloc'd; STORED entries point into zmap.
     * We never free the cache (process lifetime), so nothing to do here. */
    free(entry);
}

static HashFunctions vfs_hash_fns = {
    vfs_hash, vfs_cmp, vfs_alloc, vfs_free_entry,
    vfs_meta_alloc, vfs_meta_free, NULL
};

/* -- Helpers -------------------------------------------------------------- */

/* Read a little-endian uint16 from an unaligned pointer. */
static uint16_t le16(uint8_t *p) {
    return (uint16_t)(p[0] | (uint16_t)p[1] << 8);
}

/* Read a little-endian uint32 from an unaligned pointer. */
static uint32_t le32(uint8_t *p) {
    return (uint32_t)p[0] | (uint32_t)p[1] << 8
         | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

/* -- Platform: locate the running executable ------------------------------ */

static int open_self_exe(void) {
#ifdef __linux__
    return open("/proc/self/exe", O_RDONLY);
#elif defined(__APPLE__)
    char buf[4096];
    uint32_t size = sizeof(buf);
    if (_NSGetExecutablePath(buf, &size) != 0) return -1;
    return open(buf, O_RDONLY);
#else
#  error "unsupported platform"
#endif
}

/* -- ZIP parsing ---------------------------------------------------------- */

/* Locate the EOCD record by scanning backward through map[0..size).
 *
 * On success fills:
 *   *cd_offset     — central directory offset within the embedded ZIP
 *   *num_entries   — number of CD entries
 *   *archive_start — byte in the full file where the ZIP data begins
 *
 * Returns 1 on success, 0 if no valid EOCD found.
 */
static int find_eocd(
    uint8_t *map, size_t size,
    off_t *cd_offset,
    uint16_t *num_entries,
    off_t *archive_start
) {
    /* Minimum EOCD is 22 bytes; max ZIP comment is 65535 bytes. */
    size_t window = size < (65535 + 22) ? size : (65535 + 22);
    if (size < 22) return 0;

    uint8_t *end = map + size - 22;
    uint8_t *lo  = map + size - window;

    /* Scan backward for 'PK\x05\x06'. */
    uint8_t *p;
    for (p = end; p >= lo; p--) {
        if (p[0] == 0x50 && p[1] == 0x4b && p[2] == 0x05 && p[3] == 0x06) {
            uint16_t entries = le16(p + 10);
            uint32_t cd_size = le32(p + 12);
            uint32_t cd_off_in_zip = le32(p + 16);

            size_t eocd_file_pos = (size_t)(p - map);

            /* Sanity: cd must fit before the EOCD. */
            if (cd_off_in_zip > eocd_file_pos) continue;
            if (cd_size > eocd_file_pos) continue;

            *archive_start = (off_t)(eocd_file_pos - cd_size - cd_off_in_zip);
            *cd_offset = (off_t)cd_off_in_zip;
            *num_entries = entries;
            return 1;
        }
    }

    return 0;
}

/* Validate length fields against file bounds before processing an entry.
 * This mitigates the threat of malformed ZIPs with oversized length fields. */
static int entry_in_bounds(
    uint8_t *map, size_t map_size,
    uint8_t *p, size_t fixed_sz,
    uint16_t fname_len, uint16_t extra_len, uint16_t comment_len
) {
    size_t offset = (size_t)(p - map);
    size_t total  = fixed_sz + (size_t)fname_len + (size_t)extra_len + (size_t)comment_len;
    return offset + total <= map_size;
}

/* Parse the ZIP central directory and populate g_vfs.index.
 *
 * All access is pointer arithmetic into map — no lseek, no read.
 * archive_start is the byte offset within map where the ZIP begins.
 * cd_offset is the central directory offset relative to archive_start.
 */
static void parse_central_directory(
    uint8_t *map, size_t map_size,
    off_t archive_start,
    off_t cd_offset,
    uint16_t num_entries
) {
    /* Cap entry count to defend against corrupt archives. */
    if (num_entries > 10000) {
        fprintf(stderr, "gleepack: archive entry count %u exceeds limit (10000)\n",
                (unsigned)num_entries);
        exit(1);
    }

    g_vfs.index = hash_new(0, "gleepack_vfs", (int)num_entries, vfs_hash_fns);

    uint8_t *p = map + archive_start + cd_offset;

    for (uint16_t i = 0; i < num_entries; i++) {
        /* Verify central directory entry magic (PK\x01\x02). */
        if (!entry_in_bounds(map, map_size, p, 46, 0, 0, 0) || le32(p) != 0x02014b50) {
            fprintf(stderr, "gleepack: corrupt archive at entry %u\n", (unsigned)i);
            exit(1);
        }

        uint16_t fname_len = le16(p + 28);
        uint16_t extra_len = le16(p + 30);
        uint16_t comment_len = le16(p + 32);

        if (!entry_in_bounds(map, map_size, p, 46, fname_len, extra_len, comment_len)) {
            fprintf(stderr, "gleepack: corrupt archive entry %u: fields out of bounds\n",
                    (unsigned)i);
            exit(1);
        }

        uint16_t compression = le16(p + 10);
        uint32_t comp_size = le32(p + 20);
        uint32_t uncomp_size = le32(p + 24);
        uint32_t local_header_offset = le32(p + 42);

        /* Validate individual file size (100 MB cap). */
        if (uncomp_size > 100 * 1024 * 1024) {
            fprintf(stderr, "gleepack: entry %u uncompressed size %u exceeds 100MB\n",
                    (unsigned)i, (unsigned)uncomp_size);
            exit(1);
        }

        /* Build a NUL-terminated filename from the inline bytes. */
        char fname_buf[255];
        if (fname_len >= sizeof(fname_buf)) {
            fname_len = sizeof(fname_buf) - 1;
        }

        memcpy(fname_buf, p + 46, fname_len);
        fname_buf[fname_len] = '\0';

        gleepack_index_entry_t tmpl = {0};
        tmpl.filename = fname_buf;
        tmpl.filename_len = fname_len;
        tmpl.compression = compression;
        tmpl.comp_size = comp_size;
        tmpl.uncomp_size = uncomp_size;
        tmpl.local_header_offset = local_header_offset;
        tmpl.cached_data = NULL;

        /* this copies the entry, so we don't have to worry about fname_buf */
        hash_put(g_vfs.index, &tmpl);

        p += 46 + fname_len + extra_len + comment_len;
    }
}

/* -- Public VFS API ------------------------------------------------------- */

gleepack_index_entry_t *gleepack_vfs_lookup(const char *path) {
    if (!g_vfs.index) return NULL;
    gleepack_index_entry_t tmpl = {0};
    tmpl.filename = (char *)path;
    return (gleepack_index_entry_t *)hash_get(g_vfs.index, &tmpl);
}

void gleepack_vfs_foreach(void (*fn)(gleepack_index_entry_t *, void *), void *arg) {
    hash_foreach(g_vfs.index, (HFOREACH_FUN)fn, arg);
}

const uint8_t *gleepack_vfs_get_data(gleepack_index_entry_t *entry) {
    if (entry->cached_data != NULL) return entry->cached_data;

    /* Re-read the local file header to get the actual extra_len, which may
     * differ from the central directory extra_len. */
    uint8_t *lhdr = g_vfs.zmap + g_vfs.archive_offset + entry->local_header_offset;
    uint16_t lfname_len = le16(lhdr + 26);
    uint16_t lextra_len = le16(lhdr + 28);
    uint8_t *data = lhdr + 30 + lfname_len + lextra_len;

    if (entry->compression == 0) {
        /* STORED: zero-copy — point directly into the mmap. */
        entry->cached_data = (uint8_t *)data;
    } else if (entry->compression == 8) {
        /* DEFLATE: decompress into a malloc'd buffer. */
        uint8_t *buf = malloc(entry->uncomp_size);
        if (!buf) {
            fprintf(stderr, "gleepack: out of memory decompressing %s\n",
                entry->filename);
            exit(1);
        }

        z_stream zs;
        memset(&zs, 0, sizeof(zs));
        zs.next_in = (z_const Bytef *)data;
        zs.avail_in = entry->comp_size;
        zs.next_out = buf;
        zs.avail_out = entry->uncomp_size;

        /* -15: raw DEFLATE (no zlib/gzip wrapper). */
        if (inflateInit2(&zs, -15) != Z_OK) {
            fprintf(stderr, "gleepack: inflateInit2 failed for %s\n",
                    entry->filename);
            exit(1);
        }
        int rc = inflate(&zs, Z_FINISH);
        inflateEnd(&zs);

        if (rc != Z_STREAM_END) {
            fprintf(stderr, "gleepack: inflate failed (%d) for %s\n",
                    rc, entry->filename);
            exit(1);
        }

        entry->cached_data = buf;
    } else {
        fprintf(stderr, "gleepack: unsupported compression method %u for %s\n",
                (unsigned)entry->compression, entry->filename);
        exit(1);
    }

    return entry->cached_data;
}

void gleepack_vfs_init(void) {
    int fd = open_self_exe();
    if (fd < 0) {
        fprintf(stderr, "gleepack: cannot open self executable\n");
        exit(1);
    }

    struct stat st;
    if (fstat(fd, &st) != 0) {
        fprintf(stderr, "gleepack: fstat failed\n");
        exit(1);
    }

    uint8_t *map = mmap(0, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd); /* fd no longer needed — mmap keeps the data alive */

    if (map == MAP_FAILED) {
        fprintf(stderr, "gleepack: mmap failed\n");
        exit(1);
    }

    off_t cd_offset, archive_start;
    uint16_t num_entries;

    if (!find_eocd(map, (size_t)st.st_size, &cd_offset, &num_entries, &archive_start)) {
        /* No archive appended — VFS is empty; all /__gleepack__/ reads return ENOENT */
        munmap(map, (size_t)st.st_size);
        g_vfs.zmap = NULL;
        return;
    }

    g_vfs.zmap = map;
    g_vfs.zsize = (size_t)st.st_size;
    g_vfs.archive_offset = archive_start;

    parse_central_directory(map, (size_t)st.st_size, archive_start, cd_offset, num_entries);
}

/* -- erl_args file parser ------------------------------------------------- */

/* Parse an erl_args file: NUL-separated tokens with a trailing NUL.
 *
 * The data buffer must remain valid for the process lifetime (VFS entries
 * satisfy this: STORED entries point into the mmap; DEFLATE entries are in a
 * process-lifetime malloc buffer).
 *
 * Returns a malloc'd argv array; *out_argc is the token count. */
static char **parse_erl_args(const uint8_t *data, size_t size, int *out_argc)
{
    /* Pass 1: one NUL byte == one token. */
    int count = 0;
    for (size_t i = 0; i < size; i++) {
        if (data[i] == '\0') count++;
    }

    *out_argc = count;
    if (!count) return NULL;

    char **args = malloc(count * sizeof(char *));
    if (!args) return NULL;

    /* Pass 2: first token starts at data[0]; each interior NUL starts the next.
     * The trailing NUL (i == size-1) terminates the last token but does not
     * begin a new one. */
    args[0] = (char *)data;
    int idx = 1;
    for (size_t i = 0; i < size - 1; i++) {
        if (data[i] == '\0') {
            args[idx++] = (char *)data + i + 1;
        }
    }

    return args;
}

/* -- Entry point ------------------------------------------------------------ */

int
main(int argc, char **argv)
{
    /* Must be done before we have a chance to spawn any scheduler threads. */
    sys_init_signal_stack();

    gleepack_vfs_init();

    /* No archive attached — behave as a normal BEAM binary, passing the
     * caller's argv straight through.  This allows the gleepack CLI to
     * invoke the binary with standard flags (-root, -boot, -extra, etc.)
     * to run escripts or Erlang files without a bundled release. */
    if (g_vfs.zmap == NULL) {
        erl_start(argc, argv);
        return 0;
    }

    static const char default_erl_args[] =
        "-L\0-d\0" "-Bd\0-sbtu\0-A0\0-P\065536\0-Q\0" "1024\0"
        "--\0"
        "-root\0/__gleepack__\0"
        "-bindir\0/__gleepack__/bin\0"
        "-boot\0/__gleepack__/start\0"
        "-kernel\0inetrc\0\"/__gleepack__/erl_inetrc\"\0"
        "-noshell\0"
        "-noinput\0"
        "-mode\0minimal\0";

    /* Try to load VM arguments from erl_args inside the ZIP archive.
     * The CLI writes this file so that flags are configurable without
     * recompiling the runtime.  Fall back to the built-in defaults above
     * when the file is absent. */
    char **erl_args;
    int erl_argc;

    gleepack_index_entry_t *args_entry = gleepack_vfs_lookup("erl_args");
    if (args_entry && gleepack_vfs_get_data(args_entry)) {
        const uint8_t *data = gleepack_vfs_get_data(args_entry);
        erl_args = parse_erl_args(data, args_entry->uncomp_size, &erl_argc);
    } else {
        erl_args = parse_erl_args((const uint8_t *)default_erl_args, sizeof(default_erl_args) - 1, &erl_argc);
    }
    if (!erl_args) {
        fprintf(stderr, "gleepack: out of memory building argv\n");
        exit(1);
    }

    /* Always inject -progname argv[0] -extra between the erl_args tokens and
     * the original argv (which becomes the application's extra arguments). */
    char *structural[] = { "-progname", argv[0], "-extra" };
    int nstructural  = (int)(sizeof(structural) / sizeof(structural[0]));

    int new_argc = 1 + erl_argc + nstructural + argc;
    char **new_argv = malloc((size_t)new_argc * sizeof(char *));
    if (!new_argv) {
        fprintf(stderr, "gleepack: out of memory building argv\n");
        exit(1);
    }

    new_argv[0] = argv[0];
    memcpy(new_argv + 1,  erl_args, erl_argc * sizeof(char *));
    memcpy(new_argv + 1 + erl_argc, structural, nstructural * sizeof(char *));
    memcpy(new_argv + 1 + erl_argc + nstructural, argv, argc * sizeof(char *));

    erl_start(new_argc, new_argv);
    return 0;
}
