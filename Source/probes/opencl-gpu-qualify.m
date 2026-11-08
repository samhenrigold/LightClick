// Minimal disposable-guest GPU OpenCL qualification; never run on the host.
// x86_64 macOS10.9+. No CPU fallback, FCP installation, graphics/UI or filesystem writes.
// JSON-lines checkpoints preserve the selected device and API boundary if clBuildProgram aborts.
#import <Foundation/Foundation.h>
#import <OpenCL/opencl.h>
#import <signal.h>

#define COUNT 256
static const char *kernelSource =
"__kernel void lc_integer_add(__global const uint *a, __global const uint *b, __global uint *out) {\n"
"  size_t i = get_global_id(0); out[i] = a[i] + b[i];\n"
"}\n";
static void emit(NSDictionary *value) {
    NSError *error = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:value options:0 error:&error];
    if (!json || json.length > 131072) return;
    fwrite(json.bytes,1,json.length,stdout); putchar('\n'); fflush(stdout);
}
static void checkpoint(NSString *stage) { emit(@{@"event":@"begin",@"api":stage}); }
static BOOL status(NSMutableDictionary *report,NSString *api,cl_int code) {
    NSDictionary *entry = @{@"event":@"apiStatus",@"api":api,@"status":@(code)};
    [report[@"apiStatuses"] addObject:entry]; emit(entry);
    if (code != CL_SUCCESS) report[@"failedAPI"] = api;
    return code == CL_SUCCESS;
}
static id info(cl_device_id device,cl_device_info field,NSMutableArray *errors,NSString *name) {
    size_t count = 0;
    cl_int code = clGetDeviceInfo(device,field,0,NULL,&count);
    if (code != CL_SUCCESS || !count || count > 8192) {
        [errors addObject:@{@"query":name,@"status":@(code),@"bytes":@(count)}]; return [NSNull null];
    }
    char *buffer = calloc(count+1,1);
    if (!buffer) return [NSNull null];
    code = clGetDeviceInfo(device,field,count,buffer,NULL);
    NSString *value = code == CL_SUCCESS ? [[NSString alloc] initWithBytes:buffer length:strnlen(buffer,count) encoding:NSUTF8StringEncoding] : nil;
    free(buffer);
    if (!value) [errors addObject:@{@"query":name,@"status":@(code)}];
    return value ?: (id)[NSNull null];
}
static void buildLog(cl_program program,cl_device_id device,NSMutableDictionary *report) {
    size_t count = 0;
    cl_int code = clGetProgramBuildInfo(program,device,CL_PROGRAM_BUILD_LOG,0,NULL,&count);
    report[@"buildLogSizeStatus"] = @(code); report[@"buildLogBytes"] = @(count);
    if (code != CL_SUCCESS || !count) return;
    if (count > 32768) { report[@"buildLogOmittedOverBudget"] = @YES; return; }
    char *buffer = calloc(count+1,1);
    if (!buffer) return;
    code = clGetProgramBuildInfo(program,device,CL_PROGRAM_BUILD_LOG,count,buffer,NULL);
    report[@"buildLogReadStatus"] = @(code);
    if (code == CL_SUCCESS) {
        NSString *text = [[NSString alloc] initWithBytes:buffer length:strnlen(buffer,count) encoding:NSUTF8StringEncoding];
        report[@"buildLog"] = text ?: @"<non-UTF8 build log>";
    }
    free(buffer);
}
int main(int argc,const char **argv) {
    @autoreleasepool {
        (void)argv;
        if (argc != 1) { fprintf(stderr,"usage: opencl-gpu-qualify\n"); return 2; }
        alarm(25);
        NSMutableDictionary *report = [@{@"event":@"final",@"result":@"INCONCLUSIVE",@"apiStatuses":[NSMutableArray array],
            @"scope":@"GPU-only 256-element uint addition; not FCP kernel or application qualification",
            @"hardDeadlineSeconds":@25,@"kernelSource":[NSString stringWithUTF8String:kernelSource],@"elements":@COUNT} mutableCopy];
        cl_platform_id platformIDs[16] = {0}; cl_uint platformCount = 0;
        cl_device_id device = NULL;
        cl_context context = NULL; cl_command_queue queue = NULL; cl_program program = NULL;
        cl_kernel kernel = NULL; cl_mem aBuffer = NULL,bBuffer = NULL,outBuffer = NULL;
        cl_uint a[COUNT],b[COUNT],output[COUNT];
        cl_int code = CL_SUCCESS; int exitCode = 1;
        for (cl_uint i=0;i<COUNT;i++) { a[i] = 0xf1234567U ^ (i*0x9e3779b9U); b[i] = 0x81234567U + i*0x1020304U; output[i] = 0xdeadbeefU; }
        checkpoint(@"clGetPlatformIDs(count)");
        code = clGetPlatformIDs(0,NULL,&platformCount);
        if (!status(report,@"clGetPlatformIDs(count)",code)) goto done;
        report[@"platformCount"] = @(platformCount);
        if (platformCount > 16) { report[@"result"] = @"ENUMERATION_OVER_BUDGET"; goto done; }
        if (!platformCount) { report[@"result"] = @"NO_GPU"; goto done; }
        if (!status(report,@"clGetPlatformIDs(list)",clGetPlatformIDs(platformCount,platformIDs,NULL))) goto done;
        for (cl_uint p=0;p<platformCount && !device;p++) {
            cl_uint deviceCount = 0;
            code = clGetDeviceIDs(platformIDs[p],CL_DEVICE_TYPE_GPU,0,NULL,&deviceCount);
            emit(@{@"event":@"gpuEnumeration",@"platformIndex":@(p),@"status":@(code),@"count":@(deviceCount)});
            if (code == CL_DEVICE_NOT_FOUND) continue;
            if (!status(report,@"clGetDeviceIDs(GPU,count)",code)) goto done;
            if (deviceCount > 32) { report[@"result"] = @"ENUMERATION_OVER_BUDGET"; goto done; }
            if (deviceCount) {
                cl_device_id devices[32] = {0};
                if (!status(report,@"clGetDeviceIDs(GPU,list)",clGetDeviceIDs(platformIDs[p],CL_DEVICE_TYPE_GPU,deviceCount,devices,NULL))) goto done;
                // Fixed first enumerated GPU, reported explicitly; never substitute a CPU device.
                device = devices[0]; report[@"platformIndex"] = @(p); report[@"gpuIndex"] = @0;
            }
        }
        if (!device) { report[@"result"] = @"NO_GPU"; goto done; }
        {
            cl_device_type selectedType = 0;
            if (!status(report,@"clGetDeviceInfo(type)",clGetDeviceInfo(device,CL_DEVICE_TYPE,sizeof(selectedType),&selectedType,NULL))) goto done;
            report[@"typeBits"] = @((unsigned long long)selectedType);
            if (!(selectedType & CL_DEVICE_TYPE_GPU)) { report[@"result"] = @"SELECTED_DEVICE_NOT_GPU"; goto done; }
            NSMutableArray *errors = [NSMutableArray array];
            NSMutableDictionary *identity = [NSMutableDictionary dictionary];
            identity[@"typeBits"] = report[@"typeBits"];
            identity[@"name"] = info(device,CL_DEVICE_NAME,errors,@"name");
            identity[@"vendor"] = info(device,CL_DEVICE_VENDOR,errors,@"vendor");
            identity[@"version"] = info(device,CL_DEVICE_VERSION,errors,@"version");
            identity[@"driverVersion"] = info(device,CL_DRIVER_VERSION,errors,@"driverVersion");
            identity[@"openclCVersion"] = info(device,CL_DEVICE_OPENCL_C_VERSION,errors,@"openclCVersion");
            identity[@"queryErrors"] = errors;
            report[@"device"] = identity;
            emit(@{@"event":@"selectedGPU",@"device":identity,@"platformIndex":report[@"platformIndex"],@"gpuIndex":@0});
        }
        checkpoint(@"clCreateContext");
        context = clCreateContext(NULL,1,&device,NULL,NULL,&code);
        if (!status(report,@"clCreateContext",code) || !context) goto done;
        queue = clCreateCommandQueue(context,device,0,&code);
        if (!status(report,@"clCreateCommandQueue",code) || !queue) goto done;
        program = clCreateProgramWithSource(context,1,&kernelSource,NULL,&code);
        if (!status(report,@"clCreateProgramWithSource",code) || !program) goto done;
        checkpoint(@"clBuildProgram");
        code = clBuildProgram(program,1,&device,NULL,NULL,NULL);
        status(report,@"clBuildProgram",code);
        buildLog(program,device,report);
        emit(@{@"event":@"buildResult",@"status":@(code),@"buildLog":report[@"buildLog"] ?: [NSNull null],
               @"buildLogSizeStatus":report[@"buildLogSizeStatus"] ?: [NSNull null],@"buildLogBytes":report[@"buildLogBytes"] ?: [NSNull null]});
        if (code != CL_SUCCESS) goto done;
        kernel = clCreateKernel(program,"lc_integer_add",&code);
        if (!status(report,@"clCreateKernel",code) || !kernel) goto done;
        aBuffer = clCreateBuffer(context,CL_MEM_READ_ONLY|CL_MEM_COPY_HOST_PTR,sizeof(a),a,&code);
        if (!status(report,@"clCreateBuffer(a)",code) || !aBuffer) goto done;
        bBuffer = clCreateBuffer(context,CL_MEM_READ_ONLY|CL_MEM_COPY_HOST_PTR,sizeof(b),b,&code);
        if (!status(report,@"clCreateBuffer(b)",code) || !bBuffer) goto done;
        outBuffer = clCreateBuffer(context,CL_MEM_WRITE_ONLY,sizeof(output),NULL,&code);
        if (!status(report,@"clCreateBuffer(output)",code) || !outBuffer) goto done;
        if (!status(report,@"clSetKernelArg(a)",clSetKernelArg(kernel,0,sizeof(aBuffer),&aBuffer))) goto done;
        if (!status(report,@"clSetKernelArg(b)",clSetKernelArg(kernel,1,sizeof(bBuffer),&bBuffer))) goto done;
        if (!status(report,@"clSetKernelArg(output)",clSetKernelArg(kernel,2,sizeof(outBuffer),&outBuffer))) goto done;
        {
            size_t global = COUNT;
            checkpoint(@"clEnqueueNDRangeKernel");
            if (!status(report,@"clEnqueueNDRangeKernel",clEnqueueNDRangeKernel(queue,kernel,1,NULL,&global,NULL,0,NULL,NULL))) goto done;
        }
        checkpoint(@"clEnqueueReadBuffer");
        if (!status(report,@"clEnqueueReadBuffer",clEnqueueReadBuffer(queue,outBuffer,CL_TRUE,0,sizeof(output),output,0,NULL,NULL))) goto done;
        {
            NSMutableArray *mismatches = [NSMutableArray array]; cl_uint mismatchCount = 0;
            for (cl_uint i=0;i<COUNT;i++) {
                cl_uint expected = a[i]+b[i];
                if (output[i] != expected) {
                    mismatchCount++;
                    if (mismatches.count < 8) [mismatches addObject:@{@"index":@(i),@"expected":@(expected),@"actual":@(output[i])}];
                }
            }
            report[@"mismatchCount"] = @(mismatchCount); report[@"firstMismatches"] = mismatches;
            report[@"result"] = mismatchCount ? @"INTEGER_MISMATCH" : @"PASS_GPU_INTEGER_ADD";
            exitCode = mismatchCount ? 1 : 0;
        }
    done:
        // Record cleanup as API statuses too; the hard alarm remains active through driver releases.
        if (outBuffer) status(report,@"clReleaseMemObject(output)",clReleaseMemObject(outBuffer));
        if (bBuffer) status(report,@"clReleaseMemObject(b)",clReleaseMemObject(bBuffer));
        if (aBuffer) status(report,@"clReleaseMemObject(a)",clReleaseMemObject(aBuffer));
        if (kernel) status(report,@"clReleaseKernel",clReleaseKernel(kernel));
        if (program) status(report,@"clReleaseProgram",clReleaseProgram(program));
        if (queue) status(report,@"clReleaseCommandQueue",clReleaseCommandQueue(queue));
        if (context) status(report,@"clReleaseContext",clReleaseContext(context));
        if (exitCode == 0 && report[@"failedAPI"]) { report[@"result"] = @"CLEANUP_API_FAILURE"; exitCode = 1; }
        emit(report); alarm(0); return exitCode;
    }
}
