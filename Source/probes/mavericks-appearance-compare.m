// Compare real guest captures in a common sRGB bitmap; no synthetic reference or screenshot substitution.
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
static unsigned char *pixels(NSString *path,size_t *w,size_t *h){
    CGImageSourceRef s=CGImageSourceCreateWithURL((CFURLRef)[NSURL fileURLWithPath:path],NULL);
    if(!s)return NULL;CGImageRef i=CGImageSourceCreateImageAtIndex(s,0,NULL);CFRelease(s);if(!i)return NULL;
    *w=CGImageGetWidth(i);*h=CGImageGetHeight(i);unsigned char *p=calloc(*w**h,4);
    CGColorSpaceRef color=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef c=CGBitmapContextCreate(p,*w,*h,8,*w*4,color,kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(color);CGContextDrawImage(c,CGRectMake(0,0,*w,*h),i);CGImageRelease(i);CGContextRelease(c);return p;
}
int main(int argc,char **argv){@autoreleasepool{
    if(argc!=4)return 64;size_t w,h,vw,vh;unsigned char *a=pixels(@(argv[1]),&w,&h),*b=pixels(@(argv[2]),&vw,&vh);
    if(!a||!b||w!=vw||h!=vh){fprintf(stderr,"Capture dimensions must match\n");return 1;}
    NSArray *regions=@[@[@"titlebar",@0,@0,@840,@22],@[@"label",@215,@49,@220,@28],@[@"button",@215,@100,@210,@32],@[@"checkbox",@215,@145,@210,@32],@[@"radio",@215,@190,@210,@32],@[@"field",@465,@152,@310,@35],@[@"slider",@215,@287,@540,@25],@[@"progress",@215,@342,@540,@20],@[@"segments",@215,@392,@400,@30],@[@"background",@800,@50,@20,@450]];
    NSMutableArray *results=[NSMutableArray array];
    for(NSArray *r in regions){int scale=(int)(w/840);int x=[r[1] intValue]*scale,y=[r[2] intValue]*scale,rw=[r[3] intValue]*scale,rh=[r[4] intValue]*scale;if(x+rw>w||y+rh>h)return 2;
        double total=0;long changed=0,chromaA=0,chromaB=0;NSMutableDictionary *colorsA=[NSMutableDictionary dictionary],*colorsB=[NSMutableDictionary dictionary];
        for(int yy=y;yy<y+rh;yy++)for(int xx=x;xx<x+rw;xx++){
            size_t p=(yy*w+xx)*4;int max=0;for(int j=0;j<3;j++){int d=abs(a[p+j]-b[p+j]);total+=d;if(d>max)max=d;}
            if(max>2)changed++;
            if(MAX(a[p],MAX(a[p+1],a[p+2]))-MIN(a[p],MIN(a[p+1],a[p+2]))>2)chromaA++;
            if(MAX(b[p],MAX(b[p+1],b[p+2]))-MIN(b[p],MIN(b[p+1],b[p+2]))>2)chromaB++;
            NSNumber *ca=@((a[p]<<16)|(a[p+1]<<8)|a[p+2]),*cb=@((b[p]<<16)|(b[p+1]<<8)|b[p+2]);
            colorsA[ca]=@([colorsA[ca] intValue]+1);colorsB[cb]=@([colorsB[cb] intValue]+1);
        }
        NSNumber *peakA=nil,*peakB=nil;for(NSNumber *k in colorsA)if(!peakA||[colorsA[k] intValue]>[colorsA[peakA] intValue])peakA=k;
        for(NSNumber *k in colorsB)if(!peakB||[colorsB[k] intValue]>[colorsB[peakB] intValue])peakB=k;
        NSMutableArray *rowColors=[NSMutableArray array];
        if([r[0] isEqual:@"progress"] || [r[0] isEqual:@"titlebar"])for(int yy=y;yy<y+rh;yy++){
            int px=([r[0] isEqual:@"titlebar"]?800:600)*scale;size_t pos=(yy*w+px)*4;
            [rowColors addObject:@{@"y":@(yy),@"referenceTrack":@[@(a[pos]),@(a[pos+1]),@(a[pos+2])],@"candidateTrack":@[@(b[pos]),@(b[pos+1]),@(b[pos+2])],@"referenceFill":@[@(a[(yy*w+400*scale)*4]),@(a[(yy*w+400*scale)*4+1]),@(a[(yy*w+400*scale)*4+2])],@"candidateFill":@[@(b[(yy*w+400*scale)*4]),@(b[(yy*w+400*scale)*4+1]),@(b[(yy*w+400*scale)*4+2])]}];
        }
        [results addObject:@{@"rowColors":rowColors,@"referenceChromaticPixels":@(chromaA),@"candidateChromaticPixels":@(chromaB),@"region":r[0],@"meanAbsoluteRGBError":@(total/(rw*rh*3)),@"changedFractionThreshold2":@((double)changed/(rw*rh)),@"referencePeakRGB":peakA,@"candidatePeakRGB":peakB}];
    }
    unsigned char *heat=calloc(w*h,4);for(size_t p=0;p<w*h*4;p+=4){int max=0;for(int j=0;j<3;j++){int d=abs(a[p+j]-b[p+j]);if(d>max)max=d;}heat[p]=MIN(255,max*4);heat[p+3]=255;}
    CGColorSpaceRef color=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);CGContextRef c=CGBitmapContextCreate(heat,w,h,8,w*4,color,kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big);CGColorSpaceRelease(color);
    CGImageRef image=CGBitmapContextCreateImage(c);CGImageDestinationRef dest=CGImageDestinationCreateWithURL((CFURLRef)[NSURL fileURLWithPath:@(argv[3])],CFSTR("public.png"),1,NULL);
    CGImageDestinationAddImage(dest,image,NULL);BOOL ok=CGImageDestinationFinalize(dest);CFRelease(dest);CGImageRelease(image);CGContextRelease(c);
    puts([[[[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:results options:NSJSONWritingPrettyPrinted error:NULL] encoding:NSUTF8StringEncoding] autorelease] UTF8String]);free(a);free(b);free(heat);return ok?0:3;
}}
