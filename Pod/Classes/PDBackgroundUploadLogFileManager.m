//
//  PDBackgroundUploadLogFileManager.m
//  Pods
//
//  Created by Eric Jensen on 2/12/15.
//
//

#import "PDBackgroundUploadLogFileManager.h"

#ifdef DEBUG
  #define PDLog(__FORMAT__, ...) NSLog(__FORMAT__, ##__VA_ARGS__)
#else
  #define PDLog(__FORMAT__, ...)
#endif

@interface PDBackgroundUploadLogFileManager()

@property (strong, nonatomic) NSURLRequest *uploadRequest;

// discretionary prevents uploading unless on wi-fi even if log is rolled in foreground
@property (assign, nonatomic) BOOL discretionary;

@property (weak, nonatomic) id<PDBackgroundUploadLogFileManagerDelegate> delegate;

@property (strong, nonatomic) NSURLSession *session;
@property (copy, nonatomic) void(^completionHandler)();

@end

@implementation PDBackgroundUploadLogFileManager

- (id)initWithUploadRequest:(NSURLRequest *)uploadRequest
{
    if ((self = [super init])) {
        _uploadRequest = uploadRequest;
        _discretionary = YES;
        [self setupSession];
    }
    return self;
}

- (id)initWithUploadRequest:(NSURLRequest *)uploadRequest discretionary:(BOOL)discretionary delegate:(id<PDBackgroundUploadLogFileManagerDelegate>)delegate
{
    if ((self = [super init])) {
        _uploadRequest = uploadRequest;
        _discretionary = discretionary;
        _delegate = delegate;
        [self setupSession];
    }
    return self;
}

- (instancetype)initWithUploadRequest:(NSURLRequest *)uploadRequest discretionary:(BOOL)discretionary delegate:(id<PDBackgroundUploadLogFileManagerDelegate>)delegate logsDirectory:(NSString *)logsDirectory
{
    if ((self = [super initWithLogsDirectory:logsDirectory])) {
        _uploadRequest = uploadRequest;
        _discretionary = discretionary;
        _delegate = delegate;
        [self setupSession];
    }
    return self;
}

#if TARGET_OS_IPHONE
- (instancetype)initWithWithUploadRequest:(NSURLRequest *)uploadRequest discretionary:(BOOL)discretionary delegate:(id<PDBackgroundUploadLogFileManagerDelegate>)delegate logsDirectory:(NSString *)logsDirectory defaultFileProtectionLevel:(NSString*)fileProtectionLevel
{
    if ((self = [super initWithLogsDirectory:logsDirectory defaultFileProtectionLevel:fileProtectionLevel])) {
        _uploadRequest = uploadRequest;
        _discretionary = discretionary;
        _delegate = delegate;
        [self setupSession];
    }
    return self;
}
#endif

- (NSString *)sessionIdentifier
{
    return [self logsDirectory];
}

#pragma mark - Notifications from DDFileLogger

- (void)didArchiveLogFile:(NSString *)logFilePath
{
    PDLog(@"BackgroundUploadLogFileManager: didArchiveLogFile: %@", [logFilePath lastPathComponent]);
    [self uploadArchivedFiles];
}

- (void)didRollAndArchiveLogFile:(NSString *)logFilePath
{
    PDLog(@"BackgroundUploadLogFileManager: didRollAndArchiveLogFile: %@", [logFilePath lastPathComponent]);
    [self uploadArchivedFiles];
}

#pragma mark - private

- (void)setupSession
{
    NSURLSessionConfiguration *backgroundConfiguration;
    if ([NSURLSessionConfiguration respondsToSelector:@selector(backgroundSessionConfigurationWithIdentifier:)]) {
        backgroundConfiguration = [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:[self sessionIdentifier]];
    } else {
        backgroundConfiguration = [NSURLSessionConfiguration backgroundSessionConfiguration:[self sessionIdentifier]];
    }
    backgroundConfiguration.discretionary = self.discretionary;
    self.session = [NSURLSession sessionWithConfiguration:backgroundConfiguration delegate:self delegateQueue:nil];
}

// retries any files that may have errored
- (void)uploadArchivedFiles
{
    [self.session getTasksWithCompletionHandler:^(NSArray *dataTasks, NSArray *uploadTasks, NSArray *downloadTasks) {
        dispatch_async([DDLog loggingQueue], ^{ @autoreleasepool {
            NSArray *fileInfos = [self unsortedLogFileInfos];
            NSMutableSet *filesToUpload = [NSMutableSet setWithCapacity:[fileInfos count]];
            for (DDLogFileInfo *fileInfo in fileInfos) {
                if (fileInfo.isArchived) {
                    [filesToUpload addObject:fileInfo.filePath];
                }
            }
            
            for (NSURLSessionTask *task in uploadTasks) {
                [filesToUpload removeObject:[self filePathForTask:task]];
            }
            
            for (NSString *filePath in filesToUpload) {
                [self uploadLogFile:filePath];
            }
        }});
    }];
}

- (void)uploadLogFile:(NSString *)logFilePath
{
    NSURLSessionTask *task = [self.session uploadTaskWithRequest:self.uploadRequest fromFile:[NSURL fileURLWithPath:logFilePath]];
    task.taskDescription = logFilePath;
    PDLog(@"BackgroundUploadLogFileManager: started uploading: %@", [self filePathForTask:task]);
    [task resume];
    if ([self.delegate respondsToSelector:@selector(attemptingUploadForFilePath:)]) {
        [self.delegate attemptingUploadForFilePath:logFilePath];
    }
}

- (NSString *)filePathForTask:(NSURLSessionTask *)task
{
    NSAssert(task.taskDescription, @"taskDescription should contain file path");
    return task.taskDescription;
}

#pragma mark - app delegate forwarding

- (void)handleEventsForBackgroundURLSession:(void (^)())completionHandler
{
    self.completionHandler = completionHandler;
}

#pragma mark - NSURLSessionDelegate

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error
{
    NSString *filePath = [self filePathForTask:task];
    PDLog(@"BackgroundUploadLogFileManager: task: %@ didCompleteWithError: %@", filePath, error);
    
    dispatch_async([DDLog loggingQueue], ^{ @autoreleasepool {
        if (!error) {
            NSError *deleteError;
            [[NSFileManager defaultManager] removeItemAtPath:filePath error:&deleteError];
            if (deleteError) {
                PDLog(@"BackgroundUploadLogFileManager: Error deleting file %@: %@", filePath, deleteError);
            }
            if ([self.delegate respondsToSelector:@selector(uploadTaskForFilePath:didCompleteWithError:)]) {
                [self.delegate uploadTaskForFilePath:filePath didCompleteWithError:nil];
            }
        } else if ([self.delegate respondsToSelector:@selector(uploadTaskForFilePath:didCompleteWithError:)]) {
            // only call back with failure if this was the last retry
            NSArray *fileInfos = [self sortedLogFileInfos];
            if (self.maximumNumberOfLogFiles <= [fileInfos count] && [[[fileInfos lastObject] filePath] isEqualToString:filePath]) {
                [self.delegate uploadTaskForFilePath:filePath didCompleteWithError:error];
            }
        }
    }});
}

- (void)URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession *)session
{
    // ensure all deletes are complete before calling completion
    dispatch_async([DDLog loggingQueue], ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.completionHandler) {
                self.completionHandler();
                self.completionHandler = nil;
            }
        });
    });
}

- (void)URLSession:(NSURLSession *)session didBecomeInvalidWithError:(NSError *)error
{
    PDLog(@"BackgroundUploadLogFileManager: session: %@ didBecomeInvalidWithError: %@", session, error);
    [self setupSession];
}

@end
