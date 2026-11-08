// Disposable Mavericks guest only; invoke AFTER export completion, outside export timing.
// Fixed generated input/export.mov only. Structural checks do not certify lossy fidelity.
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CVImageBuffer.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <CommonCrypto/CommonDigest.h>
#import <sys/stat.h>
#import <sys/utsname.h>
#import <mach/mach_time.h>
#import <fcntl.h>
#import <unistd.h>
#import <signal.h>
#import <math.h>

static const size_t jsonLimit=512*1024, pixelBytes=320*180*4;
static double deadline;
static double now(void){mach_timebase_info_data_t info;mach_timebase_info(&info);return (double)mach_absolute_time()*info.numer/info.denom/1e9;}
static void hardTimeout(int sig){(void)sig;const char text[]="{\"result\":\"VERIFY_HARD_TIMEOUT\",\"report_complete\":false,\"outside_export_timing\":true}\n";write(STDOUT_FILENO,text,sizeof(text)-1);_exit(124);}
static void require(BOOL value,NSString *reason){if(!value)@throw reason;if(now()>=deadline)@throw @"verification soft deadline";}
static NSString *boundedDescription(id value){NSString *text=[value description]?:@"unspecified";return [text substringToIndex:MIN(text.length,1024)];}
static NSString *hex(const unsigned char *bytes,size_t count){NSMutableString *s=[NSMutableString string];for(size_t i=0;i<count;i++)[s appendFormat:@"%02x",bytes[i]];return s;}
static NSString *shaBytes(const void *bytes,size_t count){unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256(bytes,(CC_LONG)count,digest);return hex(digest,sizeof(digest));}
// Diagnostics only. Never enumerate or serialize the full extension dictionary.
static NSDictionary *colorScalar(CFTypeRef value){
    if(!value)return @{@"present":@NO};
    if(CFGetTypeID(value)==CFStringGetTypeID()){
        NSString *text=(__bridge NSString *)value;BOOL truncated=text.length>128;
        return @{@"present":@YES,@"type":@"string",@"value":[text substringToIndex:MIN(text.length,128)],@"truncated":@(truncated)};
    }
    if(CFGetTypeID(value)==CFBooleanGetTypeID())return @{@"present":@YES,@"type":@"boolean",@"value":@([(__bridge NSNumber *)value boolValue])};
    if(CFGetTypeID(value)==CFNumberGetTypeID()){
        double number=[(__bridge NSNumber *)value doubleValue];
        if(isfinite(number))return @{@"present":@YES,@"type":@"number",@"value":(__bridge NSNumber *)value};
        return @{@"present":@YES,@"type":@"number",@"nonfinite":@YES};
    }
    return @{@"present":@YES,@"unsupported_nonscalar":@YES};
}
static NSDictionary *formatColorDiagnostics(CMFormatDescriptionRef format){
    CFDictionaryRef extensions=CMFormatDescriptionGetExtensions(format);
    BOOL available=extensions && CFGetTypeID(extensions)==CFDictionaryGetTypeID();
    // The first three CM color names map to these actual old CoreVideo keys;
    // their newer standalone CM exports do not exist on Mavericks.
    const CFStringRef keys[]={kCVImageBufferColorPrimariesKey,kCVImageBufferTransferFunctionKey,kCVImageBufferYCbCrMatrixKey,kCMFormatDescriptionExtension_FullRangeVideo};
    NSArray *names=@[@"primaries",@"transfer_function",@"ycbcr_matrix",@"full_range_video"];
    NSMutableDictionary *result=[NSMutableDictionary dictionaryWithObject:@(available) forKey:@"extensions_available"];
    for(unsigned i=0;i<4;i++)result[names[i]]=colorScalar(available?CFDictionaryGetValue(extensions,keys[i]):NULL);
    return result;
}
static NSDictionary *imageColorDiagnostics(CGImageRef image){
    CGColorSpaceRef space=CGImageGetColorSpace(image);if(!space)return @{@"available":@NO};
    NSMutableDictionary *result=[NSMutableDictionary dictionaryWithObjectsAndKeys:@YES,@"available",@(CGColorSpaceGetModel(space)),@"model",nil];
    CFStringRef name=CGColorSpaceCopyName(space);result[@"name"]=colorScalar(name);if(name)CFRelease(name);
    // Public10.5 API with an actual Mavericks export. Hash only; never export ICC bytes.
    CFDataRef profile=CGColorSpaceCopyICCProfile(space);result[@"icc_available"]=@(profile!=NULL);
    if(profile){
        CFIndex bytes=CFDataGetLength(profile);result[@"icc_bytes"]=@(bytes);
        if(bytes>0 && bytes<=1024*1024){result[@"icc_sha256"]=shaBytes(CFDataGetBytePtr(profile),(size_t)bytes);result[@"icc_hashed"]=@YES;}
        else{result[@"icc_hashed"]=@NO;result[@"icc_hash_skipped"]=@"empty or over1MiB diagnostic budget";}
        CFRelease(profile);
    }
    return result;
}
static BOOL validMediaFile(mode_t mode,uid_t owner,uid_t current,uint64_t links,uint64_t bytes,BOOL source){
    return S_ISREG(mode) && current>0 && owner==current && links==1 && (source ? bytes==58747744ULL : bytes>0 && bytes<=512ULL*1024*1024);
}
static BOOL sampleBudget(uint64_t used,uint64_t count,uint64_t buffers){return buffers<=4096 && used<=240 && count<=240-used;}
static BOOL frameTime(CMTime time,int frame){return CMTIME_IS_NUMERIC(time) && time.timescale>0 && time.epoch==0 && (__int128)time.value*30==(__int128)frame*time.timescale;}
static BOOL endAtEight(CMTime pts,CMTime duration){return CMTIME_IS_NUMERIC(pts) && CMTIME_IS_NUMERIC(duration) && pts.timescale>0 && duration.timescale>0 && pts.epoch==0 && duration.epoch==0 && (__int128)pts.value*duration.timescale+(__int128)duration.value*pts.timescale==(__int128)8*pts.timescale*duration.timescale;}
static NSDictionary *timeJSON(CMTime t){return @{@"value":@(t.value),@"timescale":@(t.timescale),@"flags":@(t.flags),@"epoch":@(t.epoch)};}
static BOOL stableStat(const struct stat *a,const struct stat *b){return a->st_dev==b->st_dev && a->st_ino==b->st_ino && a->st_size==b->st_size && a->st_uid==b->st_uid && a->st_mode==b->st_mode && a->st_nlink==b->st_nlink && a->st_mtimespec.tv_sec==b->st_mtimespec.tv_sec && a->st_mtimespec.tv_nsec==b->st_mtimespec.tv_nsec && a->st_ctimespec.tv_sec==b->st_ctimespec.tv_sec && a->st_ctimespec.tv_nsec==b->st_ctimespec.tv_nsec;}
static NSDictionary *statJSON(struct stat s){return @{@"device":@((uint64_t)s.st_dev),@"inode":@(s.st_ino),@"bytes":@(s.st_size),@"uid":@(s.st_uid),@"mtime_seconds":@(s.st_mtimespec.tv_sec),@"mtime_nanoseconds":@(s.st_mtimespec.tv_nsec),@"ctime_seconds":@(s.st_ctimespec.tv_sec),@"ctime_nanoseconds":@(s.st_ctimespec.tv_nsec)};}
static BOOL fixture(NSString *directory,struct stat *out){
    NSRegularExpression *pattern=[NSRegularExpression regularExpressionWithPattern:@"\\A/private/var/tmp/LightClickFCPFixture\\.[A-Za-z0-9_-]{6,16}\\z" options:0 error:NULL];
    if([pattern numberOfMatchesInString:directory options:0 range:NSMakeRange(0,directory.length)]!=1)return NO;
    struct stat s;char canonical[PATH_MAX];const char *path=directory.fileSystemRepresentation;
    if(!realpath(path,canonical) || strcmp(path,canonical) || lstat(path,&s) || !S_ISDIR(s.st_mode) || s.st_uid!=getuid() || (s.st_mode&0777)!=0700)return NO;
    if(out)*out=s;return YES;
}
static int openMedia(NSString *path,BOOL source,struct stat *initial){
    char canonical[PATH_MAX];require(realpath(path.fileSystemRepresentation,canonical) && !strcmp(canonical,path.fileSystemRepresentation),@"media path not canonical");
    int fd=open(path.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_NONBLOCK);require(fd>=0,@"media open failed");
    if(fstat(fd,initial) || !validMediaFile(initial->st_mode,initial->st_uid,getuid(),initial->st_nlink,(uint64_t)initial->st_size,source)){close(fd);@throw @"media file identity/size outside contract";}return fd;
}
static void verifyStable(int fd,NSString *path,const struct stat *initial){struct stat a,b;char canonical[PATH_MAX];require(!fstat(fd,&a) && !lstat(path.fileSystemRepresentation,&b) && stableStat(initial,&a) && stableStat(initial,&b) && realpath(path.fileSystemRepresentation,canonical) && !strcmp(canonical,path.fileSystemRepresentation),@"media identity/size/time changed during verification");}
static NSString *shaFile(int fd,const struct stat *initial){
    require(lseek(fd,0,SEEK_SET)==0,@"media seek failed");CC_SHA256_CTX context;CC_SHA256_Init(&context);unsigned char bytes[65536];uint64_t total=0;
    for(;;){ssize_t count=read(fd,bytes,sizeof(bytes));if(count<0 && errno==EINTR)continue;require(count>=0,@"media hash read failed");if(!count)break;total+=(uint64_t)count;require(total<=(uint64_t)initial->st_size,@"media grew while hashing");CC_SHA256_Update(&context,bytes,(CC_LONG)count);}
    require(total==(uint64_t)initial->st_size,@"media hash short read");unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256_Final(digest,&context);return hex(digest,sizeof(digest));
}
static void loadKeys(id object,NSArray *keys){
    dispatch_semaphore_t done=dispatch_semaphore_create(0);dispatch_retain(done);
    [object loadValuesAsynchronouslyForKeys:keys completionHandler:^{dispatch_semaphore_signal(done);dispatch_release(done);}];
    double left=fmin(10,fmax(0,deadline-now()));long waited=dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,(int64_t)(left*NSEC_PER_SEC)));dispatch_release(done);
    require(waited==0,@"AVFoundation metadata load timed out");
    for(NSString *key in keys){NSError *error=nil;require([object statusOfValueForKey:key error:&error]==AVKeyValueStatusLoaded,[NSString stringWithFormat:@"metadata %@ unavailable: %@",key,boundedDescription(error)]);}
}
static NSString *fourCC(FourCharCode code){unsigned char bytes[4]={(code>>24)&255,(code>>16)&255,(code>>8)&255,code&255};for(int i=0;i<4;i++)if(bytes[i]<32 || bytes[i]>126)return [NSString stringWithFormat:@"0x%08x",(unsigned)code];return [[[NSString alloc]initWithBytes:bytes length:4 encoding:NSASCIIStringEncoding]autorelease];}
typedef struct {CMTime pts,duration,dts;} Timing;
static int compareTiming(const void *a,const void *b){return (int)CMTimeCompare(((const Timing *)a)->pts,((const Timing *)b)->pts);}
static NSDictionary *readSamples(AVURLAsset *asset,AVAssetTrack *track){
    NSError *error=nil;AVAssetReader *reader=[[[AVAssetReader alloc]initWithAsset:asset error:&error]autorelease];require(reader!=nil,[NSString stringWithFormat:@"reader unavailable: %@",boundedDescription(error)]);
    AVAssetReaderTrackOutput *output=[[[AVAssetReaderTrackOutput alloc]initWithTrack:track outputSettings:nil]autorelease];require(output!=nil,@"compressed track output unavailable");output.alwaysCopiesSampleData=NO;require([reader canAddOutput:output],@"compressed output not admitted");[reader addOutput:output];require([reader startReading],@"compressed reader did not start");
    Timing times[240];uint64_t used=0,buffers=0,markers=0;NSMutableArray *sampleRows=[NSMutableArray array];
    @try{
        for(;;){require(now()<deadline,@"compressed sample deadline");CMSampleBufferRef buffer=[output copyNextSampleBuffer];if(!buffer)break;
            @try{
                CMItemCount count=CMSampleBufferGetNumSamples(buffer);buffers++;require(count>=0 && sampleBudget(used,(uint64_t)count,buffers),@"video sample/buffer budget exceeded");if(!count)markers++;
                for(CMItemIndex i=0;i<count;i++){
                    CMSampleTimingInfo timing;require(CMSampleBufferGetSampleTimingInfo(buffer,i,&timing)==noErr,@"per-sample compressed timing unavailable");
                    times[used++]=(Timing){timing.presentationTimeStamp,timing.duration,timing.decodeTimeStamp};
                }
            }@finally{CFRelease(buffer);}
        }
        qsort(times,(size_t)used,sizeof(*times),compareTiming);
        for(unsigned i=0;i<used;i++){[sampleRows addObject:@{@"presentation":timeJSON(times[i].pts),@"duration":timeJSON(times[i].duration),@"decode":timeJSON(times[i].dts)}];}
        BOOL ptsOK=used==240,durationsOK=used==240;for(unsigned i=0;i<used;i++){ptsOK&=frameTime(times[i].pts,i);durationsOK&=frameTime(times[i].duration,1);}
        return @{@"sample_count":@(used),@"buffer_count":@(buffers),@"zero_sample_markers":@(markers),@"reader_status":@(reader.status),@"reader_error":boundedDescription(reader.error),@"presentation_grid_exact":@(ptsOK),@"all_durations_exact_1_30":@(durationsOK),@"last_sample_end_exact8":@(used>0 && endAtEight(times[used-1].pts,times[used-1].duration)),@"samples_sorted_by_pts":sampleRows};
    }@finally{if(reader.status==AVAssetReaderStatusReading)[reader cancelReading];}
}
static NSDictionary *describeAsset(AVURLAsset *asset,AVAssetTrack **videoOut){
    loadKeys(asset,@[@"tracks",@"duration"]);NSArray *video=[asset tracksWithMediaType:AVMediaTypeVideo],*audio=[asset tracksWithMediaType:AVMediaTypeAudio];
    require(video.count==1,@"expected exactlyone video track");require(audio.count<=8,@"audio track metadata budget exceeded");AVAssetTrack *track=video[0];loadKeys(track,@[@"formatDescriptions",@"naturalSize",@"preferredTransform",@"nominalFrameRate",@"timeRange"]);
    require(track.formatDescriptions.count==1,@"expected exactlyone video format description");CMFormatDescriptionRef format=(CMFormatDescriptionRef)track.formatDescriptions[0];FourCharCode codec=CMFormatDescriptionGetMediaSubType(format);CMVideoDimensions dimensions=CMVideoFormatDescriptionGetDimensions(format);CGSize presentation=CMVideoFormatDescriptionGetPresentationDimensions(format,true,true);
    NSMutableArray *audioRows=[NSMutableArray array];for(AVAssetTrack *a in audio){loadKeys(a,@[@"formatDescriptions",@"timeRange"]);require(a.formatDescriptions.count<=8,@"audio format description budget");NSMutableArray *codecs=[NSMutableArray array];for(id desc in a.formatDescriptions)[codecs addObject:fourCC(CMFormatDescriptionGetMediaSubType((CMFormatDescriptionRef)desc))];[audioRows addObject:@{@"track_id":@(a.trackID),@"codecs":codecs,@"start":timeJSON(a.timeRange.start),@"duration":timeJSON(a.timeRange.duration)}];}
    NSDictionary *result=@{@"codec":fourCC(codec),@"color_extensions":formatColorDiagnostics(format),@"width":@(dimensions.width),@"height":@(dimensions.height),@"presentation_width":@(presentation.width),@"presentation_height":@(presentation.height),@"presentation_uses_pixel_aspect_ratio":@YES,@"presentation_uses_clean_aperture":@YES,@"natural_width":@(track.naturalSize.width),@"natural_height":@(track.naturalSize.height),@"nominal_frame_rate":@(track.nominalFrameRate),@"asset_duration":timeJSON(asset.duration),@"track_start":timeJSON(track.timeRange.start),@"track_duration":timeJSON(track.timeRange.duration),@"transform_identity":@(CGAffineTransformIsIdentity(track.preferredTransform)),@"audio_tracks":audioRows};
    *videoOut=track;return result;
}
static NSData *pngData(CGImageRef image){CFMutableDataRef data=CFDataCreateMutable(NULL,0);CGImageDestinationRef destination=data?CGImageDestinationCreateWithData(data,CFSTR("public.png"),1,NULL):NULL;if(!destination){if(data)CFRelease(data);return nil;}CGImageDestinationAddImage(destination,image,NULL);BOOL done=CGImageDestinationFinalize(destination);CFRelease(destination);NSData *result=done && CFDataGetLength(data)<=262144?[NSData dataWithData:(__bridge NSData *)data]:nil;CFRelease(data);return result;}
static NSDictionary *thumbnail(AVAssetImageGenerator *generator,int frame,unsigned char *pixels,NSData **png){
    NSError *error=nil;CMTime actual=kCMTimeInvalid;CGImageRef image=[generator copyCGImageAtTime:CMTimeMake(frame,30) actualTime:&actual error:&error];require(image!=NULL,[NSString stringWithFormat:@"thumbnail frame%d failed: %@",frame,boundedDescription(error)]);
    CGColorSpaceRef space=NULL;CGContextRef context=NULL;CGImageRef normalized=NULL;NSDictionary *result=nil;
    @try{
        require(frameTime(actual,frame),@"thumbnail actual timestamp is not requested frame");require(CGImageGetWidth(image)==320 && CGImageGetHeight(image)==180,@"thumbnail dimensions not320x180");
        space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);context=space?CGBitmapContextCreate(pixels,320,180,8,320*4,space,kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big):NULL;require(context!=NULL,@"sRGB thumbnail bitmap unavailable");
        CGContextSetBlendMode(context,kCGBlendModeCopy);CGContextSetInterpolationQuality(context,kCGInterpolationHigh);CGContextDrawImage(context,CGRectMake(0,0,320,180),image);normalized=CGBitmapContextCreateImage(context);require(normalized!=NULL,@"normalized thumbnail unavailable");*png=pngData(normalized);
        result=@{@"requested_frame":@(frame),@"requested_time":timeJSON(CMTimeMake(frame,30)),@"actual_time":timeJSON(actual),@"width":@320,@"height":@180,@"decoded_image_color_space":imageColorDiagnostics(image),@"pixel_format":@"sRGB RGBA8 premultiplied; matched CoreGraphics bitmap row order",@"aperture_mode":AVAssetImageGeneratorApertureModeCleanAperture,@"rgba_sha256":shaBytes(pixels,pixelBytes),@"png_encoded":@(*png!=nil)};
    }@finally{if(normalized)CGImageRelease(normalized);if(context)CGContextRelease(context);if(space)CGColorSpaceRelease(space);CGImageRelease(image);}return result;
}
static NSDictionary *difference(const unsigned char *a,const unsigned char *b){uint64_t absolute[3]={0},squared[3]={0};unsigned maximum[3]={0};BOOL alphaExact=YES;for(size_t i=0;i<320*180;i++){for(unsigned c=0;c<3;c++){unsigned d=(unsigned)abs((int)a[i*4+c]-(int)b[i*4+c]);absolute[c]+=d;squared[c]+=(uint64_t)d*d;if(d>maximum[c])maximum[c]=d;}alphaExact&=a[i*4+3]==b[i*4+3];}NSMutableArray *mae=[NSMutableArray array],*rmse=[NSMutableArray array],*peak=[NSMutableArray array];for(unsigned c=0;c<3;c++){[mae addObject:@((double)absolute[c]/(320*180))];[rmse addObject:@(sqrt((double)squared[c]/(320*180)))];[peak addObject:@(maximum[c])];}return @{@"rgb_mae":mae,@"rgb_rmse":rmse,@"rgb_max_abs":peak,@"alpha_exact":@(alphaExact),@"fidelity_qualified":@NO,@"qualification":@"Lossy H264 export requires review against generated source; no automatic pixel-error acceptance threshold."};}
int main(int argc,const char **argv){@autoreleasepool{
    if(argc!=2){fputs("usage: fcp-export-verify ownFixtureDirectory\n",stderr);return 2;}
    // BEFORE any AVFoundation invocation. This binary must never run on the host.
    struct utsname system;struct stat console;if(uname(&system) || strcmp(system.sysname,"Darwin") || strncmp(system.release,"13.",3) || getuid()==0 || geteuid()!=getuid() || stat("/dev/console",&console) || console.st_uid!=getuid()){fputs("requires disposable Darwin13 joined console user; AVFoundation not invoked\n",stderr);return 65;}
    signal(SIGALRM,hardTimeout);alarm(65);double began=now();deadline=began+60;
    NSMutableDictionary *report=[@{@"result":@"VERIFY_FAILED",@"report_complete":@NO,@"outside_export_timing":@YES,@"soft_deadline_seconds":@60,@"hard_deadline_seconds":@65,@"fidelity_qualified":@NO,@"source_expected_codec":@"apcn",@"output_expected_codec":@"avc1",@"thumbnail_aperture_mode":AVAssetImageGeneratorApertureModeCleanAperture,@"geometry_contract":@"encoded dimensions, natural size and visible presentation dimensions all1920x1080; identity track transform"}mutableCopy];int sourceFD=-1,outputFD=-1;unsigned char *sourcePixels=NULL,*outputPixels=NULL;BOOL verified=NO;
    @try{
        NSString *directory=[NSString stringWithUTF8String:argv[1]];struct stat parent,again,sourceStat,outputStat;require(directory && fixture(directory,&parent),@"fixture must be own canonical0700 generated directory");
        NSString *sourcePath=[directory stringByAppendingPathComponent:@"input-prores422.mov"],*outputPath=[directory stringByAppendingPathComponent:@"export.mov"];
        sourceFD=openMedia(sourcePath,YES,&sourceStat);outputFD=openMedia(outputPath,NO,&outputStat);report[@"source_file"]=statJSON(sourceStat);report[@"output_file"]=statJSON(outputStat);
        NSString *sourceSHA=shaFile(sourceFD,&sourceStat);report[@"source_sha256"]=sourceSHA;require([sourceSHA isEqualToString:@"62dfa5b49d5f97d954c420d315c250015d8733f47c59752d002f8b841e650211"],@"known generated source SHA mismatch");report[@"output_sha256"]=shaFile(outputFD,&outputStat);verifyStable(sourceFD,sourcePath,&sourceStat);verifyStable(outputFD,outputPath,&outputStat);
        AVURLAsset *source=[[[AVURLAsset alloc]initWithURL:[NSURL fileURLWithPath:sourcePath] options:@{AVURLAssetPreferPreciseDurationAndTimingKey:@YES}]autorelease],*output=[[[AVURLAsset alloc]initWithURL:[NSURL fileURLWithPath:outputPath] options:@{AVURLAssetPreferPreciseDurationAndTimingKey:@YES}]autorelease];AVAssetTrack *sourceTrack=nil,*outputTrack=nil;
        NSDictionary *sourceInfo=describeAsset(source,&sourceTrack),*outputInfo=describeAsset(output,&outputTrack);report[@"source_asset"]=sourceInfo;report[@"output_asset"]=outputInfo;
        require([sourceInfo[@"codec"]isEqualToString:@"apcn"] && [outputInfo[@"codec"]isEqualToString:@"avc1"],@"expected sourceapcn and outputavc1 codecs");
        for(NSDictionary *info in @[sourceInfo,outputInfo])require([info[@"width"]intValue]==1920 && [info[@"height"]intValue]==1080 && [info[@"natural_width"]doubleValue]==1920 && [info[@"natural_height"]doubleValue]==1080 && [info[@"presentation_width"]doubleValue]==1920 && [info[@"presentation_height"]doubleValue]==1080 && [info[@"transform_identity"]boolValue],@"encoded/natural/visible1920x1080 identity geometry contract failed");
        require(frameTime(source.duration,240) && frameTime(output.duration,240) && frameTime(sourceTrack.timeRange.start,0) && frameTime(outputTrack.timeRange.start,0) && frameTime(sourceTrack.timeRange.duration,240) && frameTime(outputTrack.timeRange.duration,240),@"asset/track start or duration not exact0/8seconds");
        NSDictionary *sourceSamples=readSamples(source,sourceTrack);report[@"source_samples"]=sourceSamples;NSDictionary *outputSamples=readSamples(output,outputTrack);report[@"output_samples"]=outputSamples;
        for(NSDictionary *samples in @[sourceSamples,outputSamples])require([samples[@"reader_status"]integerValue]==AVAssetReaderStatusCompleted && [samples[@"sample_count"]integerValue]==240 && [samples[@"presentation_grid_exact"]boolValue] && [samples[@"all_durations_exact_1_30"]boolValue] && [samples[@"last_sample_end_exact8"]boolValue],@"video sample timing grid/durations/end failed");
        AVAssetImageGenerator *sg=[[[AVAssetImageGenerator alloc]initWithAsset:source]autorelease],*og=[[[AVAssetImageGenerator alloc]initWithAsset:output]autorelease];for(AVAssetImageGenerator *g in @[sg,og]){g.appliesPreferredTrackTransform=NO;g.maximumSize=CGSizeMake(320,180);g.apertureMode=AVAssetImageGeneratorApertureModeCleanAperture;g.requestedTimeToleranceBefore=kCMTimeZero;g.requestedTimeToleranceAfter=kCMTimeZero;}
        sourcePixels=calloc(1,pixelBytes);outputPixels=calloc(1,pixelBytes);require(sourcePixels && outputPixels,@"thumbnail allocation failed");NSMutableArray *comparisons=[NSMutableArray array],*pngs=[NSMutableArray array];report[@"thumbnails"]=comparisons;
        for(NSNumber *index in @[@0,@30,@120,@239]){NSData *sp=nil,*op=nil;NSDictionary *st=thumbnail(sg,index.intValue,sourcePixels,&sp),*ot=thumbnail(og,index.intValue,outputPixels,&op);[comparisons addObject:@{@"frame":index,@"source":st,@"output":ot,@"difference":difference(sourcePixels,outputPixels)}];if(sp && op)[pngs addObject:@{@"frame":index,@"source_png_base64":[sp base64EncodedStringWithOptions:0],@"output_png_base64":[op base64EncodedStringWithOptions:0]}];}
        verifyStable(sourceFD,sourcePath,&sourceStat);verifyStable(outputFD,outputPath,&outputStat);require(fixture(directory,&again) && again.st_dev==parent.st_dev && again.st_ino==parent.st_ino,@"fixture identity changed during verification");
        report[@"inline_pngs"]=pngs;report[@"inline_png_pairs_available"]=@(pngs.count);report[@"inline_png_pairs_expected"]=@4;report[@"files_stable_after_verification"]=@YES;report[@"media_structure_qualified"]=@YES;report[@"result"]=@"MEDIA_STRUCTURE_VALID_FIDELITY_REQUIRES_REVIEW";report[@"report_complete"]=@YES;verified=YES;
    }@catch(id error){report[@"error"]=boundedDescription(error);}
    if(sourceFD>=0)close(sourceFD);if(outputFD>=0)close(outputFD);free(sourcePixels);free(outputPixels);
    report[@"elapsed_seconds"]=@(now()-began);report[@"inline_pngs_exported"]=@(report[@"inline_pngs"]!=nil);NSData *json=[NSJSONSerialization dataWithJSONObject:report options:0 error:NULL];
    if(!json || json.length>jsonLimit){[report removeObjectForKey:@"inline_pngs"];report[@"inline_pngs_exported"]=@NO;report[@"inline_pngs_not_exported_reason"]=@"complete JSON exceeds512KiB budget or serialization failed";json=[NSJSONSerialization dataWithJSONObject:report options:0 error:NULL];}
    if(!json || json.length>jsonLimit){for(NSString *key in @[@"source_samples",@"output_samples"]){id samples=report[key];if([samples isKindOfClass:[NSDictionary class]]){NSMutableDictionary *small=[samples mutableCopy];[small removeObjectForKey:@"samples_sorted_by_pts"];report[key]=small;}}report[@"result"]=@"REPORT_BUDGET_FAILURE";report[@"report_complete"]=@NO;verified=NO;json=[NSJSONSerialization dataWithJSONObject:report options:0 error:NULL];}
    alarm(0);if(json && json.length<=jsonLimit){fwrite(json.bytes,1,json.length,stdout);fputc('\n',stdout);}else{fputs("{\"result\":\"REPORT_ENCODING_FAILED\",\"report_complete\":false}\n",stdout);return 1;}return verified?0:1;
}}
