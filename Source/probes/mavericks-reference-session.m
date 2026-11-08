#include <stdlib.h>
#include <stdio.h>
#include <unistd.h>
#include "seamless-session-join.h"
int main(int argc,char **argv){if(argc<3||geteuid()!=0)return 64;pid_t finder=atoi(argv[1]);if(finder<=1||join_session_of(finder))return 75;execv(argv[2],argv+2);perror("execv");return 71;}
