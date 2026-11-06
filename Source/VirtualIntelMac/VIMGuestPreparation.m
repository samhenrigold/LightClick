#import "VIMGuestPreparation.h"
#import "VIMGuestFiles.h"
#import "MachineKit-Swift.h"
#import "VIMGuestAgent.h"
#import "VIMQMPConnection.h"
#import "GuestControl-Swift.h"
@interface VIMGuestPreparation ()
@property VIMGuestAgent *agent;
@property VIMQMPConnection *control;
@property VIMGuestProgress *progressUI;
@property BOOL supportInserted;
@property BOOL supportUnmounted;
@property BOOL headlessRepair;
@property double transferStarted;
@property NSURL *runtime;
@property NSURL *journal;
@property NSDictionary *initialReport;
@property NSString *archiveFilename;
@property NSMutableDictionary *state;
@property(copy) void (^progress)(NSString *);
@property(copy) void (^completion)(NSDictionary *, NSError *);
@end
@implementation VIMGuestPreparation
+ (void)prepareWithAgent:(id)agent
                  report:(NSDictionary *)report
                 runtime:(NSURL *)runtime
                 journal:(NSURL *)journal
                 control:(id)control
     allowHeadlessRepair:(BOOL)headlessRepair
                progress:(void (^)(NSString *))progress
              completion:(void (^)(NSDictionary *, NSError *))completion {
    VIMGuestPreparation *operation = [self new];
    operation.agent = agent;
    operation.runtime = runtime;
    operation.journal = journal;
    operation.control = control;
    operation.headlessRepair = headlessRepair;
    operation.initialReport = report;
    operation.progress = progress;
    operation.completion = completion;
    [operation start];
}
- (BOOL)savePhase:(NSString *)phase error:(NSError **)error {
    self.state[@"Phase"] = phase;
    self.state[@"UpdatedAt"] = NSDate.date;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:self.state
                                                              format:NSPropertyListBinaryFormat_v1_0
                                                             options:0
                                                               error:error];
    return data && [data writeToURL:self.journal options:NSDataWritingAtomic error:error];
}
- (void)finish:(NSDictionary *)receipt error:(NSError *)error {
    NSError *writeError = nil;
    if (error)
        self.state[@"Failure"] = error.localizedDescription;
    if (receipt)
        self.state[@"Receipt"] = receipt;
    if (error)
        [self.progressUI
            updateMode:@"failed"
              fraction:0
               message:@"Setup couldn’t finish. Check Session Details in the Light Click app before trying again."
            completion:nil];
    if (self.state)
        [self savePhase:error ? @"failed" : @"prepared" error:&writeError];
    [self releaseSupportMedia:^(NSError *ejectError) {
      self.completion(receipt, error ?: writeError ?: ejectError);
    }];
}
- (void)releaseSupportMedia:(void (^)(NSError *))completion {
    if (!self.supportInserted) {
        completion(nil);
        return;
    }
    // macOS can retain PREVENT MEDIUM REMOVAL even after unmounting. Forcing
    // the tray is safe only after the verified volume is no longer mounted.
    [self.control execute:@"eject"
                arguments:@{@"id" : @"setup-support-device", @"force" : @(self.supportUnmounted)}
               completion:^(id result, NSError *error) {
                 if (!error)
                     self.supportInserted = NO;
                 completion(error);
               }];
}
- (BOOL)phase:(NSString *)phase message:(NSString *)message {
    NSError *error = nil;
    if (![self savePhase:phase error:&error]) {
        [self finish:nil error:error];
        return NO;
    }
    NSDictionary *fractions = @{
        @"preparing-utilities" : @.12,
        @"checking-environment" : @.14,
        @"extracting" : @.18,
        @"preparing" : @.25,
        @"verifying-guest" : @.42,
        @"planning-installation" : @.46
    };
    if (fractions[phase])
        [self.progressUI updateMode:@"working" fraction:[fractions[phase] doubleValue] message:message completion:nil];
    self.progress(message);
    return YES;
}
// Disk Arbitration does not automount optical volumes before a GUI session.
// Only request a read-only mount of the uniquely named support disc; stage-media
// still verifies its entire manifest and every file before executing anything.
- (void)mountHeadlessSupport:(void (^)(NSError *))completion {
    [self mountHeadlessSupport:completion deadline:NSProcessInfo.processInfo.systemUptime + 45];
}
- (void)mountHeadlessSupport:(void (^)(NSError *))completion deadline:(NSTimeInterval)deadline {
    [self.agent
        runExecutable:@"/usr/sbin/diskutil"
            arguments:@[ @"list", @"-plist" ]
              timeout:20
           completion:^(NSDictionary *result, NSError *failure) {
             if (failure) {
                 completion(failure);
                 return;
             }
             VIMSupportDiscLookup *lookup =
                 [VIMGuestPreparationChecks supportDiscInDiskList:result
                                                         mayRetry:NSProcessInfo.processInfo.systemUptime < deadline];
             if (lookup.refusal) {
                 completion(lookup.refusal);
                 return;
             }
             NSString *identifier = lookup.identifier;
             if (!identifier) {
                 // Insertion is acknowledged before the guest's asynchronous CD/HFS
                 // probe publishes its partition label. Retry discovery only, never
                 // repeat a mount with an uncertain outcome.
                 dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                   [self mountHeadlessSupport:completion deadline:deadline];
                 });
                 return;
             }
             [self.agent
                 runExecutable:@"/usr/sbin/diskutil"
                     arguments:@[ @"info", @"-plist", identifier ]
                       timeout:15
                    completion:^(NSDictionary *reply, NSError *issue) {
                      NSError *problem = issue ?: [VIMGuestPreparationChecks refusalOfSupportDiscInfo:reply];
                      if (problem) {
                          completion(problem);
                          return;
                      }
                      [self.agent
                          runExecutable:@"/usr/sbin/diskutil"
                              arguments:@[ @"mount", @"readOnly", identifier ]
                                timeout:30
                             completion:^(NSDictionary *mounted, NSError *error) {
                               completion(error ?: [VIMGuestPreparationChecks refusalOfSupportDiscMount:mounted]);
                             }];
                    }];
           }];
}
- (void)start {
    NSAssert(NSThread.isMainThread, @"Guest preparation is main-thread owned");
    NSDictionary *report = self.initialReport;
    NSString *guest = report[@"Guest"];
    NSError *refusal = [VIMGuestPreparationChecks refusalOfInitialReport:report
                                                  allowingHeadlessRepair:self.headlessRepair];
    if (refusal) {
        self.completion(nil, refusal);
        return;
    }
    NSURL *payloads = [self.runtime URLByAppendingPathComponent:@"GuestPayloads"];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSError *error = nil;
    if (![fm createDirectoryAtURL:self.journal.URLByDeletingLastPathComponent
            withIntermediateDirectories:YES
                             attributes:nil
                                  error:&error]) {
        self.completion(nil, error);
        return;
    }
    if ([fm fileExistsAtPath:self.journal.path]) {
        NSURL *history =
            [self.journal.URLByDeletingLastPathComponent URLByAppendingPathComponent:@"GuestPreparationHistory"];
        if (![fm createDirectoryAtURL:history withIntermediateDirectories:YES attributes:nil error:&error] ||
            ![fm copyItemAtURL:self.journal
                         toURL:[history URLByAppendingPathComponent:[NSUUID.UUID.UUIDString
                                                                        stringByAppendingString:@".plist"]]
                         error:&error]) {
            self.completion(nil, error);
            return;
        }
    }
    self.state = [@{
        @"FormatVersion" : @1,
        @"Attempt" : NSUUID.UUID.UUIDString,
        @"HeadlessUpdateRepair" : @(self.headlessRepair),
        @"InitialGuestReport" : report,
        @"Installed" : @NO
    } mutableCopy];
    if (![self phase:@"transferring" message:@"Making guest setup files available…"])
        return;
    self.transferStarted = NSProcessInfo.processInfo.systemUptime;
    NSURL *tools = VIMGuestFileURL(@"GuestTools");
    NSURL *media = [payloads URLByAppendingPathComponent:[guest stringByAppendingString:@".iso"]];
    if (![fm fileExistsAtPath:media.path]) {
        NSString *message = @"This app’s guest support disc is incomplete. Reinstall the app and try again.";
        [self finish:nil
               error:[NSError errorWithDomain:@"VirtualIntelMac.GuestPreparation"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey : message}]];
        return;
    }
    [self.control
           execute:@"blockdev-change-medium"
         arguments:@{
             @"id" : @"setup-support-device",
             @"filename" : media.path,
             @"format" : @"raw",
             @"read-only-mode" : @"read-only"
         }
        completion:^(id inserted, NSError *insertError) {
          if (insertError) {
              [self finish:nil error:insertError];
              return;
          }
          self.supportInserted = YES;
          [self.agent
              stageInstallationFiles:@{
                  @"guest-macho" : [tools URLByAppendingPathComponent:@"guest-macho"],
                  @"guest-progress" : [tools URLByAppendingPathComponent:@"guest-progress"],
                  @"SupportIcon.png" :
                      [tools URLByAppendingPathComponent:[guest stringByAppendingString:@"-support-icon.png"]]
              }
                            progress:nil
                          completion:^(NSDictionary *bootstrap, NSError *bootstrapError) {
                            if (bootstrapError) {
                                [self finish:nil error:bootstrapError];
                                return;
                            }
                            NSString *directory = bootstrap[@"Directory"];
                            self.state[@"GuestStagingDirectory"] = directory;
                            void (^continueSetup)(VIMGuestProgress *, NSError *) = ^(VIMGuestProgress *progressUI,
                                                                                     NSError *uiError) {
                              if (uiError) {
                                  [self finish:nil error:uiError];
                                  return;
                              }
                              self.progressUI = progressUI;
                              self.state[@"GuestProgress"] = progressUI.receipt;
                              self.progress(@"Copying and verifying guest setup files…");
                              [progressUI updateMode:@"working"
                                            fraction:.05
                                             message:@"Copying and verifying guest support files…"
                                          completion:nil];
                              [self.agent
                                  runExecutable:[directory stringByAppendingPathComponent:@"guest-macho"]
                                      arguments:@[ @"stage-media", guest, directory ]
                                        timeout:0
                                     completion:^(NSDictionary *copied, NSError *failure) {
                                       NSDictionary *transfer = [VIMGuestPreparationChecks JSONFromCommand:copied];
                                       if (failure) {
                                           if (failure.userInfo[@"GuestStagingDirectory"])
                                               self.state[@"GuestStagingDirectory"] =
                                                   failure.userInfo[@"GuestStagingDirectory"];
                                           [self finish:nil error:failure];
                                           return;
                                       }
                                       NSError *staging = [VIMGuestPreparationChecks refusalOfStaging:copied
                                                                                            directory:directory];
                                       if (staging) {
                                           [self finish:nil error:staging];
                                           return;
                                       }
                                       self.state[@"Transfer"] = transfer;
                                       self.state[@"GuestStagingDirectory"] = transfer[@"Directory"];
                                       self.state[@"TransferSeconds"] =
                                           @(NSProcessInfo.processInfo.systemUptime - self.transferStarted);
                                       self.archiveFilename = transfer[@"Archive"];
                                       NSError *copy = [VIMGuestPreparationChecks refusalOfStagedCopy:transfer];
                                       if (copy) {
                                           [self finish:nil error:copy];
                                           return;
                                       }
                                       NSString *device = transfer[@"MediaDevice"];
                                       // Tell guest Disk Arbitration first. A forced host-only tray removal
                                       // can leave the now-invalid mounted volume visible in Finder.
                                       [self.agent runExecutable:@"/usr/sbin/diskutil"
                                                       arguments:@[ @"unmount", device ]
                                                         timeout:60
                                                      completion:^(NSDictionary *unmounted, NSError *unmountError) {
                                                        self.state[@"SupportUnmountResult"] = [VIMGuestPreparationChecks
                                                            unmountEvidenceFromCommand:unmounted];
                                                        NSError *held = unmountError
                                                                            ?: [VIMGuestPreparationChecks
                                                                                   refusalOfUnmount:unmounted];
                                                        if (held) {
                                                            [self finish:nil error:held];
                                                            return;
                                                        }
                                                        self.supportUnmounted = YES;
                                                        [self releaseSupportMedia:^(NSError *ejectError) {
                                                          if (ejectError) {
                                                              [self finish:nil error:ejectError];
                                                              return;
                                                          }
                                                          [self extractInDirectory:transfer[@"Directory"]];
                                                        }];
                                                      }];
                                     }];
                            };
                            // An update can replace framebuffer support before WindowServer starts.
                            // A previously verified update repair reports progress in the host app;
                            // opening a guest AppKit window here would deadlock on WindowServer.
                            if (self.headlessRepair)
                                [self mountHeadlessSupport:^(NSError *mountError) {
                                  continueSetup(nil, mountError);
                                }];
                            else
                                [VIMGuestProgress startWithAgent:self.agent staging:directory completion:continueSetup];
                          }];
        }];
}
- (void)extractInDirectory:(NSString *)directory {
    if (![self phase:@"preparing-utilities" message:@"Preparing guest setup utilities…"])
        return;
    NSString *prepare = [directory stringByAppendingPathComponent:@"guest-prepare"],
             *patch = [directory stringByAppendingPathComponent:@"guest-image-patch"];
    [self.agent
        runExecutable:@"/bin/chmod"
            arguments:@[
                @"0700", prepare, patch, [directory stringByAppendingPathComponent:@"guest-install"],
                [directory stringByAppendingPathComponent:@"codesign_allocate"]
            ]
              timeout:15
           completion:^(NSDictionary *mode, NSError *error) {
             NSError *refused = error ?: [VIMGuestPreparationChecks refusalOfUtilities:mode];
             if (refused) {
                 [self finish:nil error:refused];
                 return;
             }
             if (![self phase:@"checking-environment" message:@"Checking guest setup requirements…"])
                 return;
             [self.agent
                 runExecutable:[directory stringByAppendingPathComponent:@"guest-install"]
                     arguments:@[ @"--check-environment" ]
                       timeout:30
                    completion:^(NSDictionary *checked, NSError *checkError) {
                      NSString *diagnostic = [VIMGuestPreparationChecks logFromCommand:checked nonText:nil];
                      if (diagnostic)
                          self.state[@"AdmissionLog"] = diagnostic;
                      NSError *ineligible = checkError
                                                ?: [VIMGuestPreparationChecks refusalOfEnvironment:checked
                                                                                            report:self.initialReport];
                      if (ineligible) {
                          [self finish:nil error:ineligible];
                          return;
                      }
                      NSDictionary *admission = [VIMGuestPreparationChecks JSONFromCommand:checked];
                      self.state[@"Admission"] = admission;
                      if (![self phase:@"extracting" message:@"Unpacking guest setup files…"])
                          return;
                      NSString *extracted = [directory stringByAppendingPathComponent:@"Extracted"];
                      [self.agent
                          runExecutable:prepare
                              arguments:@[
                                  @"--extract", [directory stringByAppendingPathComponent:self.archiveFilename],
                                  extracted
                              ]
                                timeout:0
                             completion:^(NSDictionary *result, NSError *extractError) {
                               NSString *log = [VIMGuestPreparationChecks logFromCommand:result
                                                                                 nonText:@"Non-text extraction output"];
                               if (log)
                                   self.state[@"ExtractionLog"] = log;
                               NSDictionary *receipt = [VIMGuestPreparationChecks JSONFromCommand:result];
                               NSString *payload = [extracted stringByAppendingPathComponent:@"payload"];
                               if (receipt)
                                   self.state[@"Extraction"] = receipt;
                               NSError *unextracted = extractError
                                                          ?: [VIMGuestPreparationChecks refusalOfExtraction:result
                                                                                                    payload:payload];
                               if (unextracted) {
                                   [self finish:nil error:unextracted];
                                   return;
                               }
                               if (![self phase:@"preparing" message:@"Preparing this macOS build’s graphics files…"])
                                   return;
                               [self.agent
                                   runExecutable:prepare
                                       arguments:@[ @"/", payload, directory ]
                                         timeout:0
                                      completion:^(NSDictionary *prepared, NSError *prepareError) {
                                        NSString *log =
                                            [VIMGuestPreparationChecks logFromCommand:prepared
                                                                              nonText:@"Non-text preparation output"];
                                        if (log)
                                            self.state[@"PreparationLog"] = log;
                                        NSDictionary *result = [VIMGuestPreparationChecks JSONFromCommand:prepared];
                                        NSError *unprepared = prepareError
                                                                  ?: [VIMGuestPreparationChecks
                                                                         refusalOfPreparedFiles:prepared
                                                                                         report:self.initialReport];
                                        if (unprepared) {
                                            [self finish:nil error:unprepared];
                                            return;
                                        }
                                        self.state[@"Preparation"] = result;
                                        if (![self phase:@"verifying-guest" message:@"Verifying the prepared guest…"])
                                            return;
                                        NSData *status =
                                            [NSData dataWithContentsOfURL:VIMGuestFileURL(@"GuestTools/guest-status")];
                                        [self.agent
                                            collectStatusWithTool:status
                                                       completion:^(NSDictionary *report, NSError *statusError) {
                                                         NSError *changed =
                                                             statusError
                                                                 ?: [VIMGuestPreparationChecks
                                                                        refusalOfLaterReport:report
                                                                                      report:self.initialReport];
                                                         if (changed) {
                                                             [self finish:nil error:changed];
                                                             return;
                                                         }
                                                         if (![self phase:@"planning-installation"
                                                                  message:@"Checking installation targets and "
                                                                          @"recording recovery information…"])
                                                             return;
                                                         NSString *journal =
                                                             [directory stringByAppendingPathComponent:
                                                                            @"InstallTransaction.plist"];
                                                         [self.agent
                                                             runExecutable:[directory stringByAppendingPathComponent:
                                                                                          @"guest-install"]
                                                                 arguments:@[ @"--plan", @"/", payload, journal ]
                                                                   timeout:0
                                                                completion:^(NSDictionary *planned,
                                                                             NSError *planError) {
                                                                  NSString *log = [VIMGuestPreparationChecks
                                                                      logFromCommand:planned
                                                                             nonText:@"Non-text planning output"];
                                                                  if (log)
                                                                      self.state[@"PlanningLog"] = log;
                                                                  NSDictionary *plan = [VIMGuestPreparationChecks
                                                                      JSONFromCommand:planned];
                                                                  NSError *unplanned =
                                                                      planError
                                                                          ?: [VIMGuestPreparationChecks
                                                                                 refusalOfPlan:planned
                                                                                        report:self.initialReport];
                                                                  if (unplanned) {
                                                                      [self finish:nil error:unplanned];
                                                                      return;
                                                                  }
                                                                  self.state[@"InstallationPlan"] = plan;
                                                                  NSError *untracked = [VIMGuestPreparationChecks
                                                                      refusalOfTransaction:plan];
                                                                  if (untracked) {
                                                                      [self finish:nil error:untracked];
                                                                      return;
                                                                  }
                                                                  [self finish:@{
                                                                      @"Prepared" : @YES,
                                                                      @"Planned" : @YES,
                                                                      @"Installed" : @NO,
                                                                      @"GuestReport" : report,
                                                                      @"PayloadDirectory" : payload,
                                                                      @"TransactionJournal" : journal,
                                                                      @"TransactionID" : plan[@"TransactionID"],
                                                                      @"GuestProgress" : self.progressUI.receipt ?: @{}
                                                                  }
                                                                         error:nil];
                                                                }];
                                                       }];
                                      }];
                             }];
                    }];
           }];
}
@end
