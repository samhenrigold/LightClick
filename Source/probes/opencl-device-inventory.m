// Query-only guest OpenCL inventory, x86_64 macOS10.9+. No contexts/kernels/UI.
// Public SDK OpenCL/cl.h: clGetPlatformIDs/GetPlatformInfo/GetDeviceIDs/GetDeviceInfo.
// Compile only on host; run only inside disposable guest with an outer >=12s deadline.
#import <Foundation/Foundation.h>
#import <OpenCL/opencl.h>
#import <mach/mach_time.h>
#import <signal.h>

static double deadline;
static BOOL timedOut, truncated, enumerationFailed;
static double now(void) {
    mach_timebase_info_data_t info; mach_timebase_info(&info);
    return (double)mach_absolute_time()*info.numer/info.denom/1e9;
}
static BOOL ready(void) { if (now() >= deadline) { timedOut = YES; return NO; } return YES; }
static void error(NSMutableArray *errors, NSString *name, cl_int code) {
    [errors addObject:@{@"query":name,@"status":@(code)}];
}
static id text(cl_platform_id platform, cl_device_id device, cl_uint key, NSString *name, NSMutableArray *errors) {
    if (!ready()) return [NSNull null];
    size_t count = 0;
    cl_int status = device ? clGetDeviceInfo(device,key,0,NULL,&count) : clGetPlatformInfo(platform,key,0,NULL,&count);
    if (status != CL_SUCCESS) { error(errors,name,status); return [NSNull null]; }
    if (!count || count > 32768) { error(errors,[name stringByAppendingString:@":sizeBudget"],CL_INVALID_VALUE); return [NSNull null]; }
    char *buffer = calloc(count+1,1);
    if (!buffer) { error(errors,name,CL_OUT_OF_HOST_MEMORY); return [NSNull null]; }
    status = device ? clGetDeviceInfo(device,key,count,buffer,NULL) : clGetPlatformInfo(platform,key,count,buffer,NULL);
    id result = [NSNull null];
    if (status == CL_SUCCESS) {
        NSString *string = [[NSString alloc] initWithBytes:buffer length:strnlen(buffer,count) encoding:NSUTF8StringEncoding];
        if (string) result = string;
        else error(errors,[name stringByAppendingString:@":utf8"],CL_INVALID_VALUE);
    } else error(errors,name,status);
    free(buffer); return result;
}
static id integer(cl_device_id device,cl_device_info key,size_t width,NSString *name,NSMutableArray *errors) {
    if (!ready()) return [NSNull null];
    cl_ulong value = 0;
    cl_int status = clGetDeviceInfo(device,key,width,&value,NULL);
    if (status != CL_SUCCESS) { error(errors,name,status); return [NSNull null]; }
    return [NSNumber numberWithUnsignedLongLong:value];
}
int main(int argc,const char **argv) {
    @autoreleasepool {
        (void)argv;
        if (argc != 1) { fprintf(stderr,"usage: opencl-device-inventory\n"); return 2; }
        alarm(9); deadline = now()+6;
        NSMutableDictionary *report = [@{@"result":@"INCONCLUSIVE",@"queryOnly":@YES,
            @"note":@"Device availability only; no context, kernel, FCP usability or performance qualification."} mutableCopy];
        NSMutableArray *errors = [NSMutableArray array], *platforms = [NSMutableArray array];
        cl_uint platformCount = 0;
        cl_int status = clGetPlatformIDs(0,NULL,&platformCount);
        report[@"platformEnumerationStatus"] = @(status);
        report[@"platformCount"] = @(platformCount);
        cl_uint totalDevices = 0;
        if (status == CL_SUCCESS && platformCount && ready()) {
            cl_platform_id ids[16] = {0};
            cl_uint count = MIN(platformCount,16U);
            if (platformCount > count) truncated = YES;
            status = clGetPlatformIDs(count,ids,NULL);
            if (status != CL_SUCCESS) error(errors,@"platformIDs",status);
            else for (cl_uint i=0;i<count && ready();i++) {
                NSMutableArray *platformErrors = [NSMutableArray array], *devices = [NSMutableArray array];
                NSMutableDictionary *platform = [@{@"index":@(i),@"devices":devices,@"errors":platformErrors} mutableCopy];
                platform[@"name"] = text(ids[i],NULL,CL_PLATFORM_NAME,@"name",platformErrors);
                platform[@"vendor"] = text(ids[i],NULL,CL_PLATFORM_VENDOR,@"vendor",platformErrors);
                platform[@"version"] = text(ids[i],NULL,CL_PLATFORM_VERSION,@"version",platformErrors);
                platform[@"profile"] = text(ids[i],NULL,CL_PLATFORM_PROFILE,@"profile",platformErrors);
                platform[@"extensions"] = text(ids[i],NULL,CL_PLATFORM_EXTENSIONS,@"extensions",platformErrors);
                cl_uint deviceCount = 0;
                cl_int enumeration = ready() ? clGetDeviceIDs(ids[i],CL_DEVICE_TYPE_ALL,0,NULL,&deviceCount) : CL_INVALID_OPERATION;
                platform[@"deviceEnumerationStatus"] = @(enumeration); platform[@"deviceCount"] = @(deviceCount);
                if (enumeration == CL_DEVICE_NOT_FOUND) deviceCount = 0; // Valid empty platform, not an error.
                else if (enumeration != CL_SUCCESS) { enumerationFailed = YES; error(platformErrors,@"deviceIDsCount",enumeration); }
                else if (deviceCount && ready()) {
                    cl_device_id deviceIDs[32] = {0};
                    cl_uint deviceLimit = MIN(MIN(deviceCount,32U),64U-totalDevices);
                    if (deviceCount > deviceLimit) truncated = YES;
                    if (deviceLimit) {
                        enumeration = clGetDeviceIDs(ids[i],CL_DEVICE_TYPE_ALL,deviceLimit,deviceIDs,NULL);
                        if (enumeration != CL_SUCCESS) { enumerationFailed = YES; error(platformErrors,@"deviceIDs",enumeration); }
                        else for (cl_uint j=0;j<deviceLimit && ready();j++) {
                            cl_device_id device = deviceIDs[j];
                            NSMutableArray *deviceErrors = [NSMutableArray array];
                            NSMutableDictionary *entry = [@{@"index":@(j),@"errors":deviceErrors} mutableCopy];
                            entry[@"name"] = text(NULL,device,CL_DEVICE_NAME,@"name",deviceErrors);
                            entry[@"vendor"] = text(NULL,device,CL_DEVICE_VENDOR,@"vendor",deviceErrors);
                            entry[@"deviceVersion"] = text(NULL,device,CL_DEVICE_VERSION,@"deviceVersion",deviceErrors);
                            entry[@"driverVersion"] = text(NULL,device,CL_DRIVER_VERSION,@"driverVersion",deviceErrors);
                            entry[@"openclCVersion"] = text(NULL,device,CL_DEVICE_OPENCL_C_VERSION,@"openclCVersion",deviceErrors);
                            entry[@"extensions"] = text(NULL,device,CL_DEVICE_EXTENSIONS,@"extensions",deviceErrors);
                            entry[@"typeBits"] = integer(device,CL_DEVICE_TYPE,sizeof(cl_device_type),@"typeBits",deviceErrors);
                            entry[@"maxComputeUnits"] = integer(device,CL_DEVICE_MAX_COMPUTE_UNITS,sizeof(cl_uint),@"maxComputeUnits",deviceErrors);
                            entry[@"available"] = integer(device,CL_DEVICE_AVAILABLE,sizeof(cl_bool),@"available",deviceErrors);
                            entry[@"compilerAvailable"] = integer(device,CL_DEVICE_COMPILER_AVAILABLE,sizeof(cl_bool),@"compilerAvailable",deviceErrors);
                            [devices addObject:entry]; totalDevices++;
                        }
                    }
                }
                [platforms addObject:platform];
            }
        } else if (status != CL_SUCCESS && status != -1001) error(errors,@"platformIDsCount",status); // CL_PLATFORM_NOT_FOUND_KHR.
        report[@"platforms"] = platforms; report[@"errors"] = errors;
        report[@"devicesQueried"] = @(totalDevices); report[@"truncated"] = @(truncated); report[@"deadlineExceeded"] = @(timedOut);
        if (!timedOut && !truncated && !enumerationFailed && !errors.count) report[@"result"] = @"INVENTORY_COMPLETE";
        NSError *jsonError = nil; NSData *json = [NSJSONSerialization dataWithJSONObject:report options:0 error:&jsonError];
        if (!json || json.length > 1048576) return 3;
        fwrite(json.bytes,1,json.length,stdout); putchar('\n'); alarm(0); return 0;
    }
}
