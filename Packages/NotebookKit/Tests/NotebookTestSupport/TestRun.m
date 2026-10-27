#import "NotebookTestSupport.h"
#import <objc/runtime.h>
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

static void removeRunFolder(void) {
    [settings removePersistentDomainForName:settingsPath];
    [NSFileManager.defaultManager removeItemAtURL:runFolder error:nil];
}

@implementation NSUserDefaults (NotebookTestRun)

// As the tests are loaded, before any of them runs.
+ (void)load {
    NSString *name = [NSString stringWithFormat:@"notebook-test-run-%d-%@", getpid(),
                      [NSUUID.UUID.UUIDString substringToIndex:8]];
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
