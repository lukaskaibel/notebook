#import "NotebookTestSupport.h"
#import <errno.h>
#import <objc/runtime.h>
#import <signal.h>
#import <unistd.h>

// Every `swift test` on a Mac runs as xctest, so every test run shares xctest's settings (com.apple.dt.xctest.tool),
// and a process sees another's change to them at once: two runs at the same time, from two worktrees, changed the
// library, the slow-disk settings and the default folder under each other's tests (#136). So in a test run the
// standard settings are a suite of the run's own, kept in a folder of its own, which the app's code, AppKit and the
// tests all read through `UserDefaults.standard`. It starts empty, sees the arguments and the global settings as the
// standard settings do, and goes with the folder when the run ends.

static NSURL *runFolder;
static NSString *settingsPath;
static NSUserDefaults *settings;

NSURL *NotebookTestRunFolder(void) {
    return runFolder;
}

static NSString *const prefix = @"notebook-test-run-";

static void removeRunFolder(void) {
    [settings removePersistentDomainForName:settingsPath];
    [NSFileManager.defaultManager removeItemAtURL:runFolder error:nil];
}

// The folders of runs that ended without getting to `removeRunFolder`: crashed, killed or stopped with Ctrl-C. A run
// whose process is still there, this Mac's other test runs, keeps its own.
static void removeFoldersOfEndedRuns(void) {
    NSString *temporary = NSTemporaryDirectory();
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:temporary error:nil]) {
        if (![name hasPrefix:prefix]) continue;
        pid_t pid = (pid_t)[[name substringFromIndex:prefix.length] intValue];
        if (pid <= 0 || kill(pid, 0) == 0 || errno != ESRCH) continue;
        [NSFileManager.defaultManager removeItemAtPath:[temporary stringByAppendingPathComponent:name] error:nil];
    }
}

@implementation NSUserDefaults (NotebookTestRun)

// As the tests are loaded, before any of them runs.
+ (void)load {
    removeFoldersOfEndedRuns();
    NSString *name = [NSString stringWithFormat:@"%@%d-%@", prefix, getpid(), [NSUUID.UUID.UUIDString substringToIndex:8]];
    runFolder = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name] isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:runFolder withIntermediateDirectories:YES attributes:nil error:nil];
    // A suite named by a path keeps its settings in that file (plus .plist), not in ~/Library/Preferences.
    settingsPath = [runFolder URLByAppendingPathComponent:@"Settings"].path;
    settings = [[NSUserDefaults alloc] initWithSuiteName:settingsPath];
    NSAssert(settings != nil, @"no settings of the test run's own");
    Method standard = class_getClassMethod(self, @selector(standardUserDefaults));
    method_setImplementation(standard, imp_implementationWithBlock(^NSUserDefaults *(id _) { return settings; }));
    atexit(removeRunFolder);
}

@end
