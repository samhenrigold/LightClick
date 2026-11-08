#ifndef LC_FCP_AX_PROJECT_GUARD_H
#define LC_FCP_AX_PROJECT_GUARD_H
#include <math.h>
/* Query-derived guest AX rectangles only. Never reuse saved coordinates. */
#define LC_FCP_RECT_OK(x,y,w,h) \
    ((x)>=-1000000.0 && (x)<=1000000.0 && (y)>=-1000000.0 && (y)<=1000000.0 && \
     (w)>=2.0 && (h)>=2.0 && (w)<=32768.0 && (h)<=32768.0)
#define LC_FCP_PROJECT_RECT_OK(x,y,w,h,wx,wy,ww,wh) \
    (LC_FCP_RECT_OK(x,y,w,h) && LC_FCP_RECT_OK(wx,wy,ww,wh) && \
     (x)>=(wx) && (y)>=(wy) && (x)+(w)<=(wx)+(ww) && (y)+(h)<=(wy)+(wh))
#endif
