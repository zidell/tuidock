// 자체 터미널(terminal.swift)의 pty. Swift에선 fork를 쓸 수 없어 C로 둔다.
#include <util.h>
#include <unistd.h>
#include <signal.h>
#include <sys/ioctl.h>

// tuidock_spawn은 새 pty에서 path를 argv·envp로 실행하고 자식 pid를 돌려준다(실패 -1). 마스터는 *master.
// envp는 fork 전에 만들어 넘긴다(fork 뒤 자식에서 setenv 같은 할당을 하지 않는다).
int tuidock_spawn(const char *path, char *const argv[], char *const envp[], int rows, int cols, int *master)
{
    struct winsize ws = {(unsigned short)rows, (unsigned short)cols, 0, 0};
    pid_t pid = forkpty(master, NULL, NULL, &ws);
    if (pid == 0) {
        signal(SIGPIPE, SIG_DFL);
        execve(path, argv, envp);
        _exit(127);
    }
    return pid;
}

// tuidock_resize는 pty 크기를 바꾼다. 커널이 프로그램에 SIGWINCH를 보낸다.
void tuidock_resize(int master, int rows, int cols, int width, int height)
{
    struct winsize ws = {(unsigned short)rows, (unsigned short)cols, (unsigned short)width, (unsigned short)height};
    ioctl(master, TIOCSWINSZ, &ws);
}
