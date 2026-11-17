// The test process ignores SIGPIPE, as the app and the heed CLI do at the top of main (BrokenPipe.ignore()), and
// keeps git to the tests' throwaway repos.
//
// Swift Testing has no hook that runs before every test, and a trait or a shared helper only covers the tests that
// use it: a test that spawns an agent without it would bring back the crash it is there to prevent. A constructor in
// the test bundle runs when the bundle is loaded, before the runner looks for a single test, and before any thread
// that could read the environment while it is written.
#include <signal.h>
#include <stdlib.h>

__attribute__((constructor)) static void heed_test_ignore_sigpipe(void) {
    signal(SIGPIPE, SIG_IGN);
}

// Every git command a test runs, however it is started, reads no system or global config and commits as a fixed
// author, so neither your config nor your signing setup reaches the tests' repos. Set for the whole process from the
// start, so no test depends on whether another one ran first.
__attribute__((constructor)) static void heed_test_isolate_git(void) {
    setenv("GIT_CONFIG_NOSYSTEM", "1", 1);
    setenv("GIT_CONFIG_GLOBAL", "/dev/null", 1);
    setenv("GIT_AUTHOR_NAME", "heed test", 1);
    setenv("GIT_AUTHOR_EMAIL", "test@heed.invalid", 1);
    setenv("GIT_COMMITTER_NAME", "heed test", 1);
    setenv("GIT_COMMITTER_EMAIL", "test@heed.invalid", 1);
}
