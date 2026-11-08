#!/usr/bin/env python3
"""Compile-only checks of the actual native rectangle guard; no executable, AX or UI."""
from pathlib import Path
import subprocess

header=Path(__file__).resolve().parents[1]/'probes/fcp-ax-project-guard.h'
checks=r'''
_Static_assert(LC_FCP_PROJECT_RECT_OK(10.,20.,100.,50.,0.,0.,800.,600.),"valid visible image");
_Static_assert(LC_FCP_PROJECT_RECT_OK(-500.,-100.,100.,50.,-600.,-200.,800.,600.),"valid negative screen origin");
_Static_assert(!LC_FCP_PROJECT_RECT_OK(10.,20.,0.,50.,0.,0.,800.,600.),"zero width");
_Static_assert(!LC_FCP_PROJECT_RECT_OK(10.,20.,100.,-1.,0.,0.,800.,600.),"negative height");
_Static_assert(!LC_FCP_PROJECT_RECT_OK(-1.,20.,100.,50.,0.,0.,800.,600.),"outside owned window");
_Static_assert(!LC_FCP_PROJECT_RECT_OK(10.,20.,1000.,50.,0.,0.,800.,600.),"crosses owned window");
_Static_assert(!LC_FCP_PROJECT_RECT_OK(NAN,20.,100.,50.,0.,0.,800.,600.),"NaN coordinate");
_Static_assert(!LC_FCP_PROJECT_RECT_OK(10.,20.,INFINITY,50.,0.,0.,800.,600.),"infinite width");
_Static_assert(!LC_FCP_PROJECT_RECT_OK(1000001.,20.,100.,50.,1000000.,0.,800.,600.),"unbounded coordinates");
'''
subprocess.run(['nice','-n','15','xcrun','clang','-std=c11','-Wall','-Wextra','-Werror','-fsyntax-only','-x','c','-'],
               input=('#include "'+str(header)+'"\n'+checks).encode(),timeout=15,check=True)
print('PASS compile-only native project geometry guards: finite bounds, containment, negative origins and invalid dimensions; no executable run')
