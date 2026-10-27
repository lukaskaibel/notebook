#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A folder of this test run's own, which goes when the run ends. Its settings are in it: in a test run,
/// `UserDefaults.standard` is a suite there (TestRun.m), as every `swift test` on a Mac runs as xctest and would
/// otherwise share xctest's settings with every other run at the same time.
NSURL *NotebookTestRunFolder(void);

NS_ASSUME_NONNULL_END
