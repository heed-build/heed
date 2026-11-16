// The test process ignores SIGPIPE, as the app and the heed CLI do at the top of main (BrokenPipe.ignore()).
//
// Swift Testing has no hook that runs before every test, and a trait or a shared helper only covers the tests that
// use it: a test that spawns an agent without it would bring back the crash it is there to prevent. A constructor in
// the test bundle runs when the bundle is loaded, before the runner looks for a single test.
#include <signal.h>

__attribute__((constructor)) static void heed_test_ignore_sigpipe(void) {
    signal(SIGPIPE, SIG_IGN);
}
