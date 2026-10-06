// 실행기(Swift)가 부르는 C: libvterm과 pty(pty.c). launcher/build.sh가 -import-objc-header로 넘긴다.
#include "libvterm/include/vterm.h"
int tuidock_spawn(const char *path, char *const argv[], char *const envp[], int rows, int cols, int *master);
void tuidock_resize(int master, int rows, int cols, int width, int height);
