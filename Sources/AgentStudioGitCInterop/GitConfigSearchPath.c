#include "AgentStudioGitCInterop.h"

int agentstudio_git_get_search_path(git_config_level_t level, git_buf *output) {
    return git_libgit2_opts(GIT_OPT_GET_SEARCH_PATH, (int)level, output);
}
