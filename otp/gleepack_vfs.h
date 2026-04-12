/* VFS types, global state, and function declarations for the gleepack in-memory
 * file system. This header is shared by gleepack_entry.c, unix_prim_file.c,
 * and win_prim_file.c. */

#ifndef GLEEPACK_VFS_H
#define GLEEPACK_VFS_H

#include <stdint.h>
#include <stddef.h>
#include <sys/types.h>

/* hash.h is available in nifs/{unix,win32} and sys/{unix,win32} build contexts. */
#include "hash.h"

/* Magic discriminator: stored in every efile_gleepack_t to distinguish gleepack
 * handles from native efile_unix_t handles at dispatch time. */
#define GLEEPACK_MAGIC 0xBEAFC0DE

/* Prefix intercepted by VFS; all other paths pass through to the OS unchanged. */
#define GLEEPACK_PREFIX     "/__gleepack__/"
#define GLEEPACK_PREFIX_LEN 14

/* efile_gleepack_t and gleepack_is_handle() require efile_data_t from
 * prim_file_nif.h.  They are needed in unix_prim_file.c and win_prim_file.c
 * (nifs/ build context).  The caller must #define GLEEPACK_HAVE_EFILE_DATA
 * before including this header to opt in; erl_main.c (sys/) does not define
 * it and therefore gets only the VFS index/lookup API. */
#ifdef GLEEPACK_HAVE_EFILE_DATA
/* In-memory file handle.  The common field MUST be first so that a pointer to
 * efile_gleepack_t can be safely cast to efile_data_t * and back (C-style
 * inheritance, matching the efile_unix_t / efile_win_t pattern). */
typedef struct {
    efile_data_t   common; /* MUST be first — cast compatibility */
    uint32_t       magic;  /* == GLEEPACK_MAGIC */
    const uint8_t  *buf;    /* pointer into cached buffer (read-only) */
    size_t         size;   /* total uncompressed size */
    size_t         pos;    /* current read position */
} efile_gleepack_t;
#endif /* GLEEPACK_HAVE_EFILE_DATA */

/* One entry in the VFS index.  HashBucket MUST be the first field — required
 * by hash.h so that (HashBucket *) == (gleepack_index_entry_t *). */
typedef struct {
    HashBucket bucket;              /* MUST be first — required by hash.h */
    char      *filename;            /* malloc'd, NUL-terminated */
    size_t     filename_len;
    uint16_t   compression;         /* 0=STORED, 8=DEFLATE */
    uint32_t   comp_size;
    uint32_t   uncomp_size;
    uint32_t   local_header_offset; /* offset of local file header in archive fd */
    uint8_t   *cached_data;         /* NULL until first access; malloc'd for DEFLATE,
                                     * points into zmap for STORED */
} gleepack_index_entry_t;

/* Global VFS state.  Populated once in gleepack_vfs_init() before erl_start().
 * zmap is NULL when no archive is present (graceful no-op, per D-14). */
typedef struct {
    uint8_t *zmap;           /* mmap of entire executable, NULL if no archive */
    size_t   zsize;          /* length of mmap region */
    off_t    archive_offset; /* byte offset where the ZIP starts within zmap */
    Hash    *index;          /* filename -> gleepack_index_entry_t, NULL if no archive */
} gleepack_vfs_t;

/* The single global VFS instance, defined in gleepack_entry.c. */
extern gleepack_vfs_t g_vfs;

/* Open the running executable, locate the appended ZIP archive, parse its
 * central directory into g_vfs.index.  Exits with an error message on
 * hard failures; sets g_vfs.zmap = NULL if no archive is found. */
void gleepack_vfs_init(void);

/* Look up a path in the VFS index.  path must NOT include the /__gleepack__/
 * prefix.  Returns NULL when no archive is loaded or the entry is absent. */
gleepack_index_entry_t *gleepack_vfs_lookup(const char *path);

/* Return a pointer to the uncompressed data for entry.  Decompresses on first
 * call and caches the result; subsequent calls return immediately.  Returns NULL
 * on decompression failure. */
const uint8_t *gleepack_vfs_get_data(gleepack_index_entry_t *entry);

/* Iterate over every entry in the index, calling fn(entry, arg) for each.
 * Wraps hash_foreach; used by efile_list_dir. */
void gleepack_vfs_foreach(void (*fn)(gleepack_index_entry_t *, void *), void *arg);

/* Return 1 if d is a gleepack handle (magic check), 0 otherwise.
 * Only available when GLEEPACK_HAVE_EFILE_DATA is defined. */
#ifdef GLEEPACK_HAVE_EFILE_DATA
static inline int gleepack_is_handle(efile_data_t *d) {
    return ((efile_gleepack_t *)d)->magic == GLEEPACK_MAGIC;
}
#endif /* GLEEPACK_HAVE_EFILE_DATA */

#endif /* GLEEPACK_VFS_H */
