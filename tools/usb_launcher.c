// GoProUSBLauncher — tiny launchd helper behind the optional "open when a
// GoPro is plugged in" setting. The per-user LaunchAgent (see AutoLaunch.swift)
// starts this binary when a USB device with GoPro's vendor ID (0x2672)
// attaches; it opens the app bundle it is embedded in and exits.
#include <xpc/xpc.h>
#include <mach-o/dyld.h>
#include <libgen.h>
#include <limits.h>
#include <spawn.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

int main(void) {
    // launchd requires launch events to be consumed via the XPC event stream
    // API; without this the job would be respawned in a loop.
    xpc_set_event_stream_handler("com.apple.iokit.matching", NULL,
                                 ^(xpc_object_t event) { (void)event; });

    // .../GoProViewer.app/Contents/MacOS/GoProUSBLauncher -> .../GoProViewer.app
    char exec[PATH_MAX];
    uint32_t len = sizeof(exec);
    if (_NSGetExecutablePath(exec, &len) != 0) return 1;
    char resolved[PATH_MAX];
    if (realpath(exec, resolved) == NULL) return 1;
    char *app = dirname(dirname(dirname(resolved)));

    char *argv[] = {"/usr/bin/open", app, NULL};
    pid_t pid;
    if (posix_spawn(&pid, argv[0], NULL, NULL, argv, environ) == 0) {
        int status;
        waitpid(pid, &status, 0);
    }
    sleep(2); // let the event handler drain before exiting
    return 0;
}
