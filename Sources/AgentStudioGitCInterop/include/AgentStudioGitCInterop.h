#ifndef AGENTSTUDIO_GIT_C_INTEROP_H
#define AGENTSTUDIO_GIT_C_INTEROP_H

#include <git2.h>

/* Swift cannot call the variadic git_libgit2_opts API directly. */
int agentstudio_git_get_search_path(git_config_level_t level, git_buf *output);

#endif
