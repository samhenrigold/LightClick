// Headless standard-C unit. Does not load Metal, OpenCL, or the diagnostic dylib.
#include "opencl-diagnostic-options.h"
#include <assert.h>
#include <stdio.h>
static void check(const char *input, bool standard, const char *expected) {
    char result[4096];
    assert(lc_opencl_diagnostic_options(input,standard,result,sizeof(result)));
    assert(!strcmp(result,expected));
}
int main(void) {
    assert(lc_opencl_diagnostic_source_allowed(LC_OPENCL_DIAGNOSTIC_SOURCE_SHA,154));
    assert(!lc_opencl_diagnostic_source_allowed(LC_OPENCL_DIAGNOSTIC_SOURCE_SHA,153));
    assert(!lc_opencl_diagnostic_source_allowed("0110a56696746ed66d54450f587bf4c063386815a5e79f5e7b13d83fef730d22",154));
    assert(!lc_opencl_diagnostic_source_allowed(NULL,154));
    check("",false,"-x cl");
    check("",true,"-std=cl1.2 -x cl");
    check("-fapplecl-lax-vector-conversions -Dfoo=1",false,"-fapplecl-lax-vector-conversions -Dfoo=1 -x cl");
    check("-O2 -fapplecl-lax-vector-conversions -Dfoo=1 -fapplecl-functional-casts -cl-std=CL1.2 -fapplecl-inline-definitions",true,"-O2  -Dfoo=1  -cl-std=CL1.2  -std=cl1.2 -x cl");
    check("-I\"/own/space path\"\t-DKEEP=1  -fapplecl-inline-definitions\n",true,"-I\"/own/space path\"\t-DKEEP=1  \n -std=cl1.2 -x cl");
    check("'-fapplecl-inline-definitions' -fapplecl-inline-definitions-extra -DNAME=-fapplecl-functional-casts",true,"'-fapplecl-inline-definitions' -fapplecl-inline-definitions-extra -DNAME=-fapplecl-functional-casts -std=cl1.2 -x cl");
    char with_header[4096];
    assert(lc_opencl_diagnostic_options_with_header("-DKEEP=1 -fapplecl-inline-definitions",true,true,with_header,sizeof(with_header)));
    assert(!strcmp(with_header,"-DKEEP=1  -std=cl1.2 -x cl -include " LC_OPENCL_DIAGNOSTIC_HEADER_PATH));
    char tiny[4]={1,2,3,4};
    assert(!lc_opencl_diagnostic_options("-long",true,tiny,3));
    assert(tiny[3]==4);
    puts("PASS exact synthetic-source gate, precise option removal/preservation, dialect-only control and output bounds");
}
